import SwiftUI
import GlintCore

/// Timeline in recording (source) time, so items stay anchored to content: cuts are shown hatched in place,
/// speed changes as bands, zooms as draggable/resizable capsules on their own lane.
struct TimelineEditor: View {
    let model: EditorModel
    @State private var zoomLevel: Double = 1
    @State private var dragRange: (Double, Double)?
    @State private var drag: (id: String, mode: Int, dx: Double)?   // mode 0 move, 1 left edge, 2 right edge

    let labelWidth: CGFloat = 88
    let rulerH: CGFloat = 22, videoH: CGFloat = 58, waveH: CGFloat = 22, laneH: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let duration = max(0.1, model.doc.media.duration)
            let avail = max(200, geo.size.width - labelWidth - 24)
            let pps = avail / duration * zoomLevel
            let contentW = duration * pps
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Timeline").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    Text("recording time · cuts hatched · ⌫ deletes selection · drag on video to select · double-click zoom lane to add")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.text3)
                    Slider(value: $zoomLevel, in: 1...12).frame(width: 120).controlSize(.mini)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: rulerH)
                        laneLabel("Video", "film").frame(height: videoH + waveH)
                        laneLabel("Zoom", "plus.magnifyingglass").frame(height: laneH)
                        laneLabel("Captions", "captions.bubble").frame(height: laneH)
                    }
                    .frame(width: labelWidth)
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                ruler(width: contentW, pps: pps, duration: duration).frame(height: rulerH)
                                videoLane(width: contentW, pps: pps).frame(height: videoH + waveH)
                                zoomLane(width: contentW, pps: pps).frame(height: laneH)
                                captionLane(width: contentW, pps: pps).frame(height: laneH)
                            }
                            playhead(pps: pps)
                        }
                        .frame(width: contentW, alignment: .leading)
                        .padding(.trailing, 12)
                    }
                }
            }
        }
        .background(Theme.panel)
    }

    func laneLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 9.5)); Text(t).font(.system(size: 10.5, weight: .medium)) }
            .foregroundStyle(Theme.text3).padding(.leading, 12).frame(maxHeight: .infinity, alignment: .center)
    }

    func ruler(width: Double, pps: Double, duration: Double) -> some View {
        let step: Double = pps > 160 ? 0.5 : pps > 60 ? 1 : pps > 25 ? 2 : pps > 10 ? 5 : 10
        return Canvas { ctx, size in
            var t = 0.0
            while t <= duration {
                let x = t * pps
                let major = (t / step).rounded() .truncatingRemainder(dividingBy: 2) == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (major ? 8 : 4), width: 1, height: major ? 8 : 4)), with: .color(.white.opacity(0.25)))
                if major { ctx.draw(Text(Theme.time(t)).font(.system(size: 9.5, design: .monospaced)).foregroundColor(Theme.text3), at: CGPoint(x: x + 3, y: 7), anchor: .leading) }
                t += step
            }
            for m in model.doc.timeline.markers {
                let x = m.time * pps
                ctx.fill(Path(CGRect(x: x, y: 2, width: 2, height: size.height - 2)), with: .color(Theme.speed))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.seek(source: max(0, v.location.x / pps)) })
        .overlay(alignment: .topLeading) {
            ForEach(model.doc.timeline.markers) { m in
                Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Theme.speed).offset(x: m.time * pps + 2, y: 1).help(m.note)
            }
        }
    }

    func videoLane(width: Double, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            // Thumbnails.
            HStack(spacing: 0) {
                if model.thumbnails.isEmpty { Rectangle().fill(Theme.raised) }
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, t in
                    Image(decorative: t.1, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / Double(max(1, model.thumbnails.count)), height: videoH).clipped()
                }
            }
            .frame(width: width, height: videoH)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            // Waveform.
            Canvas { ctx, size in
                guard !model.waveform.isEmpty else { return }
                let n = model.waveform.count
                let peak = max(0.02, model.waveform.max() ?? 1)
                for (i, v) in model.waveform.enumerated() {
                    let x = Double(i) / Double(n) * size.width
                    let h = Double(v / peak) * (size.height - 4)
                    ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: max(1, size.width / Double(n) - 0.5), height: max(1, h))), with: .color(Theme.caption.opacity(0.55)))
                }
            }
            .frame(width: width, height: waveH).offset(y: videoH)
            // Out-of-range (trim) shading.
            let kept = model.doc.keptRange
            if kept.start > 0 { Rectangle().fill(Color.black.opacity(0.6)).frame(width: kept.start * pps, height: videoH) }
            if kept.end < model.doc.media.duration { Rectangle().fill(Color.black.opacity(0.6)).frame(width: (model.doc.media.duration - kept.end) * pps, height: videoH).offset(x: kept.end * pps) }
            // Speed bands.
            ForEach(model.doc.timeline.speeds) { s in
                let sel = model.selection == .speed(s.id)
                RoundedRectangle(cornerRadius: 4).fill(Theme.speed.opacity(sel ? 0.55 : 0.32))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.speed, lineWidth: sel ? 2 : 1))
                    .overlay(Text("\(s.rate.formatted())×").font(.system(size: 10, weight: .bold)).foregroundStyle(.white), alignment: .topLeading).padding(0)
                    .frame(width: max(4, s.range.duration * pps), height: 18).offset(x: s.start * pps, y: videoH - 20)
                    .onTapGesture { model.selection = .speed(s.id) }
                    .help(s.reason ?? "speed")
            }
            // Cuts (hatched).
            ForEach(model.doc.timeline.cuts) { c in
                let sel = model.selection == .cut(c.id)
                Hatch().fill(Theme.cut.opacity(0.75)).background(Color.black.opacity(0.55))
                    .overlay(Rectangle().strokeBorder(Theme.cut, lineWidth: sel ? 2 : 0.5))
                    .frame(width: max(3, c.range.duration * pps), height: videoH).offset(x: c.start * pps)
                    .onTapGesture { model.selection = .cut(c.id) }
                    .help(c.reason ?? "cut")
            }
            // Range selection.
            if let r = dragRange ?? { if case .range(let a, let b) = model.selection { return (a, b) }; return nil }() {
                Rectangle().fill(Theme.accent.opacity(0.22)).overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: max(1, abs(r.1 - r.0) * pps), height: videoH).offset(x: min(r.0, r.1) * pps).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in dragRange = (max(0, v.startLocation.x / pps), max(0, min(model.doc.media.duration, v.location.x / pps))) }
                .onEnded { _ in
                    if let r = dragRange, abs(r.1 - r.0) > 0.1 { model.selection = .range(min(r.0, r.1), max(r.0, r.1)) }
                    dragRange = nil
                }
        )
        .simultaneousGesture(SpatialTapGesture().onEnded { v in model.selection = nil; model.seek(source: v.location.x / pps) })
    }

    func zoomLane(width: Double, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.025)).frame(width: width, height: laneH - 6).offset(y: 3)
                .onTapGesture(count: 2) { }
                .gesture(SpatialTapGesture(count: 2).onEnded { v in
                    let t = v.location.x / pps
                    model.apply([EditOperation(.addZoom, start: max(0, t - 0.3), end: min(model.doc.media.duration, t + 2.2), scale: 2, focus: .string("cursor"))], label: "Add zoom")
                })
            ForEach(model.doc.timeline.zooms) { z in
                let sel = model.selection == .zoom(z.id)
                let d = drag?.id == z.id ? drag : nil
                let start = z.start * pps + ((d?.mode == 0 || d?.mode == 1) ? d!.dx : 0)
                let end = z.end * pps + ((d?.mode == 0 || d?.mode == 2) ? d!.dx : 0)
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Theme.zoom.opacity(sel ? 0.95 : 0.7), Theme.accent2.opacity(sel ? 0.7 : 0.45)], startPoint: .leading, endPoint: .trailing))
                    Capsule().strokeBorder(.white.opacity(sel ? 0.9 : 0.15), lineWidth: sel ? 1.5 : 1)
                    HStack(spacing: 3) {
                        Image(systemName: z.origin == .agent ? "sparkles" : z.origin == .auto ? "wand.and.stars" : "plus.magnifyingglass").font(.system(size: 8.5))
                        Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .bold))
                    }.foregroundStyle(.white).padding(.horizontal, 6).lineLimit(1)
                    HStack { edge(z, 1, pps); Spacer(); edge(z, 2, pps) }
                }
                .frame(width: max(14, end - start), height: laneH - 8)
                .offset(x: start, y: 4)
                .help(z.reason ?? "zoom")
                .onTapGesture { model.selection = .zoom(z.id) }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in drag = (id: z.id, mode: 0, dx: Double(v.translation.width)) }
                    .onEnded { v in commit(z, mode: 0, dx: Double(v.translation.width), pps: pps) })
            }
        }
    }

    func edge(_ z: ZoomSegment, _ mode: Int, _ pps: Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in drag = (id: z.id, mode: mode, dx: Double(v.translation.width)) }
                .onEnded { v in commit(z, mode: mode, dx: Double(v.translation.width), pps: pps) })
    }

    func commit(_ z: ZoomSegment, mode: Int, dx: Double, pps: Double) {
        drag = nil
        let dt = dx / pps
        guard abs(dt) > 0.01 else { return }
        var s = z.start, e = z.end
        if mode == 0 { let shift = max(-s, min(model.doc.media.duration - e, dt)); s += shift; e += shift }
        if mode == 1 { s = max(0, min(e - 0.3, s + dt)) }
        if mode == 2 { e = min(model.doc.media.duration, max(s + 0.3, e + dt)) }
        model.apply([EditOperation(.updateZoom, id: z.id, start: s, end: e)], label: mode == 0 ? "Move zoom" : "Resize zoom")
        model.selection = .zoom(z.id)
    }

    func captionLane(width: Double, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.doc.timeline.captions) { c in
                CaptionChip(caption: c, selected: model.selection == .caption(c.id), pps: pps, height: laneH - 10)
                    .offset(x: c.start * pps, y: 5)
                    .onTapGesture { model.selection = .caption(c.id) }
            }
        }
    }

    func playhead(pps: Double) -> some View {
        let x = model.sourceTime * pps
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: 1.5)
            Triangle().fill(Color.white).frame(width: 10, height: 7).offset(y: 0)
        }
        .frame(width: 10, height: rulerH + videoH + waveH + laneH * 2)
        .offset(x: x - 5)
        .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
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
    let pps: Double
    let height: CGFloat
    var body: some View {
        let w: CGFloat = max(6, CGFloat((caption.end - caption.start) * pps) - 2)
        let fill: Color = Theme.caption.opacity(selected ? 0.6 : 0.3)
        let stroke: Color = Theme.caption.opacity(selected ? 1 : 0.4)
        return Text(caption.text)
            .font(.system(size: 9.5)).lineLimit(1)
            .foregroundStyle(caption.hidden ? Theme.text3 : Color.white)
            .padding(.horizontal, 5)
            .frame(width: w, height: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke))
    }
}
