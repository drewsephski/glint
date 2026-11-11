import SwiftUI
import GlintCore

/// How the timeline lays out time. Every x position and every pointer-to-time conversion goes through here, so the
/// two views share one implementation:
/// - **Edited video** (output time): what the export plays. Removed footage closes up (a cut is a seam), a sped-up
///   stretch is as wide as it plays (source length / rate), and the ruler reads the finished video's clock.
/// - **Original take** (program source time, all shots end to end): cuts hatched in place, for getting removed
///   material back.
/// The document stays in source time either way: views convert, operations get source seconds.
struct TimelineScale {
    enum Mode: String, CaseIterable, Identifiable {
        case edited, original
        var id: String { rawValue }
        var title: String { self == .edited ? "Edited video" : "Original take" }
    }
    let mode: Mode
    let pps: Double
    let map: TimeMap
    let programDuration: Double
    var edited: Bool { mode == .edited }

    /// Length of the timeline in view seconds.
    var duration: Double { edited ? map.outputDuration : programDuration }
    /// View time of a source instant. In the edited view, an instant inside a cut sits on the seam the cut left
    /// (both edges of a cut play at the same output instant), and trimmed ends sit at 0 / the end.
    func view(_ source: Double) -> Double { edited ? map.outputClamped(forSource: source) : source }
    func x(_ source: Double) -> Double { view(source) * pps }
    /// Source instant shown at a view time. `end` picks the earlier side of a seam, for the end of a range, so a range
    /// ending at a seam doesn't reach across the removed footage.
    func source(view v: Double, end: Bool = false) -> Double {
        guard edited else { return v }
        return end ? map.sourceEnd(forOutput: v) : map.source(forOutput: v)
    }
    /// View span of a source range: zero width when it is entirely removed.
    func viewSpan(_ start: Double, _ end: Double) -> (Double, Double) {
        let a = view(start)
        return (a, max(a, view(end)))
    }
    /// True when an item doesn't appear in the finished video at all (edited view only).
    func collapsed(_ start: Double, _ end: Double) -> Bool { edited && !map.isVisible(TimeRange(start, end)) }
}

/// Timeline over the program (all shots end to end), so items stay anchored to content: in the edited view cuts are
/// seams and speed changes take their played length; in the original view cuts are hatched in place. Speed changes
/// show as bands, and zooms, captions, callouts, masks and audio as chips that move and resize.
struct TimelineEditor: View {
    let model: EditorModel
    @State private var zoomLevel: Double = 1
    /// A range being dragged out on the video track, in view seconds.
    @State private var dragRange: (Double, Double)?
    @State private var drag: ChipDrag?
    @AppStorage("glint.timeline.mode") private var mode: TimelineScale.Mode = .edited

    enum DragMode { case move, leading, trailing }
    /// A drag in progress. `revision` is the document revision when it began, sent as `expectedRevision` on commit so
    /// an agent edit that lands mid-drag isn't overwritten with positions computed on the old document.
    struct ChipDrag: Equatable { var id: String; var mode: DragMode; var dx: Double; var revision: Int }

    /// Start or continue a drag (the revision is captured once, at the start).
    func track(_ id: String, _ mode: DragMode, _ dx: Double) {
        let rev = drag?.id == id ? drag!.revision : model.doc.revision
        drag = ChipDrag(id: id, mode: mode, dx: dx, revision: rev)
    }

    static let labelWidth: CGFloat = 92
    static let headerH: CGFloat = 34
    static let rulerH: CGFloat = 22, shotsH: CGFloat = 28, videoH: CGFloat = 52, waveH: CGFloat = 18, laneH: CGFloat = 28
    static let overlayRowH: CGFloat = 20
    /// Pointer distance (points) within which a dragged edge snaps.
    static let snapDistance: Double = 6

    enum Lane: Hashable {
        case shots, video, zoom, captions, overlays(rows: Int), voice, audio
        var height: CGFloat {
            switch self {
            case .shots: TimelineEditor.shotsH
            case .video: TimelineEditor.videoH + TimelineEditor.waveH
            case .overlays(let rows): CGFloat(max(1, rows)) * TimelineEditor.overlayRowH + 8
            default: TimelineEditor.laneH
            }
        }
        var title: String {
            switch self {
            case .shots: "Shots"; case .video: "Video"; case .zoom: "Zoom"; case .captions: "Captions"
            case .overlays: "Overlays"; case .voice: "Voice"; case .audio: "Audio"
            }
        }
        var icon: String {
            switch self {
            case .shots: "film.stack"; case .video: "film"; case .zoom: "plus.magnifyingglass"; case .captions: "captions.bubble"
            case .overlays: "rectangle.on.rectangle"; case .voice: "waveform"; case .audio: "music.note"
            }
        }
    }

    // MARK: Layout

    /// Overlay chips stacked into rows so overlapping ones stay visible (at most three rows).
    struct OverlayItem: Identifiable {
        enum Kind { case annotation(Annotation), redaction(Redaction) }
        let kind: Kind
        var id: String { switch kind { case .annotation(let a): a.id; case .redaction(let r): r.id } }
        var start: Double { switch kind { case .annotation(let a): a.start; case .redaction(let r): r.start } }
        var end: Double { switch kind { case .annotation(let a): a.end; case .redaction(let r): r.end } }
    }

    static func overlayRows(_ doc: ProjectDocument) -> [(OverlayItem, Int)] {
        let items = (doc.timeline.annotations.map { OverlayItem(kind: .annotation($0)) } + doc.timeline.redactions.map { OverlayItem(kind: .redaction($0)) })
            .sorted { $0.start < $1.start }
        var rowEnds: [Double] = []
        var out: [(OverlayItem, Int)] = []
        for it in items {
            if let r = rowEnds.firstIndex(where: { $0 <= it.start + 1e-6 }) { rowEnds[r] = it.end; out.append((it, r)) }
            else if rowEnds.count < 3 { rowEnds.append(it.end); out.append((it, rowEnds.count - 1)) }
            else {
                // Out of rows: put it on the row that frees up first.
                let r = rowEnds.indices.min(by: { rowEnds[$0] < rowEnds[$1] })!
                rowEnds[r] = max(rowEnds[r], it.end); out.append((it, r))
            }
        }
        return out
    }

    static func lanes(_ doc: ProjectDocument) -> [Lane] {
        let rows = (overlayRows(doc).map(\.1).max() ?? 0) + 1
        var l: [Lane] = [.shots, .video, .zoom, .captions, .overlays(rows: rows)]
        if !doc.timeline.voiceover.isEmpty { l.append(.voice) }
        if !doc.timeline.audio.isEmpty { l.append(.audio) }
        return l
    }

    /// The height the timeline needs to show every lane without scrolling.
    static func preferredHeight(_ doc: ProjectDocument) -> CGFloat {
        headerH + rulerH + lanes(doc).reduce(0) { $0 + $1.height } + 16
    }

    var body: some View {
        GeometryReader { geo in
            let map = model.map
            let duration = max(0.1, mode == .edited ? map.outputDuration : model.doc.duration)
            let avail = max(200, geo.size.width - Self.labelWidth - 24)
            let pps = avail / duration * zoomLevel
            let sc = TimelineScale(mode: mode, pps: pps, map: map, programDuration: model.doc.duration)
            let contentW = duration * pps
            let lanes = Self.lanes(model.doc)
            VStack(spacing: 0) {
                header
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: Self.rulerH)
                            ForEach(lanes, id: \.self) { lane in laneLabel(lane.title, lane.icon).frame(height: lane.height) }
                        }
                        .frame(width: Self.labelWidth)
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ruler(width: contentW, sc: sc, duration: duration).frame(height: Self.rulerH)
                                    ForEach(lanes, id: \.self) { lane in
                                        laneContent(lane, width: contentW, sc: sc).frame(width: contentW, height: lane.height, alignment: .topLeading)
                                    }
                                }
                                shotJoins(sc: sc, height: lanes.reduce(0) { $0 + $1.height })
                                    .offset(y: Self.rulerH)
                                playhead(sc: sc, height: Self.rulerH + lanes.reduce(0) { $0 + $1.height })
                            }
                            .frame(width: contentW, alignment: .leading)
                            .coordinateSpace(name: "timeline")
                            .padding(.trailing, 12)
                        }
                    }
                }
            }
        }
        .background(Theme.panel)
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Timeline").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
            Picker("Timeline shows", selection: $mode) {
                ForEach(TimelineScale.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help("Edited video: the timeline is the finished video, with removed footage closed up and speed changes at the length they play. Original take: the whole recording, with cuts in place, to bring removed footage back.")
            Text(mode == .edited ? "Times match the exported video. Drag on the video to select a range."
                                 : "The whole take, cuts hatched in place. Drag on the video to select a range.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            Group {
                Button { model.splitShotAtPlayhead() } label: { Image(systemName: "square.split.2x1") }
                    .help("Split the shot at the playhead (S)").accessibilityLabel("Split shot at playhead")
                Button { model.setTrimAtPlayhead(in: true) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Start the video at the playhead (I)").accessibilityLabel("Set in point at playhead")
                Button { model.setTrimAtPlayhead(in: false) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("End the video at the playhead (O)").accessibilityLabel("Set out point at playhead")
            }
            .buttonStyle(IconButtonStyle()).controlSize(.small).scaleEffect(0.86)
            Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 14).padding(.horizontal, 2)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.text3).accessibilityHidden(true)
            Slider(value: $zoomLevel, in: 1...12).frame(width: 120).controlSize(.mini)
                .accessibilityLabel("Timeline zoom").accessibilityValue(String(format: "%.1f times", zoomLevel))
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.text3).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).frame(height: Self.headerH)
    }

    func laneLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 9.5)); Text(t).font(.system(size: 10.5, weight: .medium)) }
            .foregroundStyle(Theme.text3).padding(.leading, 12).frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder func laneContent(_ lane: Lane, width: Double, sc: TimelineScale) -> some View {
        switch lane {
        case .shots: shotsLane(width: width, sc: sc)
        case .video: videoLane(width: width, sc: sc)
        case .zoom: zoomLane(width: width, sc: sc)
        case .captions: captionLane(width: width, sc: sc)
        case .overlays: overlayLane(width: width, sc: sc)
        case .voice: voiceLane(width: width, sc: sc)
        case .audio: audioLane(width: width, sc: sc)
        }
    }

    /// Where the playhead is, in view seconds.
    func playheadView(_ sc: TimelineScale) -> Double { sc.edited ? model.currentTime : model.sourceTime }
    /// Seek to a view time (output time in the edited view, so a click lands exactly on that frame of the video).
    func seek(view v: Double, _ sc: TimelineScale) {
        if sc.edited { model.seek(output: max(0, v)) } else { model.seek(source: max(0, v)) }
    }

    /// An item that doesn't appear in the edited video (it is entirely inside removed footage): a thin tick at the
    /// seam, so it isn't lost, without pretending it plays.
    func collapsedMarker(x: Double, height: CGFloat, y: CGFloat, tint: Color, selected: Bool, label: String, select: @escaping () -> Void) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(selected ? Theme.accent : tint.opacity(0.7))
            .frame(width: 3, height: height)
            .frame(width: 9, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 4.5, y: y)
            .onTapGesture { select() }
            .help("\(label). It is inside removed footage, so it doesn't play. Switch to Original take to edit it.")
            .accessibilityElement()
            .accessibilityLabel("\(label), inside removed footage")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
    }

    /// A one-line note inside an empty lane.
    func laneHint(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            .padding(.leading, 8).frame(maxHeight: .infinity, alignment: .center).allowsHitTesting(false)
    }

    // MARK: Drag resolution (shared by every chip, so the live position and the committed one agree)

    func snap(_ t: Double, pps: Double, targets: [Double]) -> Double? {
        let tol = Self.snapDistance / pps
        guard let best = targets.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= tol else { return nil }
        return best
    }

    /// An item's span while it is dragged (moved or one edge resized), snapped and kept in bounds. The pointer works in
    /// view time (what the user sees); `view` is the span to draw and `source` the document times to commit. An edge
    /// the drag didn't move keeps its exact source instant, even when it is hidden inside a cut.
    func resolved(id: String, start: Double, end: Double, sc: TimelineScale, minLength: Double, lower: Double = 0,
                  upper: Double? = nil) -> (view: (Double, Double), source: (Double, Double)) {
        let (vs0, ve0) = sc.viewSpan(start, end)
        guard let d = drag, d.id == id else { return ((vs0, ve0), (start, end)) }
        let lo = sc.view(lower), hi = sc.view(upper ?? model.doc.duration)
        let dt = d.dx / sc.pps
        let targets = model.snapTargets(excluding: [start, end]).map(sc.view)
        var vs = vs0, ve = ve0
        switch d.mode {
        case .move:
            var shift = max(lo - vs0, min(hi - ve0, dt))
            let adjustments = [snap(vs0 + shift, pps: sc.pps, targets: targets).map { $0 - (vs0 + shift) },
                               snap(ve0 + shift, pps: sc.pps, targets: targets).map { $0 - (ve0 + shift) }].compactMap { $0 }
            if let adj = adjustments.min(by: { abs($0) < abs($1) }), vs0 + shift + adj >= lo - 1e-9, ve0 + shift + adj <= hi + 1e-9 { shift += adj }
            vs = vs0 + shift; ve = ve0 + shift
        case .leading:
            vs = max(lo, min(ve0 - minLength, vs0 + dt))
            if let t = snap(vs, pps: sc.pps, targets: targets), t >= lo, t <= ve0 - minLength { vs = t }
        case .trailing:
            ve = min(hi, max(vs0 + minLength, ve0 + dt))
            if let t = snap(ve, pps: sc.pps, targets: targets), t <= hi, t >= vs0 + minLength { ve = t }
        }
        let s = abs(vs - vs0) < 1e-9 ? start : sc.source(view: vs)
        let e = abs(ve - ve0) < 1e-9 ? end : sc.source(view: ve, end: true)
        return ((vs, ve), (s, max(s, e)))
    }

    /// A chip on a lane: tap selects, drag moves, edges resize. `commit` gets the new source range once, on release,
    /// with the revision the drag started from. In the edited view, an item that doesn't play is a thin marker.
    @ViewBuilder
    func chip<C: View>(id: String, start: Double, end: Double, sc: TimelineScale, height: CGFloat, y: CGFloat, minLength: Double = 0.2,
                       lower: Double = 0, upper: Double? = nil, resizable: Bool = true, label: String, selected: Bool, tint: Color,
                       select: @escaping () -> Void, commit: @escaping (Double, Double, DragMode, Int) -> Void,
                       @ViewBuilder content: () -> C) -> some View {
        if drag?.id != id, sc.collapsed(start, end) {
            collapsedMarker(x: sc.x(start), height: height, y: y, tint: tint, selected: selected, label: label, select: select)
        } else {
            let (v, _) = resolved(id: id, start: start, end: end, sc: sc, minLength: minLength, lower: lower, upper: upper)
            let finish = {
                let r = resolved(id: id, start: start, end: end, sc: sc, minLength: minLength, lower: lower, upper: upper).source
                let mode = drag?.mode ?? .move
                let rev = drag?.revision ?? model.doc.revision
                drag = nil
                guard abs(r.0 - start) > 0.004 || abs(r.1 - end) > 0.004 else { return }
                commit(r.0, r.1, mode, rev)
            }
            content()
                .frame(width: max(resizable ? 14 : 8, (v.1 - v.0) * sc.pps), height: height, alignment: .leading)
                .overlay {
                    if resizable {
                        HStack(spacing: 0) {
                            edgeHandle(id: id, mode: .leading, onEnd: finish)
                            Spacer(minLength: 0)
                            edgeHandle(id: id, mode: .trailing, onEnd: finish)
                        }
                    }
                }
                .contentShape(Rectangle())
                .offset(x: v.0 * sc.pps, y: y)
                .onTapGesture { select() }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                    .onChanged { g in track(id, .move, Double(g.translation.width)) }
                    .onEnded { _ in finish() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("\(Theme.time(v.0, precise: true)) to \(Theme.time(v.1, precise: true))")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { select() }
        }
    }

    func edgeHandle(id: String, mode: DragMode, onEnd: @escaping () -> Void) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 7)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { v in track(id, mode, Double(v.translation.width)) }
                .onEnded { _ in onEnd() })
    }

    /// Bounds that keep an item between its neighbours on the same lane (for items that must not overlap).
    func neighbours<T>(_ items: [T], id: String, idOf: (T) -> String, startOf: (T) -> Double, endOf: (T) -> Double) -> (Double, Double) {
        let sorted = items.sorted { startOf($0) < startOf($1) }
        guard let i = sorted.firstIndex(where: { idOf($0) == id }) else { return (0, model.doc.duration) }
        let lo = i > 0 ? endOf(sorted[i - 1]) : 0
        let hi = i + 1 < sorted.count ? startOf(sorted[i + 1]) : model.doc.duration
        return (min(lo, startOf(sorted[i])), max(hi, endOf(sorted[i])))
    }

    // MARK: Ruler

    func ruler(width: Double, sc: TimelineScale, duration: Double) -> some View {
        let pps = sc.pps
        let step: Double = pps > 160 ? 0.5 : pps > 60 ? 1 : pps > 25 ? 2 : pps > 10 ? 5 : 10
        return Canvas { ctx, size in
            var t = 0.0
            while t <= duration {
                let x = t * pps
                let major = (t / step).rounded().truncatingRemainder(dividingBy: 2) == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (major ? 8 : 4), width: 1, height: major ? 8 : 4)), with: .color(.white.opacity(0.25)))
                if major { ctx.draw(Text(Theme.time(t)).font(.system(size: 9.5, design: .monospaced)).foregroundColor(Theme.text3), at: CGPoint(x: x + 3, y: 7), anchor: .leading) }
                t += step
            }
            for m in model.doc.timeline.markers {
                let x = sc.x(m.time)
                ctx.fill(Path(CGRect(x: x, y: 2, width: 2, height: size.height - 2)), with: .color(Theme.speed))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(view: v.location.x / pps, sc) })
        .overlay(alignment: .topLeading) {
            ForEach(model.doc.timeline.markers) { m in
                Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Theme.speed).offset(x: sc.x(m.time) + 2, y: 1).help(m.note)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(sc.edited ? "Playhead, edited video time" : "Playhead, original take time")
        .accessibilityValue(Theme.time(playheadView(sc), precise: true))
        .accessibilityAdjustableAction { dir in seek(view: playheadView(sc) + (dir == .increment ? 1 : -1), sc) }
    }

    // MARK: Shots

    func shotsLane(width: Double, sc: TimelineScale) -> some View {
        let layout = model.clipLayout
        let segs = layout.segments
        let single = segs.count == 1 && segs[0].clip.primary
        return ZStack(alignment: .topLeading) {
            ForEach(segs, id: \.clip.id) { seg in
                if drag?.id != seg.clip.id, sc.collapsed(seg.start, seg.end) {
                    collapsedMarker(x: sc.x(seg.start), height: Self.shotsH - 6, y: 3, tint: Theme.text2, selected: model.selection == .clip(seg.clip.id),
                                    label: "Shot \(seg.clip.name)", select: { model.selection = .clip(seg.clip.id) })
                } else {
                    shotChip(seg, count: segs.count, sc: sc, hint: single ? "One shot. Press S to split it at the playhead." : nil)
                }
            }
            ForEach(model.doc.timeline.transitions) { tr in transitionMarker(tr, sc: sc) }
        }
    }

    func shotChip(_ seg: ClipLayout.Segment, count: Int, sc: TimelineScale, hint: String?) -> some View {
        let c = seg.clip
        let sel = model.selection == .clip(c.id)
        let dx = drag?.id == c.id && drag?.mode == .move ? drag!.dx : 0
        let (v0, v1) = sc.viewSpan(seg.start, seg.end)
        let w = max(10, (v1 - v0) * sc.pps - 2)
        let inside = model.sourceTime > seg.start + 0.05 && model.sourceTime < seg.end - 0.05
        return HStack(spacing: 5) {
            Image(systemName: c.primary ? "record.circle" : "square.and.arrow.down").font(.system(size: 9.5)).foregroundStyle(Theme.text2)
            Text(c.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            if let scene = c.scene {
                Text(scene).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: w, height: Self.shotsH - 6, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(sel ? Theme.raised : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(sel ? Theme.accent : Theme.hairlineStrong, lineWidth: sel ? 1.5 : 1))
        .contentShape(Rectangle())
        .offset(x: v0 * sc.pps + 1 + dx, y: 3)
        .zIndex(dx != 0 ? 1 : 0)
        .help("\(c.name)\(c.primary ? ", the recording" : ", imported")\(c.scene.map { ", scene \($0)" } ?? ""). Drag to reorder.")
        .onTapGesture { model.selection = .clip(c.id) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .onChanged { v in if count > 1 { track(c.id, .move, Double(v.translation.width)) } }
            .onEnded { v in
                let rev = drag?.revision
                drag = nil
                guard count > 1 else { return }
                // Compare centres where the user sees them (view time), so reordering works the same in both views.
                let center = (v0 + v1) / 2 + Double(v.translation.width) / sc.pps
                let others = model.clipLayout.segments.filter { $0.clip.id != c.id }
                let target = others.filter { (sc.view($0.start) + sc.view($0.end)) / 2 < center }.count
                if target != seg.index { model.moveShot(c.id, to: target, expectedRevision: rev) }
            })
        .contextMenu {
            Button("Split at Playhead") { model.splitShotAtPlayhead() }.disabled(!inside)
            Button("Move Left") { model.moveShot(c.id, to: seg.index - 1) }.disabled(seg.index == 0)
            Button("Move Right") { model.moveShot(c.id, to: seg.index + 1) }.disabled(seg.index >= count - 1)
            if seg.index > 0, !model.doc.timeline.transitions.contains(where: { abs($0.time - seg.start) < 0.05 }) {
                Button("Dip to Black Before This Shot") {
                    model.apply([.add(.addTransition, GlintCore.Transition(time: seg.start, kind: .dipBlack))], label: "Dip to black")
                }
            }
            Divider()
            Button("Remove Shot", role: .destructive) {
                model.apply([EditOperation(.removeClip, id: c.id)], label: "Remove shot \(c.name)")
                if model.selection == .clip(c.id) { model.selection = nil }
            }.disabled(count <= 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shot \(seg.index + 1) of \(count), \(c.name)\(c.primary ? ", recording" : ", imported")\(c.scene.map { ", scene \($0)" } ?? "")")
        .accessibilityValue("\(Theme.time(v0, precise: true)) to \(Theme.time(v1, precise: true))")
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selection = .clip(c.id) }
    }

    func transitionMarker(_ tr: GlintCore.Transition, sc: TimelineScale) -> some View {
        let sel = model.selection == .transition(tr.id)
        let white = tr.kind == .dipWhite
        let name = white ? "Dip to white" : "Dip to black"
        let fill: Color = white ? .white : .black
        let stroke: Color = sel ? Theme.accent : Color.white.opacity(0.7)
        let diamond = RoundedRectangle(cornerRadius: 2).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(stroke, lineWidth: sel ? 2 : 1))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(45))
        return diamond
            .frame(width: 18, height: Self.shotsH)
            .contentShape(Rectangle())
            .offset(x: sc.x(tr.time) - 9)
            .zIndex(2)
            .help("\(name), \(String(format: "%.1fs", tr.duration))")
            .onTapGesture { model.selection = .transition(tr.id) }
            .contextMenu {
                Button("Remove Transition", role: .destructive) {
                    model.apply([EditOperation(.removeTransition, id: tr.id)], label: "Remove transition")
                    if model.selection == .transition(tr.id) { model.selection = nil }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue(Theme.time(sc.view(tr.time), precise: true))
            .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selection = .transition(tr.id) }
    }

    /// Thin lines through every lane where one shot ends and the next begins.
    func shotJoins(sc: TimelineScale, height: CGFloat) -> some View {
        let joins = model.clipLayout.segments.dropFirst().map { sc.x($0.start) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(joins.enumerated()), id: \.offset) { _, x in
                Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: height).offset(x: x)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Video (thumbnails, waveform, trims, speed, cuts, range)

    /// The filmstrip: fixed-width tiles, each showing the thumbnail nearest the source instant under its centre, so the
    /// strip follows the view (sped-up stretches get fewer tiles, cut footage none).
    func filmstrip(width: Double, sc: TimelineScale) -> some View {
        let thumbs = model.thumbnails
        let aspect = Double(max(1, model.doc.media.width)) / Double(max(1, model.doc.media.height))
        let tileW = max(40, Self.videoH * aspect)
        return Canvas { ctx, size in
            guard !thumbs.isEmpty else { return }
            var resolved: [Int: GraphicsContext.ResolvedImage] = [:]
            var x = 0.0
            while x < size.width {
                let t = sc.source(view: (x + tileW / 2) / sc.pps)
                // Nearest thumbnail by source time (they are few and sorted).
                var best = 0
                for (i, th) in thumbs.enumerated() where abs(th.0 - t) < abs(thumbs[best].0 - t) { best = i }
                let img = resolved[best] ?? ctx.resolve(Image(decorative: thumbs[best].1, scale: 1))
                resolved[best] = img
                let tile = CGRect(x: x, y: 0, width: min(tileW, size.width - x), height: size.height)
                // Aspect-fill the tile.
                let iw = Double(thumbs[best].1.width), ih = Double(thumbs[best].1.height)
                let k = max(tileW / max(1, iw), size.height / max(1, ih))
                let fill = CGRect(x: x + (tileW - iw * k) / 2, y: (size.height - ih * k) / 2, width: iw * k, height: ih * k)
                ctx.drawLayer { l in l.clip(to: Path(tile)); l.draw(img, in: fill) }
                x += tileW
            }
        }
        .frame(width: width, height: Self.videoH)
    }

    /// Peaks along the view: each 2-point column takes the loudest program bucket among the source it shows.
    func waveformView(width: Double, sc: TimelineScale) -> some View {
        let wave = model.waveform, span = model.waveformSpan
        return Canvas { ctx, size in
            guard !wave.isEmpty, span > 0 else { return }
            let n = Double(wave.count)
            let peak = max(0.02, wave.max() ?? 1)
            let col = 2.0
            var x = 0.0
            while x < size.width {
                let v0 = x / sc.pps, v1 = (x + col) / sc.pps
                let s0 = sc.source(view: v0)
                var s1 = sc.source(view: v1, end: true)
                // A column that straddles a seam would otherwise sweep over the removed audio.
                if s1 < s0 || s1 - s0 > (v1 - v0) * 16 + 1e-6 { s1 = s0 + (v1 - v0) }
                let i0 = max(0, min(wave.count - 1, Int(s0 / span * n)))
                let i1 = max(i0 + 1, min(wave.count, Int((s1 / span * n).rounded(.up))))
                var m: Float = 0
                for i in i0..<i1 { m = max(m, wave[i]) }
                let h = Double(m / peak) * (size.height - 4)
                ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: col - 0.5, height: max(1, h))), with: .color(Theme.caption.opacity(0.55)))
                x += col
            }
        }
        .frame(width: width, height: Self.waveH)
    }

    func videoLane(width: Double, sc: TimelineScale) -> some View {
        let videoH = Self.videoH
        let pps = sc.pps
        return ZStack(alignment: .topLeading) {
            // Thumbnails.
            Group {
                if model.thumbnails.isEmpty {
                    Rectangle().fill(Theme.raised)
                        .overlay(alignment: .leading) {
                            if model.thumbnailsLoading {
                                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading thumbnails").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                                    .padding(.leading, 8)
                            }
                        }
                } else {
                    filmstrip(width: width, sc: sc)
                }
            }
            .frame(width: width, height: videoH)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            // Waveform.
            waveformView(width: width, sc: sc).offset(y: videoH)
                .accessibilityHidden(true)
            speedBands(sc: sc)
            cutMarks(sc: sc)
            // Range selection (view seconds while dragging; the selection itself is in source time).
            if let r = dragRange ?? { if case .range(let a, let b) = model.selection { return sc.viewSpan(a, b) }; return nil }() {
                Rectangle().fill(Theme.accent.opacity(0.22)).overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: max(1, abs(r.1 - r.0) * pps), height: videoH).offset(x: min(r.0, r.1) * pps).allowsHitTesting(false)
            }
            trimHandles(sc: sc)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in dragRange = (max(0, v.startLocation.x / pps), max(0, min(sc.duration, v.location.x / pps))) }
                .onEnded { _ in
                    if let r = dragRange, abs(r.1 - r.0) > 0.1 {
                        let a = sc.source(view: min(r.0, r.1)), b = sc.source(view: max(r.0, r.1), end: true)
                        if b - a > 0.05 { model.selection = .range(a, b) }
                    }
                    dragRange = nil
                }
        )
        .simultaneousGesture(SpatialTapGesture().onEnded { v in
            // A click on the bare track clears the selection; one on a speed band or a cut keeps what it selected.
            let x = v.location.x
            let onSpeed = v.location.y >= Self.videoH - 20 && v.location.y <= Self.videoH - 2
                && model.doc.timeline.speeds.contains { x >= sc.x($0.start) && x <= sc.x($0.end) }
            let onCut = v.location.y <= Self.videoH && model.doc.timeline.cuts.contains { c in
                let r = cutSpan(c, sc: sc)
                return x >= r.0 && x <= r.1
            }
            if !onSpeed && !onCut { model.selection = nil }
            seek(view: x / pps, sc)
        })
    }

    /// Speed changes as bands along the bottom of the video track (as wide as they play, in the edited view).
    func speedBands(sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.doc.timeline.speeds) { s in
                let sel = model.selection == .speed(s.id)
                let (lo, hi) = neighbours(model.doc.timeline.speeds, id: s.id, idOf: \.id, startOf: \.start, endOf: \.end)
                chip(id: s.id, start: s.start, end: s.end, sc: sc, height: 18, y: Self.videoH - 20, minLength: 0.1, lower: lo, upper: hi,
                     label: "Speed \(s.rate.formatted())×", selected: sel, tint: Theme.speed,
                     select: { model.selection = .speed(s.id) },
                     commit: { a, b, mode, rev in
                        model.apply([EditOperation(.updateSpeed, id: s.id, start: a, end: b)], label: mode == .move ? "Move speed change" : "Resize speed change",
                                    expectedRevision: rev)
                        model.selection = .speed(s.id)
                     }) {
                    Text("\(s.rate.formatted())×").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.speed.opacity(sel ? 0.55 : 0.32)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.speed, lineWidth: sel ? 2 : 1))
                }
                .help(s.reason ?? "Speed change. Drag to move, drag an edge to resize.")
            }
        }
    }

    /// Cuts: hatched in place in the original take; in the edited video the footage is gone, so a cut is a seam.
    func cutMarks(sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.doc.timeline.cuts) { c in cutMark(c, sc: sc) }
        }
    }

    /// Horizontal extent of a cut's mark, in points.
    func cutSpan(_ c: Cut, sc: TimelineScale) -> (Double, Double) {
        let x = sc.x(c.start)
        return sc.edited ? (x - 2, x + 2) : (x, x + max(3, c.range.duration * sc.pps))
    }

    func cutMark(_ c: Cut, sc: TimelineScale) -> some View {
        let sel = model.selection == .cut(c.id)
        let (x0, x1) = cutSpan(c, sc: sc)
        let value = "\(Theme.time(c.start, precise: true)) to \(Theme.time(c.end, precise: true)) of the original take"
        let traits: AccessibilityTraits = sel ? [.isButton, .isSelected] : .isButton
        let mark: AnyView = sc.edited
            ? AnyView(Capsule().fill(sel ? Theme.cut : Theme.cut.opacity(0.85)).frame(width: sel ? 4 : 2.5).frame(width: x1 - x0)
                .overlay(alignment: .top) { Image(systemName: "scissors").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.cut).offset(y: -1) })
            : AnyView(Hatch().fill(Theme.cut.opacity(0.75)).background(Color.black.opacity(0.55))
                .overlay(Rectangle().strokeBorder(Theme.cut, lineWidth: sel ? 2 : 0.5)))
        return mark
            .frame(width: x1 - x0, height: Self.videoH).contentShape(Rectangle()).offset(x: x0)
            .onTapGesture { model.selection = .cut(c.id) }
            .help(sc.edited ? "\(c.reason ?? "Cut"): \(Theme.time(c.range.duration, precise: true)) removed here. Switch to Original take to see it." : c.reason ?? "Cut")
            .accessibilityElement()
            .accessibilityLabel("Cut")
            .accessibilityValue(value)
            .accessibilityAddTraits(traits)
            .accessibilityAction { model.selection = .cut(c.id) }
    }

    /// Shading outside the kept range, and draggable in/out handles. In the edited view the trimmed ends aren't on
    /// the timeline, so the handles sit at its ends and can only trim further.
    @ViewBuilder func trimHandles(sc: TimelineScale) -> some View {
        let kept = model.doc.keptRange
        let pps = sc.pps
        let vs = resolved(id: "__trim_in", start: kept.start, end: kept.end, sc: sc, minLength: 0.2).view.0
        let ve = resolved(id: "__trim_out", start: kept.start, end: kept.end, sc: sc, minLength: 0.2).view.1
        let end = sc.view(model.doc.duration)
        if vs > 0 { Rectangle().fill(Color.black.opacity(0.6)).frame(width: vs * pps, height: Self.videoH).allowsHitTesting(false) }
        if ve < end { Rectangle().fill(Color.black.opacity(0.6)).frame(width: (end - ve) * pps, height: Self.videoH).offset(x: ve * pps).allowsHitTesting(false) }
        trimHandle(isIn: true, at: vs, kept: kept, sc: sc)
        trimHandle(isIn: false, at: ve, kept: kept, sc: sc)
    }

    func trimHandle(isIn: Bool, at v: Double, kept: TimeRange, sc: TimelineScale) -> some View {
        let id = isIn ? "__trim_in" : "__trim_out"
        let active = drag?.id == id
        let shape = UnevenRoundedRectangle(topLeadingRadius: isIn ? 4 : 0, bottomLeadingRadius: isIn ? 4 : 0,
                                           bottomTrailingRadius: isIn ? 0 : 4, topTrailingRadius: isIn ? 0 : 4, style: .continuous)
        return shape.fill(active ? Theme.accent : Color.white.opacity(0.85))
            .overlay(Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 16))
            .frame(width: 9, height: Self.videoH)
            .contentShape(Rectangle().inset(by: -3))
            .offset(x: isIn ? v * sc.pps : v * sc.pps - 9)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help(isIn ? "Start of the video. Drag to trim the beginning (I sets it at the playhead)." : "End of the video. Drag to trim the end (O sets it at the playhead).")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { g in track(id, isIn ? .leading : .trailing, Double(g.translation.width)) }
                .onEnded { _ in
                    let r = resolved(id: id, start: kept.start, end: kept.end, sc: sc, minLength: 0.2).source
                    let rev = drag?.revision
                    drag = nil
                    if isIn {
                        guard abs(r.0 - kept.start) > 0.004 else { return }
                        model.apply([EditOperation(.setTrim, start: r.0)], label: "Trim start", expectedRevision: rev)
                    } else {
                        guard abs(r.1 - kept.end) > 0.004 else { return }
                        // At the very end, clear the out point rather than pin it.
                        let op = r.1 >= model.doc.duration - 1e-3 ? EditOperation(.setTrim, value: .null) : EditOperation(.setTrim, end: r.1)
                        model.apply([op], label: "Trim end", expectedRevision: rev)
                    }
                })
            .accessibilityElement()
            .accessibilityLabel(isIn ? "In point" : "Out point")
            .accessibilityValue(Theme.time(isIn ? kept.start : kept.end, precise: true))
            .accessibilityAdjustableAction { dir in
                let step = dir == .increment ? 0.5 : -0.5
                if isIn { model.apply([EditOperation(.setTrim, start: max(0, min(kept.end - 0.2, kept.start + step)))], label: "Trim start") }
                else { model.apply([EditOperation(.setTrim, end: min(model.doc.duration, max(kept.start + 0.2, kept.end + step)))], label: "Trim end") }
            }
    }

    // MARK: Zoom

    func zoomLane(width: Double, sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.025)).frame(width: width, height: Self.laneH - 6).offset(y: 3)
                .gesture(SpatialTapGesture(count: 2).onEnded { v in
                    let t = sc.source(view: v.location.x / sc.pps)
                    model.apply([EditOperation(.addZoom, start: max(0, t - 0.3), end: min(model.doc.duration, t + 2.2), scale: 2, focus: .string("cursor"))], label: "Add zoom")
                })
                .accessibilityHidden(true)
            if model.doc.timeline.zooms.isEmpty { laneHint("Double-click here to add a zoom, or use Auto Zoom.") }
            ForEach(model.doc.timeline.zooms) { z in
                let sel = model.selection == .zoom(z.id)
                chip(id: z.id, start: z.start, end: z.end, sc: sc, height: Self.laneH - 8, y: 4, minLength: 0.3,
                     label: String(format: "Zoom %.1f×", z.scale), selected: sel, tint: Theme.zoom,
                     select: { model.selection = .zoom(z.id) },
                     commit: { a, b, mode, rev in
                        model.apply([EditOperation(.updateZoom, id: z.id, start: a, end: b)], label: mode == .move ? "Move zoom" : "Resize zoom", expectedRevision: rev)
                        model.selection = .zoom(z.id)
                     }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.zoom.opacity(sel ? 0.95 : 0.6))
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(sel ? 0.9 : 0.12), lineWidth: sel ? 1.5 : 1)
                        HStack(spacing: 3) {
                            Image(systemName: Theme.originIcon(z.origin)).font(.system(size: 8.5))
                            Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .bold))
                        }.foregroundStyle(Theme.onAccent).padding(.horizontal, 6).lineLimit(1)
                    }
                }
                .help(z.reason ?? "Zoom. Drag to move, drag an edge to resize.")
            }
        }
    }

    // MARK: Captions

    func captionLane(width: Double, sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            if model.doc.timeline.captions.isEmpty { laneHint("No captions. Use Captions in the toolbar.") }
            ForEach(model.doc.timeline.captions) { c in
                let sel = model.selection == .caption(c.id)
                let (lo, hi) = neighbours(model.doc.timeline.captions, id: c.id, idOf: \.id, startOf: \.start, endOf: \.end)
                chip(id: c.id, start: c.start, end: c.end, sc: sc, height: Self.laneH - 10, y: 5, minLength: 0.2, lower: lo, upper: hi,
                     label: "Caption: \(c.text)", selected: sel, tint: Theme.caption,
                     select: { model.selection = .caption(c.id) },
                     commit: { a, b, mode, rev in
                        // Only the span: the engine carries each word's timing with it (moved, or scaled on a resize).
                        model.apply([EditOperation(.updateCaption, id: c.id, start: a, end: b)],
                                    label: mode == .move ? "Move caption" : "Resize caption", expectedRevision: rev)
                        model.selection = .caption(c.id)
                     }) {
                    CaptionChip(caption: c, selected: sel, height: Self.laneH - 10)
                }
                .help(c.text)
            }
        }
    }

    // MARK: Overlays (callouts and masks)

    func overlayLane(width: Double, sc: TimelineScale) -> some View {
        let rows = Self.overlayRows(model.doc)
        return ZStack(alignment: .topLeading) {
            if rows.isEmpty { laneHint("No callouts or redactions. Pick a tool above the preview and drag on the frame.") }
            ForEach(rows, id: \.0.id) { item, row in
                let y = 4 + CGFloat(row) * Self.overlayRowH
                switch item.kind {
                case .annotation(let a):
                    let sel = model.selection == .annotation(a.id)
                    chip(id: a.id, start: a.start, end: a.end, sc: sc, height: Self.overlayRowH - 3, y: y, minLength: 0.1,
                         label: "\(Self.annotationName(a))", selected: sel, tint: TimelineColors.callout,
                         select: { selectOverlay(.annotation(a.id), start: a.start, end: a.end) },
                         commit: { s, e, mode, rev in
                            model.updateOverlay(.updateAnnotation, id: a.id, ["start": .number(s), "end": .number(e)], label: mode == .move ? "Move callout" : "Resize callout",
                                                expectedRevision: rev)
                            model.selection = .annotation(a.id)
                         }) {
                        overlayChipBody(icon: Self.annotationIcon(a.kind), title: Self.annotationName(a), tint: TimelineColors.callout, selected: sel)
                    }
                    .help("\(Self.annotationName(a)). Drag to move, drag an edge to change how long it shows.")
                case .redaction(let r):
                    let sel = model.selection == .redaction(r.id)
                    chip(id: r.id, start: r.start, end: r.end, sc: sc, height: Self.overlayRowH - 3, y: y, minLength: 0.1,
                         label: "Redaction, \(r.mode.rawValue)", selected: sel, tint: TimelineColors.mask,
                         select: { selectOverlay(.redaction(r.id), start: r.start, end: r.end) },
                         commit: { s, e, mode, rev in
                            model.updateOverlay(.updateRedaction, id: r.id, ["start": .number(s), "end": .number(e)], label: mode == .move ? "Move redaction" : "Resize redaction",
                                                expectedRevision: rev)
                            model.selection = .redaction(r.id)
                         }) {
                        overlayChipBody(icon: "eye.slash", title: r.label ?? "Redact (\(r.mode.rawValue))", tint: TimelineColors.mask, selected: sel)
                    }
                    .help("Redaction. Drag to move, drag an edge to change how long it hides the area.")
                }
            }
        }
    }

    /// Selecting an overlay moves the playhead into it when it isn't showing, so it can be edited on the preview.
    func selectOverlay(_ s: Selection, start: Double, end: Double) {
        model.selection = s
        if !(model.sourceTime >= start && model.sourceTime < end) { model.seek(source: min(end - 0.02, start + min(0.3, (end - start) / 2))) }
    }

    func overlayChipBody(icon: String, title: String, tint: Color, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
            Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(selected ? 0.6 : 0.3)))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(selected ? 1 : 0.5), lineWidth: selected ? 1.5 : 1))
    }

    static func annotationIcon(_ k: Annotation.Kind) -> String {
        switch k { case .box: "rectangle"; case .highlight: "light.max"; case .arrow: "arrow.up.right"; case .text: "textformat" }
    }
    static func annotationName(_ a: Annotation) -> String {
        switch a.kind {
        case .text: a.text.map { "Text: \($0)" } ?? "Text"
        case .box: "Box"; case .highlight: "Highlight"; case .arrow: "Arrow"
        }
    }

    // MARK: Voice and audio

    /// Voiceover clips: anchored at a program instant, drawn as long as they last once the picture is retimed
    /// (in the edited view that is exactly the clip's duration).
    func voiceLane(width: Double, sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.025)).frame(width: width, height: Self.laneH - 6).offset(y: 3)
            ForEach(model.doc.timeline.voiceover) { c in
                let sel = model.selection == .voice(c.id)
                let span = model.sourceSpan(of: c)
                chip(id: c.id, start: span.start, end: span.end, sc: sc, height: Self.laneH - 8, y: 4, minLength: 0.05,
                     upper: max(span.end, model.doc.duration), resizable: false, label: "Voiceover: \(c.text)", selected: sel, tint: Theme.voice,
                     select: { model.selection = .voice(c.id) },
                     commit: { s, _, _, rev in
                        model.apply([EditOperation(.updateVoiceover, id: c.id, start: max(0, min(model.doc.duration - 0.1, s)))], label: "Move voiceover", expectedRevision: rev)
                        model.selection = .voice(c.id)
                     }) {
                    Text(c.text)
                        .font(.system(size: 9.5)).lineLimit(1).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.voice.opacity(sel ? 0.95 : 0.65)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(sel ? 0.9 : 0.12), lineWidth: sel ? 1.5 : 1))
                }
                .help(c.text)
            }
        }
    }

    /// Music, imported voice and sound effects: drag to change where they start.
    func audioLane(width: Double, sc: TimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.025)).frame(width: width, height: Self.laneH - 6).offset(y: 3)
            ForEach(model.doc.timeline.audio) { a in
                let sel = model.selection == .audio(a.id)
                let span = model.sourceSpan(of: a)
                chip(id: a.id, start: span.start, end: span.end, sc: sc, height: Self.laneH - 8, y: 4, minLength: 0.05,
                     upper: max(span.end, model.doc.duration), resizable: false, label: "\(a.kind.rawValue.capitalized): \(a.name)", selected: sel,
                     tint: TimelineColors.audio,
                     select: { model.selection = .audio(a.id) },
                     commit: { s, _, _, rev in
                        model.apply([EditOperation(.updateAudio, id: a.id, start: max(0, min(model.doc.duration - 0.1, s)))], label: "Move \(a.kind.rawValue)", expectedRevision: rev)
                        model.selection = .audio(a.id)
                     }) {
                    HStack(spacing: 4) {
                        Image(systemName: a.kind == .music ? "music.note" : a.kind == .voice ? "mic" : "speaker.wave.2").font(.system(size: 8.5, weight: .semibold))
                        Text(a.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                        if a.loop { Image(systemName: "repeat").font(.system(size: 8)).foregroundStyle(Theme.text2) }
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(TimelineColors.audio.opacity(sel ? 0.55 : 0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(TimelineColors.audio.opacity(sel ? 1 : 0.5), lineWidth: sel ? 1.5 : 1))
                }
                .help("\(a.name). Drag to change where it starts.")
            }
        }
    }

    func playhead(sc: TimelineScale, height: CGFloat) -> some View {
        let x = playheadView(sc) * sc.pps
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: 1.5)
            Triangle().fill(Color.white).frame(width: 10, height: 7).offset(y: 0)
        }
        .frame(width: 10, height: height)
        .offset(x: x - 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Lane colours for the newer item kinds. Each means one thing: callouts, privacy masks, added audio.
enum TimelineColors {
    static let callout = Color(red: 0.94, green: 0.56, blue: 0.82)
    static let mask = Color(red: 0.62, green: 0.65, blue: 0.72)
    static let audio = Color(red: 0.76, green: 0.84, blue: 0.42)
}

struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height)); p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            p.addLine(to: CGPoint(x: x + rect.height + 2.5, y: 0)); p.addLine(to: CGPoint(x: x + 2.5, y: rect.height)); p.closeSubpath()
            x += 8
        }
        return p.intersection(Path(rect))
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() } }
}

struct CaptionChip: View {
    let caption: CaptionSegment
    let selected: Bool
    let height: CGFloat
    var body: some View {
        let fill: Color = Theme.caption.opacity(selected ? 0.6 : 0.3)
        let stroke: Color = Theme.caption.opacity(selected ? 1 : 0.4)
        return Text(caption.text)
            .font(.system(size: 9.5)).lineLimit(1)
            .foregroundStyle(caption.hidden ? Theme.text3 : Color.white)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke))
    }
}
