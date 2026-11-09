import Foundation

/// A measurable check with a verdict, so agents can iterate toward thresholds instead of guessing.
public struct QualityCheck: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable { case pass, warn, fail, info }
    public var id: String
    public var verdict: Verdict
    public var value: Double?
    public var threshold: String?
    public var message: String
    /// Concrete suggestion an agent can act on.
    public var fix: String?
    public init(_ id: String, _ verdict: Verdict, value: Double? = nil, threshold: String? = nil, _ message: String, fix: String? = nil) {
        self.id = id; self.verdict = verdict; self.value = value; self.threshold = threshold; self.message = message; self.fix = fix
    }
}

public struct QualityReport: Codable, Hashable, Sendable {
    public var score: Int
    public var checks: [QualityCheck]
    public var metrics: [String: Double]
    public init(checks: [QualityCheck], metrics: [String: Double]) {
        self.checks = checks
        self.metrics = metrics
        let penalty = checks.reduce(0) { $0 + ($1.verdict == .fail ? 18 : $1.verdict == .warn ? 6 : 0) }
        score = max(0, 100 - penalty)
    }
    public var failures: [QualityCheck] { checks.filter { $0.verdict == .fail } }
}

/// Edit-level quality: computed from the document, events, transcript and the simulated camera — no rendering.
public enum EditQuality {
    public static func report(document doc: ProjectDocument, events: EventLog, transcript: Transcript?, targetDuration: Double? = nil,
                              outputWidth: Double = 1920, outputHeight: Double = 1080) -> QualityReport {
        let map = TimeMap(document: doc)
        let out = map.outputDuration
        var checks: [QualityCheck] = []
        var metrics: [String: Double] = ["output_duration": out, "source_duration": doc.media.duration]

        // Duration vs target.
        if let target = targetDuration, target > 0 {
            let ratio = out / target
            metrics["duration_ratio"] = ratio
            checks.append(QualityCheck("duration_target", abs(ratio - 1) <= 0.1 ? .pass : abs(ratio - 1) <= 0.25 ? .warn : .fail,
                                       value: out, threshold: String(format: "%.1fs ±10%%", target),
                                       String(format: "Output is %.1fs (target %.1fs)", out, target),
                                       fix: ratio > 1 ? "plan_cuts or set_speed on idle/typing stretches" : "remove cuts or slow segments"))
        }

        // Zooms.
        let layout = CanvasLayout(document: doc, outputWidth: outputWidth, outputHeight: outputHeight)
        let cursor = CursorPath(log: events, duration: doc.media.duration, style: doc.style.cursor)
        let camera = CameraPath(document: doc, map: map, cursor: cursor, layout: layout)
        let zoomSpans = doc.timeline.zooms.compactMap { z in map.outputSpan(forSource: z.range).map { (z, $0) } }.sorted { $0.1.start < $1.1.start }
        let zoomed = zoomSpans.reduce(0) { $0 + $1.1.duration }
        let coverage = out > 0 ? zoomed / out : 0
        metrics["zoom_count"] = Double(zoomSpans.count)
        metrics["zoom_coverage"] = coverage
        let keptClicks = events.clicks.filter { map.output(forSource: $0.t) != nil }.count
        if zoomSpans.isEmpty {
            checks.append(QualityCheck("zoom_presence", keptClicks >= 2 ? .warn : .info, value: 0,
                                       "No zooms; \(keptClicks) clicks in the output", fix: keptClicks >= 2 ? "plan_zooms" : nil))
        } else {
            checks.append(QualityCheck("zoom_coverage", coverage <= 0.75 ? .pass : .warn, value: coverage, threshold: "≤ 0.75",
                                       String(format: "%.0f%% of the video is zoomed", coverage * 100),
                                       fix: coverage > 0.75 ? "remove or shorten some zooms so viewers keep context" : nil))
        }
        let short = zoomSpans.filter { $0.1.duration < 1.2 }
        checks.append(QualityCheck("zoom_min_duration", short.isEmpty ? .pass : .warn, value: Double(short.count), threshold: "≥ 1.2s",
                                   short.isEmpty ? "All zooms last at least 1.2s" : "\(short.count) zoom(s) shorter than 1.2s feel abrupt: \(short.map(\.0.id).joined(separator: ", "))",
                                   fix: short.isEmpty ? nil : "extend or remove them"))
        var pumps: [String] = []
        for (a, b) in zip(zoomSpans, zoomSpans.dropFirst()) where b.1.start - a.1.end > 0.01 && b.1.start - a.1.end < 0.7 {
            pumps.append("\(a.0.id)→\(b.0.id)")
        }
        checks.append(QualityCheck("zoom_pumping", pumps.isEmpty ? .pass : .warn, value: Double(pumps.count), threshold: "gap ≥ 0.7s or 0",
                                   pumps.isEmpty ? "No zoom out-and-back-in within 0.7s" : "Zoom out/in pumps between \(pumps.joined(separator: ", "))",
                                   fix: pumps.isEmpty ? nil : "merge those zooms or join them end-to-start"))

        // Cursor visibility while zoomed: sample the camera and check the cursor is inside the viewport.
        if !cursor.isEmpty && zoomed > 0 {
            var inside = 0, total = 0
            var t = 0.0
            while t < out {
                let cam = camera.state(at: t)
                if cam.scale > 1.15 {
                    let p = layout.canvasPoint(cursor.position(at: map.source(forOutput: t)))
                    let half = 0.5 / cam.scale
                    total += 1
                    if abs(p.x - cam.cx) <= half && abs(p.y - cam.cy) <= half { inside += 1 }
                }
                t += 1.0 / 15
            }
            let frac = total > 0 ? Double(inside) / Double(total) : 1
            metrics["cursor_in_view"] = frac
            checks.append(QualityCheck("cursor_in_view", frac >= 0.9 ? .pass : frac >= 0.75 ? .warn : .fail, value: frac, threshold: "≥ 0.9",
                                       String(format: "Cursor visible in %.0f%% of zoomed frames", frac * 100),
                                       fix: frac < 0.9 ? "lower zoom scale, use focus \"cursor\", or shorten zooms that outlast the action" : nil))
        }
        // Camera speed (jerkiness).
        let maxSpeed = camera.samples.map(\.speed).max() ?? 0
        metrics["camera_max_speed"] = maxSpeed
        checks.append(QualityCheck("camera_speed", maxSpeed <= 3.0 ? .pass : maxSpeed <= 4.5 ? .warn : .fail, value: maxSpeed, threshold: "≤ 3 canvas/s",
                                   String(format: "Peak camera speed %.2f canvas widths/s", maxSpeed),
                                   fix: maxSpeed > 3 ? "lower style.zoom.stiffness or reduce scale differences between adjacent zooms" : nil))

        // Pacing: dead air in the output (no input and no speech).
        let speech = transcript?.speechRanges() ?? []
        let idle = Activity.idleRanges(events, duration: doc.media.duration, minDuration: 0.5)
        var dead: [TimeRange] = []
        for r in idle {
            var pieces = [r]
            for s in speech { pieces = pieces.flatMap { p -> [TimeRange] in
                guard p.overlaps(s) else { return [p] }
                return [TimeRange(p.start, s.start), TimeRange(s.end, p.end)].filter { $0.duration > 0 }
            } }
            for p in pieces { for o in map.outputRanges(forSource: p) where o.duration >= 3 { dead.append(o) } }
        }
        let deadTotal = dead.reduce(0) { $0 + $1.duration }
        metrics["dead_air_seconds"] = deadTotal
        checks.append(QualityCheck("dead_air", dead.isEmpty ? .pass : deadTotal > 8 ? .fail : .warn, value: deadTotal, threshold: "no stretch ≥ 3s",
                                   dead.isEmpty ? "No stretch of 3s+ without input or speech" : String(format: "%d stretch(es), %.1fs total, with nothing happening (first at %.1fs output)", dead.count, deadTotal, dead[0].start),
                                   fix: dead.isEmpty ? nil : "plan_cuts, or set_speed 3–4× on those ranges (time_base output)"))

        // Fragments: tiny kept pieces between cuts look like glitches.
        let tiny = map.pieces.filter { $0.outputDuration < 0.35 }
        checks.append(QualityCheck("jump_fragments", tiny.isEmpty ? .pass : .warn, value: Double(tiny.count), threshold: "≥ 0.35s",
                                   tiny.isEmpty ? "No kept fragment under 0.35s" : "\(tiny.count) kept fragment(s) under 0.35s between cuts",
                                   fix: tiny.isEmpty ? nil : "merge adjacent cuts"))

        // Captions.
        let caps = doc.timeline.captions.filter { !$0.hidden }
        if doc.style.captions.enabled && !caps.isEmpty {
            var fast = 0, long = 0
            for c in caps {
                let d = (map.outputSpan(forSource: TimeRange(c.start, c.end))?.duration ?? 0)
                if d > 0 && Double(c.text.count) / d > 20 { fast += 1 }
                if c.text.count > doc.style.captions.maxCharsPerLine + 4 { long += 1 }
            }
            metrics["caption_count"] = Double(caps.count)
            checks.append(QualityCheck("caption_reading_speed", fast == 0 ? .pass : .warn, value: Double(fast), threshold: "≤ 20 chars/s",
                                       fast == 0 ? "All captions readable (≤ 20 chars/s)" : "\(fast) caption(s) faster than 20 chars/s",
                                       fix: fast == 0 ? nil : "split captions or avoid speeding up speech"))
            checks.append(QualityCheck("caption_length", long == 0 ? .pass : .warn, value: Double(long), threshold: "≤ \(doc.style.captions.maxCharsPerLine) chars",
                                       long == 0 ? "Caption lines fit" : "\(long) caption(s) too long for one line"))
            let sped = caps.filter { c in map.pieces.contains { $0.rate > 1.3 && $0.source.overlaps(TimeRange(c.start, c.end)) } }
            if !sped.isEmpty {
                checks.append(QualityCheck("speech_sped_up", .warn, value: Double(sped.count), "\(sped.count) caption(s) fall in sped-up parts; speech will sound rushed",
                                           fix: "exclude speech from speed segments"))
            }
        } else if transcript.map({ !$0.words.isEmpty }) == true && caps.isEmpty {
            checks.append(QualityCheck("captions_missing", .info, "A transcript exists but no captions are on the timeline", fix: "generate_captions"))
        }
        return QualityReport(checks: checks, metrics: metrics)
    }
}
