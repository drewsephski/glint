import SwiftUI
import AppKit
import GlintCore
import GlintRender

/// Editing layer over the preview: outlines and handles for the selected callout or redaction at its real place in
/// the rendered frame (through the zoom camera and letterboxing), drawing tools, and the facecam bubble.
/// Lives exactly over the player, whose frame is the rendered canvas. Edits commit once, on mouse-up.
struct OverlayCanvas: View {
    @Bindable var model: EditorModel
    @State private var live: Live?
    @State private var creating: (start: CGPoint, current: CGPoint)?
    @State private var textPrompt: TextPrompt?
    @State private var textAnchor: CGRect = .zero
    @State private var faceDrag: CGSize?

    /// Geometry being dragged, before it is committed.
    struct Live: Equatable { var id: String; var geometry: Geometry }
    enum Geometry: Equatable { case rect(NormRect), arrow(NormPoint, NormPoint), text(NormRect) }
    enum Handle { case body, topLeft, topRight, bottomLeft, bottomRight, width, tail, head }
    struct TextPrompt: Identifiable { let id = UUID(); var rect: NormRect }

    static let space = "overlay"
    // Smallest shapes the document accepts (Annotation/Redaction validation).
    static let minRect = 0.005, minArrow = 0.01, minTextWidth = 0.05

    var t: Double { model.currentTime }
    var plan: RenderPlan? { model.previewPlan }
    /// Overlays are edited on a still frame of the real edit (not while playing or previewing a proposal).
    var editable: Bool { !model.isPlaying && model.previewProposal == nil && plan != nil }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if editable { catcher(size) }
                if editable, selectedID != nil, let g = selectedGeometry { editor(g, size: size) }
                if let c = creating, let tool = model.overlayTool { creationPreview(tool, c.start, c.current) }
                if let plan, model.doc.media.camera != nil, model.doc.style.facecam.visible, model.overlayTool == nil, editable {
                    facecamHandle(plan: plan, size: size)
                }
            }
            .coordinateSpace(name: Self.space)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .popover(item: $textPrompt, attachmentAnchor: .rect(.rect(textAnchor)), arrowEdge: .bottom) { p in
                TextLabelPrompt { text in
                    textPrompt = nil
                    createText(text, rect: p.rect)
                } cancel: { textPrompt = nil }
            }
        }
        .onChange(of: model.selection) { _, _ in live = nil }
        .onChange(of: model.isPlaying) { _, playing in if playing { live = nil; creating = nil; faceDrag = nil } }
    }

    // MARK: Mapping (screen-normalized ↔ points in this view)

    func view(_ p: NormPoint, _ size: CGSize) -> CGPoint {
        guard let plan else { return .zero }
        let v = plan.viewPoint(p, outputTime: t)
        return CGPoint(x: v.x * size.width, y: v.y * size.height)
    }
    func shot(_ pt: CGPoint, _ size: CGSize) -> NormPoint {
        guard let plan, size.width > 0, size.height > 0 else { return .center }
        return plan.shotPoint(forView: NormPoint(pt.x / size.width, pt.y / size.height), outputTime: t)
    }
    func viewRect(_ r: NormRect, _ size: CGSize) -> CGRect {
        let a = view(NormPoint(r.x, r.y), size), b = view(NormPoint(r.x + r.width, r.y + r.height), size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    /// Width / height of the shot on screen (text labels wrap in shot pixels).
    var shotAspect: Double {
        guard let plan else { return Double(model.doc.media.width) / Double(max(1, model.doc.media.height)) }
        let r = plan.contentRect(outputTime: t)
        return (r.width * Double(plan.width)) / max(1e-9, r.height * Double(plan.height))
    }

    // MARK: Selected item

    var selectedID: String? {
        switch model.selection { case .annotation(let id), .redaction(let id): id; default: nil }
    }
    var selectedAnnotation: Annotation? {
        if case .annotation(let id) = model.selection { return model.doc.timeline.annotations.first { $0.id == id } }
        return nil
    }
    var selectedRedaction: Redaction? {
        if case .redaction(let id) = model.selection { return model.doc.timeline.redactions.first { $0.id == id } }
        return nil
    }
    /// The selected overlay's geometry when it shows at the playhead (live while dragging).
    var selectedGeometry: Geometry? {
        let src = model.sourceTime
        if let a = selectedAnnotation, src >= a.start, src < a.end {
            if let l = live, l.id == a.id { return l.geometry }
            return Self.geometry(a)
        }
        if let r = selectedRedaction, src >= r.start, src < r.end {
            if let l = live, l.id == r.id { return l.geometry }
            return .rect(r.rect)
        }
        return nil
    }

    static func geometry(_ a: Annotation) -> Geometry? {
        switch a.kind {
        case .box, .highlight: a.rect.map { .rect($0) }
        case .text: a.rect.map { .text($0) }
        case .arrow: a.from.flatMap { f in a.to.map { .arrow(f, $0) } }
        }
    }

    /// Height of a text label in screen-normalized units, matching how the renderer wraps it.
    func textHeight(_ text: String, rect: NormRect, fontSize: Double) -> Double {
        let H = 1000.0, W = H * shotAspect
        let px = fontSize * H
        let font = NSFont.systemFont(ofSize: px, weight: .semibold)
        let padX = px * 0.55, padY = px * 0.35
        let maxW = max(20, max(40, rect.width * W) - 2 * padX)
        let b = (text as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return (ceil(b.height) + 2 * padY) / H
    }

    // MARK: Click to select, drag to create

    func catcher(_ size: CGSize) -> some View {
        Color.white.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { inside in
                guard model.overlayTool != nil else { return }
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in
                    guard model.overlayTool != nil else { return }
                    creating = (v.startLocation, v.location)
                }
                .onEnded { v in
                    if let tool = model.overlayTool {
                        creating = nil
                        create(tool, from: v.startLocation, to: v.location, size: size)
                    } else if hypot(v.translation.width, v.translation.height) < 4 {
                        selectAt(v.location, size: size)
                    }
                })
            .accessibilityElement()
            .accessibilityLabel(model.overlayTool.map { "Preview. \($0.hint)." } ?? "Preview")
            .accessibilityHint(model.overlayTool == nil ? "Click a callout or redaction on the frame to select it" : "")
    }

    /// Select the topmost overlay under a click (callouts draw over redactions).
    func selectAt(_ pt: CGPoint, size: CGSize) {
        let src = model.sourceTime
        let p = shot(pt, size)
        let tol = 8.0 / max(1, Double(viewRect(.full, size).width))   // ~8 points, in screen units
        for a in model.doc.timeline.annotations.reversed() where src >= a.start && src < a.end {
            switch Self.geometry(a) {
            case .rect(let r)?: if r.contains(p) { model.selection = .annotation(a.id); return }
            case .text(let r)?:
                let h = textHeight(a.text ?? "", rect: r, fontSize: a.fontSize)
                if NormRect(x: r.x, y: r.y, width: r.width, height: h).contains(p) { model.selection = .annotation(a.id); return }
            case .arrow(let f, let to)?: if Self.distance(p, f, to) <= tol { model.selection = .annotation(a.id); return }
            case nil: continue
            }
        }
        for r in model.doc.timeline.redactions.reversed() where src >= r.start && src < r.end && r.rect.contains(p) {
            model.selection = .redaction(r.id); return
        }
        switch model.selection { case .annotation, .redaction: model.selection = nil; default: break }
    }

    static func distance(_ p: NormPoint, _ a: NormPoint, _ b: NormPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return p.distance(to: a) }
        let k = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return p.distance(to: NormPoint(a.x + k * dx, a.y + k * dy))
    }

    static func clamp01(_ p: NormPoint) -> NormPoint { NormPoint(max(0, min(1, p.x)), max(0, min(1, p.y))) }

    func create(_ tool: OverlayTool, from a: CGPoint, to b: CGPoint, size: CGSize) {
        let dragged = hypot(b.x - a.x, b.y - a.y) >= 4
        let p = shot(a, size), q = shot(b, size)
        let (start, end) = model.overlaySpan()
        switch tool {
        case .arrow:
            let f = Self.clamp01(p), to = Self.clamp01(q)
            guard dragged, f.distance(to: to) >= Self.minArrow else { model.banner = "Drag from where the arrow starts to where it points"; return }
            model.addAnnotation(Annotation(kind: .arrow, start: start, end: end, from: f, to: to))
        case .text:
            var x = max(0, min(1, min(p.x, q.x))), y = max(0, min(0.98, min(p.y, q.y)))
            var w = dragged ? abs(q.x - p.x) : 0.3
            if w < Self.minTextWidth { w = 0.3 }
            w = min(w, 1)
            if x + w > 1 { x = max(0, 1 - w) }
            y = max(0, y)
            let r = NormRect(x: x, y: y, width: w, height: 0.05)
            let topLeft = view(NormPoint(r.x, r.y), size)
            textAnchor = CGRect(x: topLeft.x, y: topLeft.y, width: max(1, viewRect(r, size).width), height: 1)
            textPrompt = TextPrompt(rect: r)
        case .box, .highlight, .redact:
            var r: NormRect
            if dragged {
                let c0 = Self.clamp01(p), c1 = Self.clamp01(q)
                r = NormRect(x: min(c0.x, c1.x), y: min(c0.y, c1.y), width: abs(c1.x - c0.x), height: abs(c1.y - c0.y))
                guard r.width >= Self.minRect, r.height >= Self.minRect else {
                    model.banner = (0...1).contains(p.x) && (0...1).contains(p.y) ? "Drag a larger area" : "Draw on the recorded screen, not the background"
                    return
                }
            } else {
                // A click places a default-sized shape centred on it.
                guard (0...1).contains(p.x), (0...1).contains(p.y) else { model.banner = "Click on the recorded screen, not the background"; return }
                let w = 0.22, h = 0.14
                r = NormRect(x: max(0, min(1 - w, p.x - w / 2)), y: max(0, min(1 - h, p.y - h / 2)), width: w, height: h)
            }
            if tool == .redact { model.addRedaction(Redaction(start: start, end: end, rect: r)) }
            else { model.addAnnotation(Annotation(kind: tool == .box ? .box : .highlight, start: start, end: end, rect: r)) }
        }
    }

    func createText(_ text: String, rect: NormRect) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        guard s.count <= 280 else { model.banner = "Labels can be at most 280 characters"; return }
        let (start, end) = model.overlaySpan()
        model.addAnnotation(Annotation(kind: .text, start: start, end: end, rect: rect, text: s))
    }

    @ViewBuilder func creationPreview(_ tool: OverlayTool, _ a: CGPoint, _ b: CGPoint) -> some View {
        let dash = StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        if tool == .arrow {
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Theme.accent, style: dash).allowsHitTesting(false)
        } else {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            Rectangle().fill(Theme.accent.opacity(tool == .redact ? 0.25 : 0.08))
                .overlay(Rectangle().stroke(Theme.accent, style: dash))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
        }
    }

    // MARK: Editing the selected overlay

    @ViewBuilder func editor(_ g: Geometry, size: CGSize) -> some View {
        switch g {
        case .rect(let r):
            let vr = viewRect(r, size)
            Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: max(1, vr.width), height: max(1, vr.height))
                .contentShape(Rectangle())
                .offset(x: vr.minX, y: vr.minY)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(handleDrag(.body, g, size))
                .accessibilityLabel("Selected area. Drag to move.")
            ForEach([Handle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                knob(at: corner(h, vr), handle: h, g: g, size: size, label: "Resize handle")
            }
        case .text(let r):
            let height = textHeight(selectedAnnotation?.text ?? "", rect: r, fontSize: selectedAnnotation?.fontSize ?? 0.04)
            let vr = viewRect(NormRect(x: r.x, y: r.y, width: r.width, height: height), size)
            Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(Color.white.opacity(0.001))
                .frame(width: max(1, vr.width), height: max(1, vr.height))
                .contentShape(Rectangle())
                .offset(x: vr.minX, y: vr.minY)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(handleDrag(.body, g, size))
                .accessibilityLabel("Selected label. Drag to move.")
            knob(at: CGPoint(x: vr.maxX, y: vr.midY), handle: .width, g: g, size: size, label: "Label width handle")
        case .arrow(let f, let to):
            let a = view(f, size), b = view(to, size)
            let line = Path { p in p.move(to: a); p.addLine(to: b) }
            line.stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .contentShape(line.strokedPath(StrokeStyle(lineWidth: 14, lineCap: .round)))
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(handleDrag(.body, g, size))
                .accessibilityLabel("Selected arrow. Drag to move.")
            knob(at: a, handle: .tail, g: g, size: size, round: true, label: "Arrow tail")
            knob(at: b, handle: .head, g: g, size: size, round: true, label: "Arrow tip")
        }
    }

    func corner(_ h: Handle, _ r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        default: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    func knob(at p: CGPoint, handle: Handle, g: Geometry, size: CGSize, round: Bool = false, label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: round ? 5 : 2, style: .continuous)
        return shape.fill(Color.white)
            .overlay(shape.strokeBorder(Theme.accentStrong, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .offset(x: p.x - 10, y: p.y - 10)
            .onHover { inside in if inside { (handle == .width ? NSCursor.resizeLeftRight : NSCursor.crosshair).push() } else { NSCursor.pop() } }
            .gesture(handleDrag(handle, g, size))
            .accessibilityLabel(label)
    }

    /// A drag on a handle: updates the live geometry, commits one update on release.
    func handleDrag(_ h: Handle, _ g0: Geometry, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard let id = selectedID else { return }
                // The first change records where the drag started; later re-renders hand us the live geometry.
                if dragBase == nil { dragBase = g0 }
                live = Live(id: id, geometry: moved(dragBase ?? g0, h, from: v.startLocation, to: v.location, size: size))
            }
            .onEnded { v in
                let base = dragBase ?? g0
                dragBase = nil
                guard let id = selectedID else { live = nil; return }
                let g = moved(base, h, from: v.startLocation, to: v.location, size: size)
                commit(id, g)
                live = nil
            }
    }
    @State private var dragBase: Geometry?

    /// The geometry after dragging handle `h` from one view point to another, clamped to the screen.
    func moved(_ g: Geometry, _ h: Handle, from a: CGPoint, to b: CGPoint, size: CGSize) -> Geometry {
        let pa = shot(a, size), pb = shot(b, size)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        switch g {
        case .rect(let r):
            if h == .body {
                return .rect(NormRect(x: max(0, min(1 - r.width, r.x + dx)), y: max(0, min(1 - r.height, r.y + dy)), width: r.width, height: r.height))
            }
            var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
            switch h {
            case .topLeft: x0 += dx; y0 += dy
            case .topRight: x1 += dx; y0 += dy
            case .bottomLeft: x0 += dx; y1 += dy
            default: x1 += dx; y1 += dy
            }
            let lx = max(0, min(1, min(x0, x1))), hx = max(0, min(1, max(x0, x1)))
            let ly = max(0, min(1, min(y0, y1))), hy = max(0, min(1, max(y0, y1)))
            return .rect(NormRect(x: lx, y: ly, width: hx - lx, height: hy - ly))
        case .text(let r):
            if h == .width {
                let w = max(Self.minTextWidth, min(1 - r.x, r.width + dx))
                return .text(NormRect(x: r.x, y: r.y, width: w, height: r.height))
            }
            return .text(NormRect(x: max(0, min(1 - r.width, r.x + dx)), y: max(0, min(0.98, r.y + dy)), width: r.width, height: r.height))
        case .arrow(let f, let to):
            switch h {
            case .tail: return .arrow(Self.clamp01(NormPoint(f.x + dx, f.y + dy)), to)
            case .head: return .arrow(f, Self.clamp01(NormPoint(to.x + dx, to.y + dy)))
            default:
                // Move both ends together, stopping at the screen edges.
                let sx = max(-min(f.x, to.x), min(1 - max(f.x, to.x), dx)), sy = max(-min(f.y, to.y), min(1 - max(f.y, to.y), dy))
                return .arrow(NormPoint(f.x + sx, f.y + sy), NormPoint(to.x + sx, to.y + sy))
            }
        }
    }

    static func json(_ r: NormRect) -> JSONValue { .object(["x": .number(r.x), "y": .number(r.y), "width": .number(r.width), "height": .number(r.height)]) }
    static func json(_ p: NormPoint) -> JSONValue { .object(["x": .number(p.x), "y": .number(p.y)]) }

    func commit(_ id: String, _ g: Geometry) {
        switch g {
        case .rect(let r):
            guard r.width >= Self.minRect, r.height >= Self.minRect else { model.banner = "That area is too small. Drag it larger."; return }
            if selectedRedaction?.id == id {
                guard selectedRedaction?.rect != r else { return }
                model.updateOverlay(.updateRedaction, id: id, ["rect": Self.json(r)], label: "Edit redaction area")
            } else {
                guard selectedAnnotation?.rect != r else { return }
                model.updateOverlay(.updateAnnotation, id: id, ["rect": Self.json(r)], label: "Edit callout area")
            }
        case .text(let r):
            guard r.width >= Self.minTextWidth, r.x + r.width <= 1.0001 else { model.banner = "Labels need to be at least 5% of the screen wide"; return }
            guard selectedAnnotation?.rect != r else { return }
            model.updateOverlay(.updateAnnotation, id: id, ["rect": Self.json(r)], label: "Move label")
        case .arrow(let f, let to):
            guard f.distance(to: to) >= Self.minArrow else { model.banner = "That arrow is too short. Drag its ends further apart."; return }
            guard selectedAnnotation?.from != f || selectedAnnotation?.to != to else { return }
            model.updateOverlay(.updateAnnotation, id: id, ["from": Self.json(f), "to": Self.json(to)], label: "Edit arrow")
        }
    }

    // MARK: Facecam

    /// The facecam bubble: drag it and it snaps to the nearest corner of the frame.
    @ViewBuilder func facecamHandle(plan: RenderPlan, size: CGSize) -> some View {
        let st = model.doc.style.facecam
        let zoomed = FacecamLayout.zoomed(cameraScale: plan.camera.state(at: t).scale, restScale: max(1, model.doc.style.canvas.baseScale))
        let r = FacecamLayout.rect(st, canvasWidth: Double(plan.width), canvasHeight: Double(plan.height), zoomed: zoomed)
        let vr = CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
        let off = faceDrag ?? .zero
        let target = faceDrag.map { nearestCorner(CGPoint(x: vr.midX + $0.width, y: vr.midY + $0.height), size) }
        if faceDrag != nil {
            ForEach(FacecamStyle.Corner.allCases, id: \.self) { c in
                let cr = Self.facecamRect(st, at: c, plan: plan, zoomed: zoomed)
                RoundedRectangle(cornerRadius: st.shape == .circle ? cr.height * size.height / 2 : 8, style: .continuous)
                    .strokeBorder(c == target ? Theme.accent : Color.white.opacity(0.35), style: StrokeStyle(lineWidth: c == target ? 2 : 1, dash: [5, 4]))
                    .frame(width: cr.width * size.width, height: cr.height * size.height)
                    .offset(x: cr.x * size.width, y: cr.y * size.height)
                    .allowsHitTesting(false)
            }
        }
        let shape = RoundedRectangle(cornerRadius: st.shape == .circle ? vr.height / 2 : max(0, min(0.5, st.cornerRadius)) * vr.height, style: .continuous)
        shape.fill(Color.white.opacity(0.001))
            .overlay(shape.strokeBorder(Theme.accent, lineWidth: faceDrag != nil ? 2 : 0))
            .frame(width: vr.width, height: vr.height)
            .contentShape(shape)
            .offset(x: vr.minX + off.width, y: vr.minY + off.height)
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .help("Drag the facecam to another corner")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { v in faceDrag = v.translation }
                .onEnded { v in
                    faceDrag = nil
                    let c = nearestCorner(CGPoint(x: vr.midX + v.translation.width, y: vr.midY + v.translation.height), size)
                    guard c != st.position else { return }
                    model.apply([.style("facecam.position", .string(c.rawValue))], label: "Move facecam to the \(c.rawValue.replacingOccurrences(of: "-", with: " "))")
                })
            .accessibilityElement()
            .accessibilityLabel("Facecam")
            .accessibilityValue(st.position.rawValue.replacingOccurrences(of: "-", with: " "))
            .accessibilityAdjustableAction { dir in
                let all = FacecamStyle.Corner.allCases
                guard let i = all.firstIndex(of: st.position) else { return }
                let next = all[(i + (dir == .increment ? 1 : all.count - 1)) % all.count]
                model.apply([.style("facecam.position", .string(next.rawValue))], label: "Move facecam")
            }
    }

    static func facecamRect(_ st: FacecamStyle, at corner: FacecamStyle.Corner, plan: RenderPlan, zoomed: Double) -> NormRect {
        var s = st
        s.position = corner
        return FacecamLayout.rect(s, canvasWidth: Double(plan.width), canvasHeight: Double(plan.height), zoomed: zoomed)
    }

    func nearestCorner(_ center: CGPoint, _ size: CGSize) -> FacecamStyle.Corner {
        let left = center.x < size.width / 2, top = center.y < size.height / 2
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

/// Asks for a label's text when the Text tool places one.
struct TextLabelPrompt: View {
    let add: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Label text").font(.system(size: 12, weight: .semibold))
            TextField("What should the label say?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4).frame(width: 260)
                .focused($focused)
                .onSubmit { add(text) }
            HStack {
                Text("\(text.count)/280").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(text.count > 280 ? Theme.cut : Theme.text3)
                Spacer()
                Button("Cancel") { cancel() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Add") { add(text) }.buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 280)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

/// Tool buttons for drawing on the preview.
struct OverlayToolbar: View {
    @Bindable var model: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            toolButton(nil, "cursorarrow", "Select", key: "Esc")
            ForEach(OverlayTool.allCases) { tool in toolButton(tool, tool.systemImage, tool.title, key: String(tool.key).uppercased()) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .disabled(model.previewProposal != nil)
        .help(model.previewProposal != nil ? "Apply or discard the previewed proposal to draw on the preview" : "Draw callouts and redactions on the preview")
    }

    func toolButton(_ tool: OverlayTool?, _ icon: String, _ title: String, key: String) -> some View {
        let on = model.overlayTool == tool
        return Button {
            if tool != nil, model.isPlaying { model.togglePlay() }
            model.overlayTool = tool
        } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Theme.onAccent : Theme.text2)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(key))")
        .accessibilityLabel(tool == nil ? "Select tool" : "\(title) tool")
        .accessibilityValue(on ? "selected" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
