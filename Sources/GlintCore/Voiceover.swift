import Foundation

// MARK: - Voiceover clips

/// A generated (or imported) narration clip placed on the output timeline. `start` is the SOURCE instant the clip
/// is anchored to (so it stays with its scene when cuts move things); it plays at 1× from the output time of that
/// instant, regardless of speed changes underneath it.
public struct VoiceoverClip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    /// Audio file, relative to the project bundle (`media/voiceover/<id>.mp3`).
    public var path: String
    /// The spoken text.
    public var text: String
    /// Playback length in seconds (measured from the file).
    public var duration: Double
    /// Word timings relative to the clip start (0 = first sample), from the TTS alignment.
    public var words: [CaptionWord]
    public var gain: Double
    public var voice: String?
    public var voiceName: String?
    /// Scene this clip narrates (from the storyboard), when generated from a script.
    public var scene: String?
    public var origin: Origin
    public var reason: String?

    public init(id: String = IDs.make("vo"), start: Double, path: String, text: String, duration: Double, words: [CaptionWord] = [],
                gain: Double = 1, voice: String? = nil, voiceName: String? = nil, scene: String? = nil, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.start = start; self.path = path; self.text = text; self.duration = duration; self.words = words
        self.gain = gain; self.voice = voice; self.voiceName = voiceName; self.scene = scene; self.origin = origin; self.reason = reason
    }
}

/// Which synthetic voice a project uses. Saved in the document so people and agents share one choice.
public struct VoiceStyle: Codable, Hashable, Sendable {
    public var provider: String = "elevenlabs"
    public var voiceID: String?
    public var voiceName: String?
    public var model: String = "eleven_multilingual_v2"
    /// 0.7…1.2; ElevenLabs' speaking-rate control.
    public var speed: Double = 1.0
    public var stability: Double = 0.5
    public var similarity: Double = 0.75
    public var style: Double = 0
    public init() {}
}

// MARK: - Storyboard

/// One beat of the demo: a stretch of the recording in which the user does one thing. Scenes are the unit that
/// narration is written and timed for.
public struct Scene: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var title: String
    /// What happened (from input events and accessibility labels), e.g. "click “Save”", "typing (14 keys)".
    public var actions: [String]
    /// Text read off the representative frame (on-device OCR), top to bottom.
    public var onScreenText: [String]
    /// Spoken words recorded during the scene, if any.
    public var speech: String?
    public var app: String?
    /// Representative frame, relative to the bundle (`analysis/<id>.jpg`).
    public var frame: String?
    /// The source instant the frame was taken at.
    public var frameTime: Double?
    /// Narration written for this scene (by a person or a model).
    public var narration: String?
    public init(id: String = IDs.make("sc"), start: Double, end: Double, title: String, actions: [String] = [], onScreenText: [String] = [],
                speech: String? = nil, app: String? = nil, frame: String? = nil, frameTime: Double? = nil, narration: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.title = title; self.actions = actions; self.onScreenText = onScreenText
        self.speech = speech; self.app = app; self.frame = frame; self.frameTime = frameTime; self.narration = narration
    }
    public var range: TimeRange { TimeRange(start, end) }
    public var duration: Double { max(0, end - start) }
}

/// The analysed recording: scenes with evidence (frames, text, actions) and the narration script.
public struct Storyboard: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var formatVersion = Storyboard.formatVersion
    public var createdAt: Date
    /// Base revision of the document this analysis was made from.
    public var revision: Int
    public var scenes: [Scene]
    /// What the product is / who the demo is for, as given by the user; feeds the script writer.
    public var brief: String?
    public var title: String?
    public var summary: String?
    /// Which model wrote the narration, if any.
    public var writer: String?
    public var notes: [String]
    public init(createdAt: Date = Date(), revision: Int, scenes: [Scene], brief: String? = nil, title: String? = nil, summary: String? = nil,
                writer: String? = nil, notes: [String] = []) {
        self.createdAt = createdAt; self.revision = revision; self.scenes = scenes; self.brief = brief; self.title = title
        self.summary = summary; self.writer = writer; self.notes = notes
    }
    public var script: String { scenes.compactMap(\.narration).joined(separator: "\n\n") }
    public var narratedScenes: [Scene] { scenes.filter { !($0.narration ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

public struct SceneSegmentOptions: Codable, Hashable, Sendable {
    /// An input gap at least this long starts a new scene.
    public var gap: Double = 4.0
    public var minDuration: Double = 3.0
    public var maxDuration: Double = 28.0
    /// Markers and app switches always start a new scene.
    public var splitOnMarkers = true
    public var splitOnAppSwitch = true
    public init() {}
}

/// Splits a recording into scenes from what the user did: clusters of clicks/typing/scrolls separated by pauses,
/// app switches and markers. Pure: no media access (frames and OCR are added by the analysis layer).
public enum SceneSegmenter {
    public static func scenes(document doc: ProjectDocument, events: EventLog, transcript: Transcript?, options: SceneSegmentOptions = .init()) -> [Scene] {
        let kept = doc.keptRange
        let cuts = doc.timeline.cuts.map(\.range)
        func isKept(_ t: Double) -> Bool { kept.contains(t) && !cuts.contains(where: { $0.contains(t) }) }

        // Instants where something happened.
        struct Act { var t: Double; var end: Double; var label: String; var point: NormPoint? }
        var acts: [Act] = events.clicks.filter { isKept($0.t) }.map { Act(t: $0.t, end: $0.up ?? $0.t, label: $0.target.map { "click “\($0)”" } ?? "click", point: $0.point) }
        for b in Activity.bursts(events.keys.map(\.t), gap: 1.2, minCount: 2) where isKept(b.start) { acts.append(Act(t: b.start, end: b.end, label: "typing (\(b.count) keys)", point: nil)) }
        for b in Activity.bursts(events.scrolls.map(\.t), gap: 0.6, minCount: 2) where isKept(b.start) { acts.append(Act(t: b.start, end: b.end, label: "scroll", point: nil)) }
        acts.sort { $0.t < $1.t }

        var boundaries = Set<Double>()
        if options.splitOnMarkers { for m in doc.timeline.markers + events.markers where isKept(m.time) { boundaries.insert(m.time) } }
        if options.splitOnAppSwitch { for a in events.apps.dropFirst() where isKept(a.t) { boundaries.insert(a.t) } }

        // 1. Cluster actions in time, splitting at boundaries and long gaps.
        var clusters: [[Act]] = []
        for a in acts {
            if var last = clusters.last, let prev = last.last {
                let crossesBoundary = boundaries.contains { $0 > prev.end && $0 <= a.t }
                if !crossesBoundary, a.t - prev.end < options.gap, a.end - last.first!.t <= options.maxDuration {
                    last.append(a); clusters[clusters.count - 1] = last; continue
                }
            }
            clusters.append([a])
        }

        // 2. Clusters → scenes covering the whole kept range (each scene runs until the next begins).
        var ranges: [TimeRange] = []
        if clusters.isEmpty {
            // No input events (imported movie): fixed beats of ~12 s, split at markers.
            var edges = [kept.start] + boundaries.sorted() + [kept.end]
            edges = Array(Set(edges)).sorted()
            for (a, b) in zip(edges, edges.dropFirst()) where b - a > 0.5 {
                var t = a
                while t < b { let e = min(b, t + 12); ranges.append(TimeRange(t, e)); t = e }
            }
        } else {
            var starts = clusters.map { max(kept.start, $0.first!.t - 0.6) }
            starts[0] = kept.start
            // A marker or app switch between two clusters is where the new scene begins, not 0.6 s before the next click.
            for i in 1..<starts.count {
                let prevEnd = clusters[i - 1].last!.end, next = clusters[i].first!.t
                if let b = boundaries.filter({ $0 > prevEnd && $0 <= next }).min() { starts[i] = b }
            }
            for i in starts.indices {
                let end = i + 1 < starts.count ? starts[i + 1] : kept.end
                ranges.append(TimeRange(starts[i], end))
            }
        }
        // 3. Merge scenes that are too short into their neighbour; split ones that are too long.
        var merged: [TimeRange] = []
        for r in ranges {
            if let last = merged.last, (r.duration < options.minDuration || last.duration < options.minDuration), !boundaries.contains(r.start) {
                merged[merged.count - 1] = TimeRange(last.start, r.end)
            } else { merged.append(r) }
        }
        var final: [TimeRange] = []
        for r in merged {
            if r.duration > options.maxDuration * 1.5 {
                let n = Int((r.duration / options.maxDuration).rounded(.up))
                let step = r.duration / Double(n)
                for i in 0..<n { final.append(TimeRange(r.start + Double(i) * step, i == n - 1 ? r.end : r.start + Double(i + 1) * step)) }
            } else { final.append(r) }
        }

        let words = transcript?.words ?? []
        return final.enumerated().map { i, r in
            let inRange = acts.filter { r.contains($0.t) }
            let labels = Dictionary(grouping: inRange.map(\.label), by: { $0 }).map { k, v in v.count > 1 ? "\(v.count)× \(k)" : k }.sorted()
            let speech = words.filter { r.contains($0.start) }.map(\.text).joined(separator: " ")
            let app = events.apps.last(where: { $0.t <= r.start })?.name
            let marker = (doc.timeline.markers + events.markers).first { r.contains($0.time) && !$0.note.isEmpty }
            let title = marker?.note ?? (inRange.first(where: { $0.label.hasPrefix("click “") })?.label.replacingOccurrences(of: "click ", with: "")) ?? "Scene \(i + 1)"
            // Representative instant: the first click (the camera is settled there), else a third of the way in.
            let frameTime = inRange.first(where: { $0.label.hasPrefix("click") })?.t.advanced(by: 0.35) ?? (r.start + r.duration / 3)
            return Scene(start: round3(r.start), end: round3(r.end), title: title, actions: labels, speech: speech.isEmpty ? nil : speech, app: app,
                         frameTime: round3(min(r.end - 0.05, frameTime)))
        }
    }
}

// MARK: - Fitting the picture to the narration

public struct NarrationFitOptions: Codable, Hashable, Sendable {
    /// Silence kept after each clip before the next scene starts.
    public var tail: Double = 0.45
    /// Slowest / fastest rate used when stretching or compressing a scene.
    public var minRate: Double = 0.45
    public var maxRate: Double = 3.0
    /// A scene longer than narration × this is compressed (idle stretches first).
    public var compressAbove: Double = 1.3
    public init() {}
}

/// Retimes each narrated scene so the picture lasts as long as its voiceover: idle stretches (no input) are slowed
/// or sped up first, then the whole scene uniformly. Produces speed operations tagged `fit narration`, replacing
/// earlier ones. Pure.
public enum NarrationFit {
    public static let tag = "fit narration"

    public struct Result: Codable, Hashable, Sendable {
        public var operations: [EditOperation]
        public var notes: [String]
        /// Output duration after the fit.
        public var outputDuration: Double
    }

    public static func plan(document input: ProjectDocument, events: EventLog, scenes: [Scene], clips: [VoiceoverClip],
                            options: NarrationFitOptions = .init()) -> Result {
        var ops: [EditOperation] = []
        var notes: [String] = []
        var doc = input
        // Start from a document without previous fit speeds.
        let old = doc.timeline.speeds.filter { ($0.reason ?? "").hasPrefix(tag) }
        ops += old.map { EditOperation(.removeSpeed, id: $0.id) }
        doc.timeline.speeds.removeAll { ($0.reason ?? "").hasPrefix(tag) }

        let idle = doc.idleRanges(events, minDuration: 0.8)
        for scene in scenes.sorted(by: { $0.start < $1.start }) {
            let sceneClips = clips.filter { $0.scene == scene.id || ($0.scene == nil && scene.range.contains($0.start)) }
            guard !sceneClips.isEmpty else { continue }
            let needed = sceneClips.reduce(0) { $0 + $1.duration } + options.tail
            let map = TimeMap(document: doc)
            guard let span = map.outputSpan(forSource: scene.range), span.duration > 0.1 else { continue }
            let have = span.duration
            var newSpeeds: [SpeedSegment] = []
            if have < needed {
                // Stretch: slow the idle parts of the scene; if that isn't enough, the whole scene.
                let idleInside = idle.compactMap { $0.clamped(to: scene.range) }.filter { $0.duration >= 0.6 && map.outputSpan(forSource: $0) != nil }
                let idleOut = idleInside.reduce(0.0) { acc, r in acc + (map.outputSpan(forSource: r)?.duration ?? 0) }
                let extra = needed - have
                if idleOut > 0, idleOut / options.minRate >= idleOut + extra {
                    let rate = idleOut / (idleOut + extra)
                    for r in idleInside {
                        newSpeeds.append(SpeedSegment(start: round3(r.start), end: round3(r.end), rate: round3(max(options.minRate, rate)), origin: .auto,
                                                      reason: "\(tag): hold for voiceover"))
                    }
                } else {
                    let rate = max(options.minRate, have / needed)
                    newSpeeds.append(SpeedSegment(start: round3(scene.start), end: round3(scene.end), rate: round3(rate), origin: .auto,
                                                  reason: "\(tag): scene slowed to fit \(String(format: "%.1fs", needed)) of narration"))
                    if have / rate + 0.05 < needed { notes.append(String(format: "“%@”: narration is %.1fs but the scene can only stretch to %.1fs", scene.title, needed, have / rate)) }
                }
            } else if have > needed * options.compressAbove {
                let idleInside = idle.compactMap { $0.clamped(to: scene.range) }.filter { $0.duration >= 1.0 }
                let idleOut = idleInside.reduce(0.0) { acc, r in acc + (map.outputSpan(forSource: r)?.duration ?? 0) }
                let excess = have - needed
                if idleOut > 0 {
                    let rate = min(options.maxRate, idleOut / max(0.2, idleOut - excess))
                    for r in idleInside {
                        newSpeeds.append(SpeedSegment(start: round3(r.start), end: round3(r.end), rate: round3(rate), origin: .auto,
                                                      reason: "\(tag): idle sped up"))
                    }
                }
            }
            for s in newSpeeds {
                // Don't fight speeds the user or another planner set deliberately (non-fit speeds win).
                guard !doc.timeline.speeds.contains(where: { $0.range.overlaps(s.range) }) else { continue }
                ops.append(EditOperation.setSpeed(s))
                doc.timeline.speeds.append(s)
            }
        }
        // Nothing to do when the new fit equals the one already on the timeline (re-fit is idempotent).
        func key(_ s: SpeedSegment) -> [Double] { [round3(s.start), round3(s.end), round3(s.rate)] }
        let fresh = doc.timeline.speeds.filter { ($0.reason ?? "").hasPrefix(tag) }
        if old.count == fresh.count, zip(old.sorted { $0.start < $1.start }, fresh.sorted { $0.start < $1.start }).allSatisfy({ key($0) == key($1) }) {
            return Result(operations: [], notes: notes, outputDuration: TimeMap(document: input).outputDuration)
        }
        notes.append(String(format: "output %.1fs after fit", TimeMap(document: doc).outputDuration))
        return Result(operations: ops, notes: notes, outputDuration: TimeMap(document: doc).outputDuration)
    }

    /// Caption segments from voiceover clips, in source time, so the existing caption renderer can show them.
    public static func captions(document doc: ProjectDocument, clips: [VoiceoverClip], maxChars: Int) -> [CaptionSegment] {
        // Clip words are relative to the clip's output start; convert to source time through the map so captions
        // line up with the audio wherever speed changes sit underneath.
        let map = TimeMap(document: doc)
        var words: [CaptionWord] = []
        for c in clips.sorted(by: { $0.start < $1.start }) {
            let out0 = map.outputClamped(forSource: c.start)
            let ws = c.words.isEmpty ? evenWords(c) : c.words
            for w in ws {
                let s = map.source(forOutput: out0 + w.start), e = map.source(forOutput: out0 + w.end)
                words.append(CaptionWord(text: w.text, start: s, end: max(s + 0.05, e)))
            }
        }
        return CaptionBuilder.segments(from: words, maxChars: maxChars)
    }

    static func evenWords(_ c: VoiceoverClip) -> [CaptionWord] {
        let toks = c.text.split(separator: " ").map(String.init)
        let step = c.duration / Double(max(1, toks.count))
        return toks.enumerated().map { CaptionWord(text: $1, start: Double($0) * step, end: Double($0 + 1) * step) }
    }
}

// MARK: - Secrets

/// API keys for cloud services (ElevenLabs voices, the narration model). Keys are never compiled into the app.
/// Lookup order: environment variable, then the macOS Keychain, then a 0600 JSON file in the support folder.
/// Release builds (signed with a Team ID) store keys in the Keychain; development builds (ad-hoc signed, whose
/// identity changes every build) and anything run with `GLINT_HOME` use the file, so they never raise a Keychain
/// prompt. Agents can't read or set keys through tools.
public enum Secrets {
    public enum Key: String, CaseIterable, Sendable {
        case elevenlabs = "elevenlabs_api_key"
        case anthropic = "anthropic_api_key"
        public var environment: String { self == .elevenlabs ? "ELEVENLABS_API_KEY" : "ANTHROPIC_API_KEY" }
        public var title: String { self == .elevenlabs ? "ElevenLabs" : "Anthropic" }
    }
    public static let keychainService = "dev.glint.Glint"
    public static var fileURL: URL { GlintPaths.support.appendingPathComponent("secrets.json") }

    /// True when this process should keep keys in the Keychain.
    public static let usesKeychain: Bool = {
        guard ProcessInfo.processInfo.environment["GLINT_HOME"] == nil else { return false }
        return CodeIdentity.teamID != nil
    }()
    /// Where saved keys go, for settings screens.
    public static var storeDescription: String { usesKeychain ? "the macOS Keychain (service \(keychainService))" : fileURL.path }

    static func read() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))) ?? [:]
    }
    public static func get(_ k: Key) -> String? {
        if let e = ProcessInfo.processInfo.environment[k.environment], !e.isEmpty { return e }
        if usesKeychain, let v = Keychain.get(service: keychainService, account: k.rawValue), !v.isEmpty { return v }
        if let v = read()[k.rawValue], !v.isEmpty { return v }
        return nil
    }
    /// Where the key comes from ("environment", "keychain", "file" or nil).
    public static func source(_ k: Key) -> String? {
        if let e = ProcessInfo.processInfo.environment[k.environment], !e.isEmpty { return "environment" }
        if usesKeychain, let v = Keychain.get(service: keychainService, account: k.rawValue), !v.isEmpty { return "keychain" }
        if let v = read()[k.rawValue], !v.isEmpty { return "file" }
        return nil
    }
    public static func set(_ k: Key, _ value: String?) throws {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if usesKeychain {
            try Keychain.set(service: keychainService, account: k.rawValue, value: v.isEmpty ? nil : v)
            // A key that moved to the Keychain shouldn't linger in the plain file.
            if read()[k.rawValue] != nil { try writeFile(k, nil) }
            return
        }
        try writeFile(k, v.isEmpty ? nil : v)
    }
    static func writeFile(_ k: Key, _ value: String?) throws {
        var all = read()
        if let value { all[k.rawValue] = value } else { all.removeValue(forKey: k.rawValue) }
        if all.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
