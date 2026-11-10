import Foundation

// MARK: - Annotations (callouts)

/// A callout drawn over the screen for a time range: text, an arrow, a box or a spotlight highlight.
/// Geometry is normalized to the recorded screen (origin top-left), so callouts zoom and pan with the content.
public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, arrow, box, highlight }
    public var id: String
    public var kind: Kind
    public var start: Double
    public var end: Double
    /// Box/highlight area, or the text block (x, y = top-left; width wraps the text; height is ignored for text).
    public var rect: NormRect?
    /// Arrow tail and head.
    public var from: NormPoint?
    public var to: NormPoint?
    public var text: String?
    /// Stroke / fill colour of the shape, and the label background for text.
    public var color: RGBA
    public var textColor: RGBA
    /// Line width as a fraction of the screen's shorter side.
    public var strokeWidth: Double
    /// Text size as a fraction of the screen's height.
    public var fontSize: Double
    /// Highlight: how dark the area outside the box gets (0…0.9).
    public var dim: Double
    public var origin: Origin
    public var reason: String?

    public init(id: String = IDs.make("an"), kind: Kind, start: Double, end: Double, rect: NormRect? = nil, from: NormPoint? = nil, to: NormPoint? = nil,
                text: String? = nil, color: RGBA = RGBA(0.36, 0.70, 0.96), textColor: RGBA = .white, strokeWidth: Double = 0.006,
                fontSize: Double = 0.04, dim: Double = 0.55, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.rect = rect; self.from = from; self.to = to; self.text = text
        self.color = color; self.textColor = textColor; self.strokeWidth = strokeWidth; self.fontSize = fontSize; self.dim = dim
        self.origin = origin; self.reason = reason
    }
    public var range: TimeRange { TimeRange(start, end) }

    func validate(duration: Double) throws {
        guard start >= -1e-6, end <= duration + 1e-3, end - start >= 0.1 else { throw EditError.invalid("annotation \(id) must last at least 0.1s inside the program (0–\(fmt(duration))s)") }
        func inUnit(_ p: NormPoint) -> Bool { (0...1).contains(p.x) && (0...1).contains(p.y) }
        switch kind {
        case .arrow:
            guard let a = from, let b = to else { throw EditError.invalid("arrow \(id) needs from and to points") }
            guard inUnit(a), inUnit(b) else { throw EditError.invalid("arrow \(id) points must be within 0…1") }
            guard a.distance(to: b) >= 0.01 else { throw EditError.invalid("arrow \(id) is too short") }
        case .box, .highlight:
            guard let r = rect else { throw EditError.invalid("\(kind.rawValue) \(id) needs rect {x,y,width,height}") }
            try Self.checkRect(r, id)
        case .text:
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { throw EditError.invalid("text \(id) needs text") }
            guard t.count <= 280 else { throw EditError.invalid("text \(id) is longer than 280 characters") }
            guard let r = rect else { throw EditError.invalid("text \(id) needs rect (x, y = top-left, width)") }
            guard (0...1).contains(r.x), (0...1).contains(r.y), r.width >= 0.05, r.x + r.width <= 1.0001 else { throw EditError.invalid("text \(id) rect must be inside the screen with width ≥ 0.05") }
        }
        guard (0.0005...0.05).contains(strokeWidth) else { throw EditError.invalid("strokeWidth must be 0.0005…0.05") }
        guard (0.01...0.2).contains(fontSize) else { throw EditError.invalid("fontSize must be 0.01…0.2") }
        guard (0...0.9).contains(dim) else { throw EditError.invalid("dim must be 0…0.9") }
    }

    static func checkRect(_ r: NormRect, _ id: String) throws {
        guard r.width >= 0.005, r.height >= 0.005 else { throw EditError.invalid("\(id): rect is too small (min 0.005)") }
        guard r.x >= -1e-6, r.y >= -1e-6, r.x + r.width <= 1.0001, r.y + r.height <= 1.0001 else {
            throw EditError.invalid("\(id): rect must lie inside the screen (0…1, origin top-left)")
        }
    }
}

// MARK: - Redaction

/// A privacy mask over part of the screen for a time range. It is composited into every rendered frame — preview,
/// stills, GIF and export — before the cursor, and moves with the zoom camera because it is anchored to content.
public struct Redaction: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case pixelate, blur, solid }
    public var id: String
    public var start: Double
    public var end: Double
    public var rect: NormRect
    public var mode: Mode
    /// 0…1. Pixelate block size / blur radius relative to the masked area; ignored for solid.
    public var strength: Double
    public var color: RGBA
    public var label: String?
    public var origin: Origin
    public init(id: String = IDs.make("rd"), start: Double, end: Double, rect: NormRect, mode: Mode = .pixelate, strength: Double = 0.7,
                color: RGBA = RGBA(0.1, 0.1, 0.12), label: String? = nil, origin: Origin = .manual) {
        self.id = id; self.start = start; self.end = end; self.rect = rect; self.mode = mode; self.strength = strength; self.color = color
        self.label = label; self.origin = origin
    }
    public var range: TimeRange { TimeRange(start, end) }
    func validate(duration: Double) throws {
        guard start >= -1e-6, end <= duration + 1e-3, end - start >= 0.04 else { throw EditError.invalid("redaction \(id) must last at least 0.04s inside the program (0–\(fmt(duration))s)") }
        try Annotation.checkRect(rect, "redaction \(id)")
        guard (0.1...1).contains(strength) else { throw EditError.invalid("redaction strength must be 0.1…1 (weaker masks can leave text readable)") }
    }
}

// MARK: - Transitions

/// A dip through a colour centred on a program instant — typically a clip join or a cut. At the very start or end
/// of the program it becomes a fade in or out.
public struct Transition: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case dipBlack = "dip_black", dipWhite = "dip_white" }
    public var id: String
    /// Program source instant of the transition's midpoint.
    public var time: Double
    public var kind: Kind
    /// Total length on the output timeline (seconds).
    public var duration: Double
    public var origin: Origin
    public init(id: String = IDs.make("tr"), time: Double, kind: Kind = .dipBlack, duration: Double = 0.6, origin: Origin = .manual) {
        self.id = id; self.time = time; self.kind = kind; self.duration = duration; self.origin = origin
    }
    /// Opacity of the colour at an output time, given the transition's output midpoint.
    public static func amount(outputTime t: Double, center c: Double, duration d: Double) -> Double {
        let half = max(0.02, d / 2)
        let x = abs(t - c) / half
        return max(0, min(1, 1 - x))
    }
}

// MARK: - Audio tracks (music, imported voiceover, effects)

public struct AudioClip: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case music, voice, effect }
    public var id: String
    public var kind: Kind
    public var name: String
    /// Audio file relative to the bundle (`media/audio/<file>`).
    public var path: String
    /// Program source instant the clip starts at (plays at 1× on the output timeline from there).
    public var start: Double
    /// Offset into the file.
    public var mediaStart: Double
    /// Length of the file (measured on import).
    public var fileDuration: Double
    /// Play length on the output timeline; nil = until the file (or the loop) runs to the end of the video.
    public var length: Double?
    public var gain: Double
    /// Repeat the file to fill `length` / the rest of the video (music beds).
    public var loop: Bool
    public var fadeIn: Double
    public var fadeOut: Double
    /// Lower this clip while narration (voiceover or `voice` clips) plays. Defaults on for music.
    public var duckUnderVoice: Bool
    public var origin: Origin
    public var reason: String?
    public init(id: String = IDs.make("au"), kind: Kind, name: String, path: String, start: Double = 0, mediaStart: Double = 0, fileDuration: Double,
                length: Double? = nil, gain: Double? = nil, loop: Bool? = nil, fadeIn: Double = 0, fadeOut: Double? = nil, duckUnderVoice: Bool? = nil,
                origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.path = path; self.start = start; self.mediaStart = mediaStart
        self.fileDuration = fileDuration; self.length = length
        self.gain = gain ?? (kind == .music ? 0.35 : 1)
        self.loop = loop ?? (kind == .music)
        self.fadeIn = fadeIn; self.fadeOut = fadeOut ?? (kind == .music ? 1.5 : 0)
        self.duckUnderVoice = duckUnderVoice ?? (kind == .music)
        self.origin = origin; self.reason = reason
    }
    func validate(duration: Double) throws {
        guard !path.isEmpty, fileDuration > 0.05 else { throw EditError.invalid("audio \(id) needs a path and a file duration") }
        guard start >= -1e-6, start <= duration else { throw EditError.invalid("audio \(id) starts outside the program (0–\(fmt(duration))s)") }
        guard mediaStart >= 0, mediaStart < fileDuration else { throw EditError.invalid("audio \(id) mediaStart is outside the file") }
        guard (0...3).contains(gain) else { throw EditError.invalid("audio gain must be 0…3") }
        if let l = length { guard l >= 0.1 else { throw EditError.invalid("audio length must be ≥ 0.1s") } }
        guard fadeIn >= 0, fadeOut >= 0, fadeIn <= 30, fadeOut <= 30 else { throw EditError.invalid("fades must be 0…30s") }
    }

    /// Output-time spans this clip plays, given its output start and the program's output end.
    public func playSpans(outputStart at: Double, videoEnd: Double) -> [(output: TimeRange, fileStart: Double)] {
        let total = min(length ?? .infinity, max(0, videoEnd - at))
        guard total > 0.01 else { return [] }
        let avail = fileDuration - mediaStart
        guard avail > 0.01 else { return [] }
        var out: [(TimeRange, Double)] = []
        var t = 0.0
        var first = true
        while t < total - 0.01 {
            let fs = first ? mediaStart : 0
            let piece = min(first ? avail : fileDuration, total - t)
            out.append((TimeRange(at + t, at + t + piece), fs))
            t += piece
            first = false
            if !loop { break }
        }
        return out
    }
}

/// Piecewise-linear gain over output time (fades and ducking), as keyframes. Pure, so it can be tested without media.
public enum AudioEnvelope {
    public struct Key: Hashable, Sendable { public var t: Double; public var gain: Double }

    /// Gain keyframes for a clip playing over `span`, with fades and ducking under `voice` ranges.
    public static func keys(span: TimeRange, base: Double, fadeIn: Double, fadeOut: Double, duck: [TimeRange], duckLevel: Double,
                            down: Double = 0.25, up: Double = 0.35) -> [Key] {
        // Sample the envelope at every breakpoint and interpolate linearly between them.
        let merged = mergeRanges(duck, gap: down + up).compactMap { $0.clamped(to: TimeRange(span.start - up, span.end + down)) }
        var ts: Set<Double> = [span.start, span.end]
        if fadeIn > 0 { ts.insert(min(span.end, span.start + fadeIn)) }
        if fadeOut > 0 { ts.insert(max(span.start, span.end - fadeOut)) }
        for r in merged { for x in [r.start - down, r.start, r.end, r.end + up] where x > span.start && x < span.end { ts.insert(x) } }
        func duckFactor(_ t: Double) -> Double {
            var f = 1.0
            for r in merged {
                if t >= r.start && t <= r.end { f = min(f, duckLevel) }
                else if t > r.start - down && t < r.start { f = min(f, 1 - (1 - duckLevel) * (t - (r.start - down)) / down) }
                else if t > r.end && t < r.end + up { f = min(f, duckLevel + (1 - duckLevel) * (t - r.end) / up) }
            }
            return f
        }
        func fade(_ t: Double) -> Double {
            var f = 1.0
            if fadeIn > 0 { f = min(f, max(0, (t - span.start) / fadeIn)) }
            if fadeOut > 0 { f = min(f, max(0, (span.end - t) / fadeOut)) }
            return f
        }
        return ts.sorted().map { Key(t: $0, gain: base * fade($0) * duckFactor($0)) }
    }

    public static func mergeRanges(_ rs: [TimeRange], gap: Double) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in rs.sorted(by: { $0.start < $1.start }) {
            if let l = out.last, r.start <= l.end + gap { out[out.count - 1] = TimeRange(l.start, max(l.end, r.end)) } else { out.append(r) }
        }
        return out
    }
}

// MARK: - Style presets

/// A reusable look: a partial `Style` applied with `merge_style`. Built-in presets ship with Glint; saved presets
/// live in `~/Library/Application Support/Glint/presets/<name>.json` and work in every project.
public struct StylePreset: Codable, Hashable, Sendable {
    public var name: String
    public var summary: String
    /// Partial style object (any subset of `Style`'s keys).
    public var style: JSONValue
    public var builtIn: Bool
    public init(name: String, summary: String, style: JSONValue, builtIn: Bool = false) {
        self.name = name; self.summary = summary; self.style = style; self.builtIn = builtIn
    }

    public static let builtIns: [StylePreset] = [
        StylePreset(name: "studio", summary: "Glint's default: soft gradient, rounded frame, highlight captions", style: .object([
            "background": .object(["kind": .string("gradient"), "preset": .string("dusk")]),
            "frame": .object(["padding": .number(0.075), "cornerRadius": .number(0.018), "shadowOpacity": .number(0.45)]),
            "captions": .object(["look": .string("highlight")]),
        ]), builtIn: true),
        StylePreset(name: "minimal", summary: "Flat light background, small padding, plain captions", style: .object([
            "background": .object(["kind": .string("solid"), "colors": .array([.object(["r": .number(0.95), "g": .number(0.96), "b": .number(0.98), "a": .number(1)])])]),
            "frame": .object(["padding": .number(0.04), "cornerRadius": .number(0.012), "shadowOpacity": .number(0.22)]),
            "captions": .object(["look": .string("pill")]),
        ]), builtIn: true),
        StylePreset(name: "full-bleed", summary: "No background: the screen fills the frame", style: .object([
            "background": .object(["kind": .string("none")]),
            "frame": .object(["padding": .number(0), "cornerRadius": .number(0), "shadowOpacity": .number(0)]),
        ]), builtIn: true),
        StylePreset(name: "bold-captions", summary: "Large high-contrast captions at the bottom", style: .object([
            "captions": .object(["enabled": .bool(true), "look": .string("pill"), "size": .number(0.052), "position": .string("bottom")]),
        ]), builtIn: true),
    ]
}

// MARK: - Subtitles (SRT / WebVTT)

public enum Subtitles {
    public struct Cue: Codable, Hashable, Sendable { public var start: Double; public var end: Double; public var text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text } }
    public enum Format: String, Codable, Sendable, CaseIterable { case srt, vtt }

    /// Caption cues on the OUTPUT timeline of the edit: each visible caption is mapped through cuts and speed
    /// changes, split where a cut interrupts it.
    public static func cues(document doc: ProjectDocument) -> [Cue] {
        let map = TimeMap(document: doc)
        var out: [Cue] = []
        for c in doc.timeline.captions.sorted(by: { $0.start < $1.start }) where !c.hidden {
            let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for r in map.outputRanges(forSource: TimeRange(c.start, c.end)) where r.duration >= 0.05 {
                if let l = out.last, l.text == text, abs(l.end - r.start) < 0.002 { out[out.count - 1].end = r.end } else { out.append(Cue(start: r.start, end: r.end, text: text)) }
            }
        }
        return out
    }

    public static func format(_ cues: [Cue], as f: Format) -> String {
        func ts(_ t: Double, sep: String) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, sep, ms % 1000)
        }
        switch f {
        case .srt:
            return cues.enumerated().map { "\($0 + 1)\n\(ts($1.start, sep: ",")) --> \(ts($1.end, sep: ","))\n\($1.text)\n" }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues.map { "\(ts($0.start, sep: ".")) --> \(ts($0.end, sep: "."))\n\($0.text)\n" }.joined(separator: "\n")
        }
    }

    /// Parse SRT or WebVTT. Times come back as written (output time for files exported from an edit).
    public static func parse(_ s: String) throws -> [Cue] {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else {
                throw EditError.invalid("Can't read subtitle timing “\(lines[i])”")
            }
            let body = lines[(i + 1)...].joined(separator: " ").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard b > a else { throw EditError.invalid("Subtitle cue ends before it starts: “\(lines[i])”") }
            if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
        }
        guard !cues.isEmpty else { throw EditError.invalid("No subtitle cues found (expected SRT or WebVTT)") }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let p = s.split(separator: ":").map(String.init)
        guard (2...3).contains(p.count), let sec = Double(p.last!) else { return nil }
        let m = Double(p[p.count - 2]) ?? -1, h = p.count == 3 ? (Double(p[0]) ?? -1) : 0
        guard m >= 0, h >= 0 else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Caption segments (source time) for cues on the output timeline of `doc`.
    public static func captions(from cues: [Cue], document doc: ProjectDocument, timeBase: String = "output") -> [CaptionSegment] {
        let map = TimeMap(document: doc)
        return cues.compactMap { c in
            let s: Double, e: Double
            if timeBase == "source" { s = c.start; e = c.end } else {
                s = map.source(forOutput: c.start)
                e = map.source(forOutput: max(c.start, c.end - 0.001)) + 0.001
            }
            guard e - s >= 0.05 else { return nil }
            let tokens = c.text.split(separator: " ").map(String.init)
            let step = (e - s) / Double(max(1, tokens.count))
            return CaptionSegment(start: s, end: e, text: c.text,
                                  words: tokens.enumerated().map { CaptionWord(text: $1, start: s + Double($0) * step, end: s + Double($0 + 1) * step) })
        }
    }
}

// MARK: - Transcript-based editing

public enum TranscriptEdit {
    /// Cuts that remove words `from…to` (inclusive indices into `words`), without eating neighbouring words.
    public static func cuts(words: [CaptionWord], ranges: [(Int, Int)], padding: Double = 0.04) throws -> [TimeRange] {
        let w = words
        var out: [TimeRange] = []
        for (a0, b0) in ranges {
            let a = min(a0, b0), b = max(a0, b0)
            guard a >= 0, b < w.count else { throw EditError.invalid("word range \(a0)…\(b0) is outside the transcript (0…\(w.count - 1))") }
            let prevEnd = a > 0 ? w[a - 1].end : -Double.infinity
            let nextStart = b + 1 < w.count ? w[b + 1].start : Double.infinity
            let s = max(prevEnd, w[a].start - padding, 0)
            let e = min(nextStart, w[b].end + padding)
            if e - s >= 0.05 { out.append(TimeRange(s, e)) }
        }
        return AudioEnvelope.mergeRanges(out, gap: 0)
    }

    /// Word index ranges matching a phrase (case- and punctuation-insensitive).
    public static func find(_ phrase: String, in words: [CaptionWord]) -> [(Int, Int)] {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let q = phrase.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !q.isEmpty, q.count <= words.count else { return [] }
        let ws = words.map { norm($0.text) }
        var out: [(Int, Int)] = []
        var i = 0
        while i + q.count <= ws.count {
            if Array(ws[i..<(i + q.count)]) == q { out.append((i, i + q.count - 1)); i += q.count } else { i += 1 }
        }
        return out
    }
}

@inline(__always) func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
