import Foundation

// MARK: - Shots (clips on the program timeline)
//
// A project's "source time" is the PROGRAM SOURCE timeline: the project's clips laid end to end in order. A project
// that never touched clips has exactly one implicit clip, the original recording from 0 to `media.duration`, so its
// program time equals its recording time and every existing project keeps working unchanged.
//
// Every timeline item (zooms, cuts, speeds, captions, markers, voiceover, annotations, redactions, transitions,
// audio) is anchored in program source time. When the clip list changes, items are carried through a remap keyed by
// (media file, file time), so a zoom stays on the same content when a clip is inserted before it, moved or trimmed.

/// One shot: a range of a media file placed on the program timeline.
public struct MediaClip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Video file, relative to the bundle.
    public var path: String
    /// Range of the file used (file seconds).
    public var mediaStart: Double
    public var mediaEnd: Double
    /// The project's own recording: its audio is `media.microphone`/`media.systemAudio` (with `style.audio` gains),
    /// its camera is `media.camera`, and its input events are `events.json`.
    public var primary: Bool
    /// Audio files on the same clock as `path` (relative). For an imported movie this is usually `[path]`.
    public var audio: [String]
    /// Input event log of this take (relative), if it was recorded by Glint. Nil for imported movies.
    public var events: String?
    /// Stable recipe scene this shot shows, if any.
    public var scene: String?
    /// The take (recording) the shot comes from, for provenance.
    public var take: String?
    /// Pixel size of the video.
    public var width: Int
    public var height: Int
    /// Level of this shot's own audio (imported clips). The primary recording uses `style.audio`.
    public var gain: Double
    /// Length of the whole file (measured on import), so trims can be validated.
    public var fileDuration: Double?
    public var origin: Origin
    public var reason: String?

    public init(id: String = IDs.make("clip"), name: String, path: String, mediaStart: Double = 0, mediaEnd: Double, primary: Bool = false,
                audio: [String] = [], events: String? = nil, scene: String? = nil, take: String? = nil, width: Int, height: Int,
                gain: Double = 1, fileDuration: Double? = nil, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.mediaStart = mediaStart; self.mediaEnd = mediaEnd; self.primary = primary
        self.audio = audio; self.events = events; self.scene = scene; self.take = take; self.width = width; self.height = height
        self.gain = gain; self.fileDuration = fileDuration; self.origin = origin; self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case id, name, path, mediaStart, mediaEnd, primary, audio, events, scene, take, width, height, gain, fileDuration, origin, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDs.make("clip")
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        mediaStart = try c.decodeIfPresent(Double.self, forKey: .mediaStart) ?? 0
        mediaEnd = try c.decode(Double.self, forKey: .mediaEnd)
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        audio = try c.decodeIfPresent([String].self, forKey: .audio) ?? []
        events = try c.decodeIfPresent(String.self, forKey: .events)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        take = try c.decodeIfPresent(String.self, forKey: .take)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        fileDuration = try c.decodeIfPresent(Double.self, forKey: .fileDuration)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .manual
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    public var duration: Double { max(0, mediaEnd - mediaStart) }
    /// Identity of the underlying media, used to carry items across clip edits.
    var mediaKey: String { (take ?? "") + "|" + path }

    public static let primaryID = "clip_primary"
}

extension ProjectDocument {
    /// The recording as a single clip (what a project without explicit clips plays).
    public var primaryClip: MediaClip {
        MediaClip(id: MediaClip.primaryID, name: recording?.sourceName ?? "Recording", path: media.screen, mediaStart: 0, mediaEnd: media.duration,
                  primary: true, events: "events.json", width: media.width, height: media.height, fileDuration: media.duration, origin: .auto)
    }
    /// Clips in program order (the implicit primary clip when none are set).
    public var effectiveClips: [MediaClip] { timeline.clips.isEmpty ? [primaryClip] : timeline.clips }
    /// Length of the program source timeline: the recording, or all clips end to end.
    public var duration: Double { timeline.clips.isEmpty ? media.duration : timeline.clips.reduce(0) { $0 + $1.duration } }
    /// Program ranges whose shots were recorded with input events. Elsewhere (imported movies) "no input" means
    /// "no data", not idle, so idle-based planning and checks must not act there.
    public var inputTrackedRanges: [TimeRange] {
        ClipLayout(document: self).segments.filter { $0.clip.events != nil }.map(\.range)
    }
    /// Idle ranges limited to shots that have input events.
    public func idleRanges(_ events: EventLog, minDuration: Double) -> [TimeRange] {
        let idle = Activity.idleRanges(events, duration: duration, minDuration: minDuration)
        if isSingleRecording { return idle }
        let tracked = inputTrackedRanges
        return idle.flatMap { r in tracked.compactMap { r.clamped(to: $0) } }.filter { $0.duration >= minDuration }
    }

    /// True when the program is just the original recording from its start (program time = recording time).
    public var isSingleRecording: Bool {
        let c = effectiveClips
        return c.count == 1 && c[0].primary && abs(c[0].mediaStart) < 1e-9
    }
}

/// Clips placed end to end on the program timeline.
public struct ClipLayout: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public var clip: MediaClip
        public var index: Int
        public var start: Double
        public var end: Double
        public var range: TimeRange { TimeRange(start, end) }
        /// File time of a program instant inside this segment.
        public func fileTime(_ t: Double) -> Double { clip.mediaStart + (t - start) }
        public func programTime(file f: Double) -> Double { start + (f - clip.mediaStart) }
    }
    public let segments: [Segment]
    public var duration: Double { segments.last?.end ?? 0 }

    public init(clips: [MediaClip]) {
        var t = 0.0
        var segs: [Segment] = []
        for (i, c) in clips.enumerated() {
            segs.append(Segment(clip: c, index: i, start: t, end: t + c.duration))
            t += c.duration
        }
        segments = segs
    }
    public init(document: ProjectDocument) { self.init(clips: document.effectiveClips) }

    /// The segment showing a program instant (the last one owns the very end).
    public func segment(at t: Double) -> Segment? {
        if let s = segments.first(where: { t >= $0.start - 1e-9 && t < $0.end - 1e-9 }) { return s }
        if let l = segments.last, abs(t - l.end) < 1e-6 { return l }
        return nil
    }

    /// Program ranges showing ranges of the primary recording's file time (e.g. silences found in its microphone).
    public func programRanges(primaryFileRanges rs: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for s in segments where s.clip.primary {
            for r in rs {
                let lo = max(r.start, s.clip.mediaStart), hi = min(r.end, s.clip.mediaEnd)
                if hi - lo > 1e-6 { out.append(TimeRange(s.programTime(file: lo), s.programTime(file: hi))) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Split a program range into per-segment pieces.
    public func pieces(_ r: TimeRange) -> [(Segment, TimeRange)] {
        segments.compactMap { s in r.clamped(to: s.range).map { (s, $0) } }
    }
}

// MARK: - Remap across clip edits

/// Carries program-time anchors from one clip layout to another.
public struct ClipRemap: Sendable {
    public let old: ClipLayout
    public let new: ClipLayout
    /// Old clip id → new clip id whose content replaces it (scene refresh). Items that only existed in a replaced
    /// clip are mapped proportionally into the replacement when `proportional` is requested.
    public let replacements: [String: String]

    public init(old: ClipLayout, new: ClipLayout, replacements: [String: String] = [:]) {
        self.old = old; self.new = new; self.replacements = replacements
    }

    /// New program intervals that show the same media as an old program range.
    public func ranges(_ r: TimeRange) -> [TimeRange] {
        var out: [TimeRange] = []
        for (seg, piece) in old.pieces(r) {
            let fs = seg.fileTime(piece.start), fe = seg.fileTime(piece.end)
            // Prefer the same clip id (a trim or move), then any clip on the same media (a split).
            let candidates = new.segments.filter { $0.clip.id == seg.clip.id } + new.segments.filter { $0.clip.id != seg.clip.id && $0.clip.mediaKey == seg.clip.mediaKey }
            var covered: [TimeRange] = []
            for n in candidates {
                let lo = max(fs, n.clip.mediaStart), hi = min(fe, n.clip.mediaEnd)
                guard hi - lo > 1e-6 else { continue }
                // Don't map the same file instants twice (a duplicated clip): the first candidate wins.
                var remaining = [TimeRange(lo, hi)]
                for used in covered {
                    remaining = remaining.flatMap { part -> [TimeRange] in
                        guard used.start < part.end, part.start < used.end else { return [part] }
                        var pieces: [TimeRange] = []
                        if part.start < used.start { pieces.append(TimeRange(part.start, used.start)) }
                        if used.end < part.end { pieces.append(TimeRange(used.end, part.end)) }
                        return pieces
                    }
                }
                covered.append(contentsOf: remaining)
                out.append(contentsOf: remaining.map { TimeRange(n.programTime(file: $0.start), n.programTime(file: $0.end)) })
            }
        }
        out.sort { $0.start < $1.start }
        var merged: [TimeRange] = []
        for x in out {
            if let l = merged.last, x.start <= l.end + 1e-6 { merged[merged.count - 1] = TimeRange(l.start, max(l.end, x.end)) } else { merged.append(x) }
        }
        return merged
    }

    /// Proportional position of an old instant inside the clip that replaced its clip.
    func proportional(_ t: Double) -> Double? {
        guard let seg = old.segment(at: t), let nid = replacements[seg.clip.id], let n = new.segments.first(where: { $0.clip.id == nid }) else { return nil }
        let f = seg.end > seg.start ? (t - seg.start) / (seg.end - seg.start) : 0
        return n.start + max(0, min(1, f)) * (n.end - n.start)
    }

    /// New program time of an old instant, nil if its media is gone.
    public func instant(_ t: Double, proportional prop: Bool = false) -> Double? {
        if let seg = old.segment(at: t) {
            let f = seg.fileTime(t)
            let candidates = new.segments.filter { $0.clip.id == seg.clip.id } + new.segments.filter { $0.clip.id != seg.clip.id && $0.clip.mediaKey == seg.clip.mediaKey }
            // A join belongs to the following source interval, even if the preceding split kept the old id.
            if let n = candidates.first(where: { f >= $0.clip.mediaStart && f < $0.clip.mediaEnd }) {
                return n.programTime(file: f)
            }
            // Preserve a true endpoint when there is no following source interval.
            if let n = candidates.first(where: { abs(f - $0.clip.mediaEnd) < 1e-9 }) {
                return n.end
            }
        }
        return prop ? proportional(t) : nil
    }

    /// The longest contiguous new range showing the old range (nil when its media is gone).
    public func span(_ r: TimeRange, proportional prop: Bool = false, minimum: Double = 0.05) -> TimeRange? {
        if let best = ranges(r).max(by: { $0.duration < $1.duration }), best.duration >= minimum { return best }
        guard prop, let s = proportional(r.start), let e = proportional(max(r.start, r.end - 1e-6)) else { return nil }
        // Only when the whole range sat in one replaced clip.
        guard let a = old.segment(at: r.start), let b = old.segment(at: max(r.start, r.end - 1e-6)), a.clip.id == b.clip.id, e - s >= minimum else { return nil }
        return TimeRange(s, e)
    }

    public var isIdentity: Bool { old == new }
}

/// Result of a clip edit: what happened to items that showed content which no longer exists.
public struct ClipEditReport: Codable, Hashable, Sendable {
    public var dropped: [String] = []
    public var retimedProportionally: [String] = []
    public init() {}
}

extension Timeline {
    /// Move every program-time anchor through `remap`. Items whose content disappeared are dropped, except manual
    /// and agent items (and narration) inside a replaced clip, which are mapped proportionally into its replacement.
    mutating func remap(_ m: ClipRemap, oldDuration: Double, newDuration: Double, report: inout ClipEditReport) {
        func keep(_ origin: Origin) -> Bool { origin != .auto }

        // In/out trims become cuts while clips move, so a trimmed tail stays trimmed when it stops being the end.
        var trimCuts: [Cut] = []
        if inPoint > 1e-6 { trimCuts.append(Cut(id: "__trim_in", start: 0, end: inPoint, origin: .manual)) }
        if let o = outPoint, o < oldDuration - 1e-6 { trimCuts.append(Cut(id: "__trim_out", start: o, end: oldDuration, origin: .manual)) }
        inPoint = 0; outPoint = nil

        var newCuts: [Cut] = []
        for c in cuts + trimCuts {
            let rs = m.ranges(c.range)
            if rs.isEmpty { if !c.id.hasPrefix("__") { report.dropped.append(c.id) }; continue }
            for (i, r) in rs.enumerated() where r.duration > 1e-6 {
                var x = c; x.start = r.start; x.end = r.end
                if i > 0, !c.id.hasPrefix("__") { x.id = IDs.make("c") }
                newCuts.append(x)
            }
        }
        // Cuts touching the program ends turn back into trims.
        var finalCuts: [Cut] = []
        for c in newCuts {
            if c.id.hasPrefix("__"), c.start < 1e-6 { inPoint = max(inPoint, c.end); continue }
            if c.id.hasPrefix("__"), c.end > newDuration - 1e-6 { outPoint = min(outPoint ?? newDuration, c.start); continue }
            var x = c
            if x.id.hasPrefix("__") { x.id = IDs.make("c") }
            finalCuts.append(x)
        }
        cuts = finalCuts.sorted { $0.start < $1.start }

        func mapped(_ range: TimeRange, id: String, proportional: Bool = false) -> [TimeRange] {
            let direct = m.ranges(range)
            if !direct.isEmpty { return direct }
            if proportional, let replacement = m.span(range, proportional: true) {
                report.retimedProportionally.append(id)
                return [replacement]
            }
            report.dropped.append(id)
            return []
        }
        speeds = speeds.flatMap { s in
            mapped(s.range, id: s.id, proportional: keep(s.origin)).enumerated().map { i, r in
                var x = s; x.start = r.start; x.end = r.end
                if i > 0 { x.id = IDs.make("sp") }
                return x
            }
        }
        zooms = zooms.flatMap { z in
            mapped(z.range, id: z.id, proportional: keep(z.origin)).enumerated().map { i, r in
                var x = z; x.start = r.start; x.end = r.end
                if i > 0 { x.id = IDs.make("z") }
                return x
            }
        }
        captions = captions.flatMap { c in
            mapped(TimeRange(c.start, c.end), id: c.id).enumerated().map { i, r in
                var x = c; x.start = r.start; x.end = r.end
                if i > 0 { x.id = IDs.make("k") }
                x.words = c.words.flatMap { w in
                    m.ranges(TimeRange(w.start, w.end)).compactMap { piece -> CaptionWord? in
                        let start = max(r.start, piece.start), end = min(r.end, piece.end)
                        guard end > start else { return nil }
                        return CaptionWord(text: w.text, start: start, end: end)
                    }
                }.sorted { $0.start < $1.start }
                // Preserve a manually rewritten caption; only derive text when it still matches its timed words.
                if !c.words.isEmpty, c.text == c.words.map(\.text).joined(separator: " ") {
                    x.text = x.words.map(\.text).joined(separator: " ")
                }
                return x
            }
        }
        markers = markers.compactMap { mk in
            guard let t = m.instant(mk.time, proportional: true) else { report.dropped.append(mk.id); return nil }
            var x = mk; x.time = t; return x
        }
        voiceover = voiceover.compactMap { v in
            let direct = m.instant(v.start)
            guard let t = direct ?? m.instant(v.start, proportional: true) else { report.dropped.append(v.id); return nil }
            if direct == nil { report.retimedProportionally.append(v.id) }
            var x = v; x.start = t; return x
        }
        annotations = annotations.flatMap { a in
            mapped(a.range, id: a.id, proportional: keep(a.origin)).enumerated().map { i, r in
                var x = a; x.start = r.start; x.end = r.end
                if i > 0 { x.id = IDs.make("an") }
                return x
            }
        }
        redactions = redactions.flatMap { a in
            // Keep every surviving piece, never cover unrelated inserted or replacement content.
            // Even sub-frame fragments retain coverage; never silently discard a small surviving piece.
            mapped(a.range, id: a.id).enumerated().map { i, r in
                var x = a; x.start = r.start; x.end = r.end
                if i > 0 { x.id = IDs.make("rd") }
                return x
            }
        }
        transitions = transitions.compactMap { tr in
            guard let t = m.instant(tr.time, proportional: true) else { report.dropped.append(tr.id); return nil }
            var x = tr; x.time = t; return x
        }
        audio = audio.compactMap { a in
            guard let t = m.instant(a.start, proportional: true) else { report.dropped.append(a.id); return nil }
            var x = a; x.start = t; return x
        }
    }
}

// MARK: - Program-time events and transcript

extension EventLog {
    /// Events in program source time: each clip contributes the events of its take inside its file range.
    /// `logs` maps an events path (`clip.events`) to its log. Identity for a project that is just its recording.
    public static func program(document doc: ProjectDocument, logs: [String: EventLog]) -> EventLog {
        if doc.isSingleRecording, abs(doc.effectiveClips[0].mediaEnd - doc.media.duration) < 1e-6 { return logs["events.json"] ?? EventLog() }
        var out = EventLog()
        var seenCursors = Set<String>()
        for seg in ClipLayout(document: doc).segments {
            guard let path = seg.clip.events, let log = logs[path] else { continue }
            let a = seg.clip.mediaStart, b = seg.clip.mediaEnd
            func inside(_ t: Double) -> Bool { t >= a && t < b }
            func p(_ t: Double) -> Double { seg.programTime(file: t) }
            out.pointer += log.pointer.filter { inside($0.t) }.map { var x = $0; x.t = p($0.t); return x }
            out.clicks += log.clicks.filter { inside($0.t) }.map { var x = $0; x.t = p($0.t); x.up = $0.up.map { p(min($0, b)) }; return x }
            out.keys += log.keys.filter { inside($0.t) }.map { var x = $0; x.t = p($0.t); return x }
            out.scrolls += log.scrolls.filter { inside($0.t) }.map { var x = $0; x.t = p($0.t); return x }
            out.apps += log.apps.filter { inside($0.t) }.map { var x = $0; x.t = p($0.t); return x }
            // The cursor shape in effect at the clip start carries into it.
            if let lead = log.cursorChanges.last(where: { $0.t <= a }) { var x = lead; x.t = seg.start; out.cursorChanges.append(x) }
            out.cursorChanges += log.cursorChanges.filter { $0.t > a && $0.t < b }.map { var x = $0; x.t = p($0.t); return x }
            out.markers += log.markers.filter { inside($0.time) }.map { var x = $0; x.time = p($0.time); return x }
            for c in log.cursors where !seenCursors.contains(c.id) { seenCursors.insert(c.id); out.cursors.append(c) }
        }
        out.pointer.sort { $0.t < $1.t }; out.clicks.sort { $0.t < $1.t }; out.keys.sort { $0.t < $1.t }
        out.scrolls.sort { $0.t < $1.t }; out.apps.sort { $0.t < $1.t }; out.cursorChanges.sort { $0.t < $1.t }
        return out
    }
}

extension Transcript {
    /// The transcript (of the primary recording's audio) in program source time.
    public func program(document doc: ProjectDocument, shots: [String: Transcript] = [:]) -> Transcript {
        Self.program(document: doc, primary: self, shots: shots) ?? self
    }

    /// The program's speech in program source time: the primary recording's words where primary shots play, and each
    /// imported shot's own transcript (keyed by its audio file, in file time) where that shot plays. Nil when there is
    /// nothing to say. A project that is just its recording gets the primary transcript unchanged.
    public static func program(document doc: ProjectDocument, primary: Transcript?, shots: [String: Transcript]) -> Transcript? {
        if doc.isSingleRecording { return primary }
        var words: [CaptionWord] = []
        var base: Transcript?
        for seg in ClipLayout(document: doc).segments {
            let source: Transcript?
            if seg.clip.primary { source = primary } else { source = seg.clip.audio.first.flatMap { shots[$0] } }
            guard let src = source else { continue }
            if base == nil { base = src }
            for w in src.words where w.start >= seg.clip.mediaStart && w.start < seg.clip.mediaEnd {
                words.append(CaptionWord(text: w.text, start: seg.programTime(file: w.start), end: seg.programTime(file: min(w.end, seg.clip.mediaEnd))))
            }
        }
        guard var t = primary ?? base else { return nil }
        t.words = words.sorted { $0.start < $1.start }
        return t
    }
}

extension ProjectBundle {
    /// Input events in program time (see `EventLog.program`).
    public func programEvents(for doc: ProjectDocument) -> EventLog {
        var logs: [String: EventLog] = ["events.json": readEvents()]
        for c in doc.effectiveClips {
            guard let p = c.events, logs[p] == nil else { continue }
            logs[p] = (try? JSONCoding.decoder.decode(EventLog.self, from: Data(contentsOf: resolve(p)))) ?? EventLog()
        }
        return EventLog.program(document: doc, logs: logs)
    }
    /// Transcript in program time: the recording's words plus each imported shot's own (see `Transcript.program`).
    public func programTranscript(for doc: ProjectDocument) -> Transcript? {
        Transcript.program(document: doc, primary: readTranscript(), shots: shotTranscripts(for: doc))
    }

    /// Per-file transcripts of imported shots' audio, in file time (`analysis/transcripts/<encoded path>.json`).
    public var shotTranscriptsURL: URL { analysisURL.appendingPathComponent("transcripts", isDirectory: true) }
    public func shotTranscriptURL(for audioPath: String) -> URL {
        let name = audioPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? audioPath
        return shotTranscriptsURL.appendingPathComponent(name + ".json")
    }
    public func readShotTranscript(for audioPath: String) -> Transcript? {
        try? JSONCoding.decoder.decode(Transcript.self, from: Data(contentsOf: shotTranscriptURL(for: audioPath)))
    }
    public func writeShotTranscript(_ t: Transcript, for audioPath: String) throws {
        try FileManager.default.createDirectory(at: shotTranscriptsURL, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(t).write(to: shotTranscriptURL(for: audioPath), options: .atomic)
    }
    /// Audio files of the imported shots the program plays (each shot's first audio file), in program order.
    public func shotAudioPaths(for doc: ProjectDocument) -> [String] {
        var out: [String] = []
        for c in doc.effectiveClips where !c.primary { if let a = c.audio.first, !out.contains(a) { out.append(a) } }
        return out
    }
    /// Transcripts on disk for the imported shots' audio.
    public func shotTranscripts(for doc: ProjectDocument) -> [String: Transcript] {
        var out: [String: Transcript] = [:]
        for p in shotAudioPaths(for: doc) { if let t = readShotTranscript(for: p) { out[p] = t } }
        return out
    }
    /// Imported shots and takes live here (`media/clips/<file>`, `media/takes/<take>/…`).
    public var clipsURL: URL { mediaURL.appendingPathComponent("clips", isDirectory: true) }
    public var takesURL: URL { mediaURL.appendingPathComponent("takes", isDirectory: true) }
}

// MARK: - Clip operations

public enum ClipEditor {
    /// What a clip operation would do to the document's items, without saving.
    public static func preview(_ op: EditOperation, on doc: ProjectDocument) throws -> (document: ProjectDocument, report: ClipEditReport) {
        var d = doc
        let r = try apply(op, to: &d)
        try OperationApplier.validate(d)
        return (d, r)
    }

    @discardableResult
    static func apply(_ op: EditOperation, to doc: inout ProjectDocument) throws -> ClipEditReport {
        var clips = doc.effectiveClips
        let old = ClipLayout(clips: clips)
        var replacements: [String: String] = [:]

        func validate(_ c: MediaClip) throws {
            guard !c.path.isEmpty else { throw EditError.invalid("clip needs a path") }
            guard TimelineLimits.contains(c.mediaStart), TimelineLimits.contains(c.mediaEnd),
                  c.fileDuration.map({ TimelineLimits.contains($0) && $0 > 0 }) ?? true else {
                throw EditError.invalid("clip times must be finite and within the six-hour recording limit")
            }
            guard c.mediaStart >= 0, c.duration >= 0.1 else { throw EditError.invalid("clip \(c.id) must be at least 0.1s (mediaStart ≥ 0, mediaEnd > mediaStart)") }
            if let fd = c.fileDuration, c.mediaEnd > fd + 0.01 { throw EditError.invalid("clip \(c.id) ends at \(fmt(c.mediaEnd))s but the file is \(fmt(fd))s") }
            if c.primary, c.path != doc.media.screen { throw EditError.invalid("only the project's own recording (\(doc.media.screen)) can be a primary clip") }
            if c.primary, c.mediaEnd > doc.media.duration + 0.01 { throw EditError.invalid("clip \(c.id) ends after the recording") }
            guard (0...3).contains(c.gain) else { throw EditError.invalid("clip gain must be 0…3") }
        }
        func index(of id: String?) throws -> Int {
            guard let id, let i = clips.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("clip \(id ?? "(no id)")") }
            return i
        }
        /// Split the clip under program time `t` (no-op at a boundary); returns the clip index that starts at `t`.
        func splitPoint(_ t: Double, newID: String? = nil) throws -> Int {
            let layout = ClipLayout(clips: clips)
            if t >= layout.duration - 1e-3 { return clips.count }
            for s in layout.segments {
                if abs(t - s.start) < 1e-3 { return s.index }
                if t > s.start, t < s.end {
                    guard t - s.start >= 0.05, s.end - t >= 0.05 else { throw EditError.invalid("too close to a clip edge to split (needs 0.05s on each side)") }
                    var a = s.clip, b = s.clip
                    a.mediaEnd = s.fileTime(t)
                    b.mediaStart = s.fileTime(t)
                    b.id = newID ?? IDs.make("clip")
                    clips[s.index] = a
                    clips.insert(b, at: s.index + 1)
                    return s.index + 1
                }
            }
            return clips.count
        }

        switch op.op {
        case .insertClip:
            guard var shot = op.shot else { throw EditError.invalid("insert_clip needs shot {path, mediaEnd, …}") }
            if let id = op.id { shot.id = id }
            if let s = op.scene { shot.scene = s.isEmpty ? nil : s }
            guard !clips.contains(where: { $0.id == shot.id }) else { throw EditError.invalid("clip id \(shot.id) already exists") }
            try validate(shot)
            let at = max(0, min(old.duration, op.time ?? old.duration))
            clips.insert(shot, at: try splitPoint(at))
        case .removeClip:
            let i = try index(of: op.id)
            guard clips.count > 1 else { throw EditError.invalid("the program needs at least one clip") }
            clips.remove(at: i)
        case .updateClip:
            let i = try index(of: op.id)
            var c = clips[i]
            if let s = op.start { c.mediaStart = s }
            if let e = op.end { c.mediaEnd = e }
            if let g = op.gain { c.gain = g }
            if let t = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { c.name = t }
            if let s = op.scene { c.scene = s.isEmpty ? nil : s }
            if let r = op.reason { c.reason = r }
            try validate(c)
            clips[i] = c
        case .moveClip:
            let i = try index(of: op.id)
            guard let to = op.index, (0..<clips.count).contains(to) else { throw EditError.invalid("move_clip needs index 0…\(clips.count - 1)") }
            let c = clips.remove(at: i)
            clips.insert(c, at: to)
        case .splitClip:
            guard let t = op.time else { throw EditError.invalid("split_clip needs time") }
            guard t > 0.05, t < old.duration - 0.05 else { throw EditError.invalid("split time must be inside the program") }
            let before = clips.count
            if let id = op.id, clips.contains(where: { $0.id == id }) { throw EditError.invalid("clip id \(id) already exists") }
            _ = try splitPoint(t, newID: op.id)
            guard clips.count > before else { throw EditError.invalid("there is already a clip boundary at \(fmt(t))s") }
        case .replaceClip:
            guard var shot = op.shot else { throw EditError.invalid("replace_clip needs shot") }
            let targets = clips.indices.filter { (op.id != nil && clips[$0].id == op.id) || (op.scene != nil && clips[$0].scene == op.scene) }
            guard let first = targets.first else { throw EditError.notFound(op.scene.map { "clips for scene \($0)" } ?? "clip \(op.id ?? "(no id)")") }
            if shot.scene == nil { shot.scene = clips[first].scene }
            guard !clips.contains(where: { $0.id == shot.id }) || targets.contains(where: { clips[$0].id == shot.id }) else { throw EditError.invalid("clip id \(shot.id) already exists") }
            try validate(shot)
            if targets.contains(where: { clips[$0].id == shot.id }) { shot.id = IDs.make("clip") }
            for i in targets { replacements[clips[i].id] = shot.id }
            for i in targets.reversed() { clips.remove(at: i) }
            clips.insert(shot, at: first)
        default:
            throw EditError.invalid("not a clip operation")
        }
        let new = ClipLayout(clips: clips)
        var report = ClipEditReport()
        doc.timeline.remap(ClipRemap(old: old, new: new, replacements: replacements), oldDuration: old.duration, newDuration: new.duration, report: &report)
        doc.timeline.clips = clips
        return report
    }
}
