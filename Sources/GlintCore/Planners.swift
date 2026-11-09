import Foundation

// MARK: - Transcript

public struct Transcript: Codable, Hashable, Sendable {
    public var engine: String
    public var locale: String
    /// Which audio was transcribed ("microphone" / "system").
    public var source: String
    public var words: [CaptionWord]
    public var createdAt: Date
    public init(engine: String, locale: String, source: String, words: [CaptionWord], createdAt: Date = Date()) {
        self.engine = engine; self.locale = locale; self.source = source; self.words = words; self.createdAt = createdAt
    }
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Speech ranges: words merged when gaps are under `gap`.
    public func speechRanges(gap: Double = 0.6) -> [TimeRange] {
        var out: [TimeRange] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, w.start - last.end <= gap { last.end = max(last.end, w.end); out[out.count - 1] = last }
            else { out.append(TimeRange(w.start, w.end)) }
        }
        return out
    }
}

// MARK: - Zoom planning

public struct ZoomPlanOptions: Codable, Hashable, Sendable {
    public var scale: Double = 2.0
    public var minScale: Double = 1.4
    /// Seconds the zoom starts before the first action, so the camera has arrived when the click lands.
    public var leadIn: Double = 0.7
    /// Seconds the zoom holds after the last action.
    public var hold: Double = 2.2
    /// Actions closer than this (seconds) join one zoom if they fit in one view.
    public var mergeGap: Double = 2.5
    public var minDuration: Double = 1.8
    public var maxDuration: Double = 14
    /// Zooms separated by less than this are merged (or joined) to avoid an out-in "pump".
    public var minGapBetween: Double = 2.0
    public var includeTyping = true
    public var includeClicks = true
    public var includeScrolls = false
    public init() {}
}

public enum ZoomPlanner {
    struct Action { var start: Double; var end: Double; var points: [NormPoint]; var label: String }

    public static func plan(document: ProjectDocument, events: EventLog, options: ZoomPlanOptions = .init()) -> [ZoomSegment] {
        let kept = document.keptRange
        let cuts = document.timeline.cuts.map(\.range)
        // Actions in the final second don't get a zoom (the video is about to end).
        func isKept(_ t: Double) -> Bool { kept.contains(t) && t < kept.end - 1.0 && !cuts.contains(where: { $0.contains(t) }) }

        var actions: [Action] = []
        if options.includeClicks {
            for c in events.clicks where isKept(c.t) {
                let label = c.target.map { "click “\($0)”" } ?? "click"
                actions.append(Action(start: c.t, end: c.up ?? c.t, points: [c.point], label: label))
            }
        }
        if options.includeTyping {
            for b in Activity.bursts(events.keys.map(\.t), gap: 1.2, minCount: 3) where isKept(b.start) {
                // Typing happens where the user last clicked (the focused field), else where the pointer is.
                let anchor = events.clicks.last(where: { $0.t <= b.start })?.point
                    ?? Activity.pointer(at: b.start, in: events.pointer) ?? .center
                actions.append(Action(start: b.start, end: b.end, points: [anchor], label: "typing"))
            }
        }
        if options.includeScrolls {
            for b in Activity.bursts(events.scrolls.map(\.t), gap: 0.5, minCount: 3) where isKept(b.start) {
                let p = Activity.pointer(at: b.start, in: events.pointer) ?? .center
                actions.append(Action(start: b.start, end: b.end, points: [p], label: "scroll"))
            }
        }
        actions.sort { $0.start < $1.start }
        guard !actions.isEmpty else { return [] }

        func fits(_ pts: [NormPoint], scale: Double) -> Bool {
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
            let view = 0.8 / scale
            return w <= view && h <= view
        }

        // 1. Greedy clustering in time + space.
        var clusters: [[Action]] = []
        for a in actions {
            if var last = clusters.last, let lastEnd = last.map(\.end).max(),
               a.start - lastEnd <= options.mergeGap,
               fits(last.flatMap(\.points) + a.points, scale: options.minScale),
               a.end - (last.first!.start) <= options.maxDuration {
                last.append(a); clusters[clusters.count - 1] = last
            } else {
                clusters.append([a])
            }
        }

        // 2. Clusters → segments.
        var segs: [(range: TimeRange, points: [NormPoint], labels: [String])] = clusters.map { c in
            let s = max(kept.start, c.first!.start - options.leadIn)
            var e = min(kept.end - 0.8, c.map(\.end).max()! + options.hold)
            if e - s < options.minDuration { e = min(kept.end - 0.8, s + options.minDuration) }
            if e <= s { e = s + 0.5 }
            return (TimeRange(s, e), c.flatMap(\.points), c.map(\.label))
        }

        // 3. Resolve near/overlapping neighbours: merge when they still fit one view, otherwise butt them together
        //    so the camera pans straight from one to the next instead of zooming out and back in.
        var merged: [(range: TimeRange, points: [NormPoint], labels: [String])] = []
        for s in segs {
            if var last = merged.last, s.range.start - last.range.end < options.minGapBetween {
                if fits(last.points + s.points, scale: options.minScale), s.range.end - last.range.start <= options.maxDuration {
                    last.range = TimeRange(last.range.start, max(last.range.end, s.range.end))
                    last.points += s.points; last.labels += s.labels
                    merged[merged.count - 1] = last
                } else {
                    let mid = max(last.range.start + 0.5, min(last.range.end, s.range.start))
                    last.range = TimeRange(last.range.start, mid)
                    merged[merged.count - 1] = last
                    merged.append((TimeRange(mid, max(mid + 0.5, s.range.end)), s.points, s.labels))
                }
            } else {
                merged.append(s)
            }
        }
        segs = merged

        return segs.map { s in
            let xs = s.points.map(\.x), ys = s.points.map(\.y)
            let extent = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            let scale = max(options.minScale, min(options.scale, extent > 0 ? 0.8 / extent : options.scale))
            let counts = Dictionary(grouping: s.labels, by: { $0 }).map { "\($0.value.count > 1 ? "\($0.value.count)× " : "")\($0.key)" }.sorted()
            return ZoomSegment(start: round3(s.range.start), end: round3(s.range.end), scale: round3(scale), focus: .followCursor,
                               origin: .auto, reason: counts.joined(separator: ", "))
        }
    }
}

@inline(__always) func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

// MARK: - Cut / speed planning

public struct CutPlanOptions: Codable, Hashable, Sendable {
    /// Silences (no speech) at least this long are shortened.
    public var minSilence: Double = 1.0
    /// Speech-free time kept on each side of a cut.
    public var padding: Double = 0.3
    /// Silent stretches that contain on-screen activity are sped up instead of cut.
    public var activityRate: Double = 3
    /// Idle stretches (no input) at least this long get sped up when there's no speech track.
    public var minIdle: Double = 2.5
    public var idleRate: Double = 4
    /// Silent typing at least this long gets sped up.
    public var minTyping: Double = 2.0
    public var typingRate: Double = 2.5
    public var removeFillers = true
    public var trimEnds = true
    public init() {}
}

public struct CutPlan: Codable, Hashable, Sendable {
    public var cuts: [Cut]
    public var speeds: [SpeedSegment]
    public var inPoint: Double?
    public var outPoint: Double?
    public var notes: [String]
}

public enum CutPlanner {
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "ah", "hmm", "mm", "uh-huh"]

    /// `silences` are speech-free ranges measured on the microphone (from audio analysis); pass nil when there is
    /// no voice track — then only idle/typing speed-ups and end trimming are planned.
    public static func plan(document: ProjectDocument, events: EventLog, transcript: Transcript?, silences: [TimeRange]?,
                            options: CutPlanOptions = .init()) -> CutPlan {
        let kept = document.keptRange
        var cuts: [Cut] = [], speeds: [SpeedSegment] = [], notes: [String] = []
        let clickTimes = events.clicks.map(\.t)
        let typing = Activity.bursts(events.keys.map(\.t), gap: 1.2, minCount: 3)
        let idle = Activity.idleRanges(events, duration: document.media.duration, minDuration: 0.5)
        func activity(in r: TimeRange) -> Bool {
            if clickTimes.contains(where: { r.contains($0) }) { return true }
            if typing.contains(where: { $0.end > r.start && $0.start < r.end }) { return true }
            // Pointer moving for more than a third of the range counts as activity.
            let idleInside = idle.compactMap { $0.clamped(to: r)?.duration }.reduce(0, +)
            return idleInside < r.duration * 0.66
        }
        let speech = transcript?.speechRanges() ?? []
        func speaking(_ r: TimeRange) -> Bool { speech.contains(where: { $0.overlaps(r) }) }

        // Silence handling.
        if let silences {
            for s in silences where s.duration >= options.minSilence {
                guard let inner = TimeRange(s.start + options.padding, s.end - options.padding).clamped(to: kept), inner.duration >= 0.3 else { continue }
                if activity(in: inner) {
                    if inner.duration >= 1.5 {
                        speeds.append(SpeedSegment(start: round3(inner.start), end: round3(inner.end), rate: options.activityRate, origin: .auto,
                                                   reason: "silent stretch with on-screen activity"))
                    }
                } else {
                    cuts.append(Cut(start: round3(inner.start), end: round3(inner.end), origin: .auto, reason: String(format: "%.1fs pause", s.duration)))
                }
            }
        } else {
            // No voice: speed up idle waiting (page loads, builds) and long typing.
            for r in Activity.idleRanges(events, duration: document.media.duration, minDuration: options.minIdle) {
                guard let inner = TimeRange(r.start + 0.4, r.end - 0.4).clamped(to: kept), inner.duration >= 1 else { continue }
                speeds.append(SpeedSegment(start: round3(inner.start), end: round3(inner.end), rate: options.idleRate, origin: .auto,
                                           reason: String(format: "%.1fs without input", r.duration)))
            }
        }
        for b in typing where b.end - b.start >= options.minTyping {
            let r = TimeRange(b.start + 0.3, b.end - 0.2)
            guard r.duration > 1, !speaking(r), !speeds.contains(where: { $0.range.overlaps(r) }), !cuts.contains(where: { $0.range.overlaps(r) }) else { continue }
            speeds.append(SpeedSegment(start: round3(r.start), end: round3(r.end), rate: options.typingRate, origin: .auto, reason: "typing (\(b.count) keys)"))
        }
        // Fillers.
        if options.removeFillers, let words = transcript?.words {
            for w in words {
                let norm = w.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                guard fillers.contains(norm) else { continue }
                let r = TimeRange(w.start - 0.04, w.end + 0.04)
                guard kept.contains(r.start), !cuts.contains(where: { $0.range.overlaps(r) }) else { continue }
                cuts.append(Cut(start: round3(r.start), end: round3(r.end), origin: .auto, reason: "filler “\(w.text)”"))
            }
        }
        // Trim ends to the first/last thing worth seeing.
        var inPoint: Double?, outPoint: Double?
        if options.trimEnds {
            let marks = clickTimes + events.keys.map(\.t) + speech.flatMap { [$0.start, $0.end] }
            if let first = marks.min(), first - 0.8 > kept.start + 0.3 { inPoint = round3(first - 0.8); notes.append("trim start to 0.8s before first action") }
            if let last = marks.max(), last + 1.5 < kept.end - 0.3 { outPoint = round3(last + 1.5); notes.append("trim end to 1.5s after last action") }
            if let ip = inPoint { cuts.removeAll { $0.end <= ip }; speeds.removeAll { $0.end <= ip } }
            if let op = outPoint { cuts.removeAll { $0.start >= op }; speeds.removeAll { $0.start >= op } }
        }
        cuts.sort { $0.start < $1.start }; speeds.sort { $0.start < $1.start }
        let saved = cuts.reduce(0) { $0 + $1.range.duration } + speeds.reduce(0) { $0 + $1.range.duration * (1 - 1 / $1.rate) }
        notes.append(String(format: "saves ≈ %.1fs", saved + (inPoint.map { $0 - kept.start } ?? 0) + (outPoint.map { kept.end - $0 } ?? 0)))
        return CutPlan(cuts: cuts, speeds: speeds, inPoint: inPoint, outPoint: outPoint, notes: notes)
    }
}

// MARK: - Captions

public enum CaptionBuilder {
    public static func segments(from words: [CaptionWord], maxChars: Int = 42, maxDuration: Double = 4.0, pauseBreak: Double = 0.6) -> [CaptionSegment] {
        var out: [CaptionSegment] = []
        var cur: [CaptionWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let text = cur.map(\.text).joined(separator: " ")
            out.append(CaptionSegment(start: round3(f.start), end: round3(max(l.end, f.start + 0.6)), text: text, words: cur))
            cur = []
        }
        for w in words.sorted(by: { $0.start < $1.start }) {
            let clean = w.text.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let word = CaptionWord(text: clean, start: w.start, end: w.end)
            if let last = cur.last, let first = cur.first {
                let len = cur.map(\.text).joined(separator: " ").count + 1 + clean.count
                let pause = word.start - last.end
                if len > maxChars || word.end - first.start > maxDuration || pause > pauseBreak { flush() }
            }
            cur.append(word)
            if let ch = clean.last, ".?!".contains(ch), cur.count >= 3 { flush() }
        }
        flush()
        // Avoid overlaps.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start { out[i].end = out[i + 1].start }
        return out
    }
}
