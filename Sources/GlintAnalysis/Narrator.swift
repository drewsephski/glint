import Foundation
import ImageIO
import UniformTypeIdentifiers
import GlintCore

public enum NarratorError: Error, CustomStringConvertible {
    case noKey
    case http(Int, String)
    case refused(String)
    case badResponse(String)
    public var description: String {
        switch self {
        case .noKey: return "No Anthropic API key. Set ANTHROPIC_API_KEY, add it in Glint › Settings, or run `glint keys set anthropic`."
        case .http(let c, let m): return "Narration request failed (HTTP \(c)): \(m)"
        case .refused(let m): return "The model declined to write this script: \(m)"
        case .badResponse(let m): return "Unexpected narration response: \(m)"
        }
    }
}

public enum NarrationWriter: String, Codable, Sendable, CaseIterable { case auto, claude, chatgpt, apiKey = "api-key" }

public struct NarrationOptions: Codable, Hashable, Sendable {
    /// What the product is and who the video is for. The single most useful input.
    public var brief: String?
    public var tone: String = "clear, confident, friendly; no hype"
    /// Speaking rate used to budget words per scene.
    public var wordsPerSecond: Double = 2.5
    /// Model that writes the script.
    public var model: String = ProcessInfo.processInfo.environment["GLINT_NARRATION_MODEL"] ?? "claude-haiku-5-5"
    public var includeFrames = true
    public var language: String = "English"
    /// Only rewrite scenes without narration (keeps hand-edited lines).
    public var onlyMissing = false
    public var writer: NarrationWriter = .auto
    /// Length the finished video should have (s). Each scene's word budget becomes its share of this target ×
    /// `wordsPerSecond` instead of its recorded length, so the script is written to fit the goal.
    public var targetDuration: Double?
    /// Explicit word budgets per scene id; win over the computed ones.
    public var sceneWordBudgets: [String: Int]?
    /// Scenes whose line must be kept exactly (locked in the recipe): like `onlyMissing`, for these scenes only.
    public var keepScenes: [String] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case brief, tone, wordsPerSecond, model, includeFrames, language, onlyMissing, writer, targetDuration, sceneWordBudgets, keepScenes }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brief = try c.decodeIfPresent(String.self, forKey: .brief)
        tone = try c.decodeIfPresent(String.self, forKey: .tone) ?? tone
        wordsPerSecond = try c.decodeIfPresent(Double.self, forKey: .wordsPerSecond) ?? wordsPerSecond
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        includeFrames = try c.decodeIfPresent(Bool.self, forKey: .includeFrames) ?? includeFrames
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        onlyMissing = try c.decodeIfPresent(Bool.self, forKey: .onlyMissing) ?? onlyMissing
        writer = try c.decodeIfPresent(NarrationWriter.self, forKey: .writer) ?? .auto
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
        sceneWordBudgets = try c.decodeIfPresent([String: Int].self, forKey: .sceneWordBudgets)
        keepScenes = try c.decodeIfPresent([String].self, forKey: .keepScenes) ?? []
    }

    /// Whether the line already written for `scene` must stay as it is.
    public func keeps(_ scene: Scene) -> Bool {
        guard let n = scene.narration, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return onlyMissing || keepScenes.contains(scene.id)
    }
}

/// Writes the narration script with Claude: each scene goes in as its frame (what the viewer sees), the on-screen
/// text, the actions taken and any words the presenter said. Comes back as one line of narration per scene, timed
/// to the scene's length. Raw Messages API over URLSession (there is no Swift SDK).
public enum Narrator {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public static func write(bundle: ProjectBundle, storyboard input: Storyboard, document doc: ProjectDocument, options: NarrationOptions = .init()) async throws -> Storyboard {
        guard let key = Secrets.get(.anthropic) else { throw NarratorError.noKey }
        let (content, system, schema) = prompt(bundle: bundle, storyboard: input, document: doc, options: options)
        return try await request(bundle: bundle, storyboard: input, options: options, key: key, content: content, system: system, schema: schema)
    }

    /// The fewest words a scene's line can have and still say something (the prompt's floor).
    public static let minimumWords = 4
    /// Time a spoken line needs on screen: its words at the speaking rate, plus the fit's tail after each clip.
    public static func spokenSeconds(words: Int, wordsPerSecond: Double) -> Double { Double(words) / max(0.5, wordsPerSecond) + 0.45 }

    /// Words per scene. Without a target: the scene's recorded length × rate (as before). With `targetDuration`: the
    /// scene's share of the edited output (its kept, retimed length; recorded length when it has none) × target ×
    /// rate, after reserving the fit's 0.45 s tail per scene. Never below `minimumWords`; explicit budgets win.
    public static func wordBudgets(storyboard sb: Storyboard, document doc: ProjectDocument, options: NarrationOptions) -> [String: Int] {
        var out: [String: Int] = [:]
        let wps = options.wordsPerSecond
        if let target = options.targetDuration, target > 0, !sb.scenes.isEmpty {
            let map = TimeMap(document: doc)
            let lengths = sb.scenes.map { s in map.outputSpan(forSource: s.range)?.duration ?? s.duration }
            let sum = lengths.reduce(0, +)
            let speakable = max(0, target - 0.45 * Double(sb.scenes.count))
            for (s, l) in zip(sb.scenes, lengths) {
                let share = sum > 0 ? l / sum : 1 / Double(sb.scenes.count)
                out[s.id] = max(minimumWords, Int((share * speakable * wps).rounded()))
            }
        } else {
            for s in sb.scenes { out[s.id] = max(minimumWords, Int((s.duration * wps).rounded())) }
        }
        for (k, v) in options.sceneWordBudgets ?? [:] where out[k] != nil { out[k] = max(1, v) }
        return out
    }

    public static func prompt(bundle: ProjectBundle, storyboard sb: Storyboard, document doc: ProjectDocument, options: NarrationOptions) -> ([JSONValue], String, JSONValue) {
        let total = sb.scenes.reduce(0) { $0 + $1.duration }
        let map = TimeMap(document: doc)
        let budgets = wordBudgets(storyboard: sb, document: doc, options: options)
        // Backstop for the privacy masks: frames and on-screen text extracted before the current masks were set
        // never leave the Mac (callers re-analyse first; this only guards a caller that didn't).
        let masked = sb.masksCurrent(for: doc)

        var content: [JSONValue] = []
        var header = """
        Write the voiceover for a product demo video made from a screen recording of someone using the product.
        Language: \(options.language). Tone: \(options.tone).
        The recording is \(String(format: "%.0f", total)) seconds long in \(sb.scenes.count) scenes; the edited video currently runs \(String(format: "%.0f", map.outputDuration)) seconds.
        """
        if let target = options.targetDuration, target > 0 {
            let words = budgets.values.reduce(0, +)
            header += "\nThe finished video should run about \(String(format: "%.0f", target)) seconds, so the whole script has a budget of about \(words) words. Stay within each scene's budget; say less rather than more."
        }
        if let b = options.brief?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty { header += "\nAbout the product and audience: \(b)" }
        if let t = bundle.readTranscript(), t.words.count > 5 { header += "\nThe presenter spoke while recording; their words are given per scene. Use them for intent and names, but write cleaner narration." }
        content.append(.object(["type": .string("text"), "text": .string(header)]))

        for (i, s) in sb.scenes.enumerated() {
            let budget = budgets[s.id] ?? max(minimumWords, Int((s.duration * options.wordsPerSecond).rounded()))
            var facts = "SCENE \(i + 1) · id \(s.id) · \(String(format: "%.1f", s.duration))s · about \(budget) words"
            if let app = s.app { facts += " · app: \(app)" }
            facts += "\nActions: \(s.actions.isEmpty ? "none (watching)" : s.actions.joined(separator: ", "))"
            if masked, !s.onScreenText.isEmpty { facts += "\nOn screen: " + s.onScreenText.prefix(28).joined(separator: " | ") }
            if let sp = s.speech { facts += "\nPresenter said: “\(sp)”" }
            if options.keeps(s), let n = s.narration { facts += "\nKEEP this narration exactly: “\(n)”" }
            if masked, options.includeFrames, let f = s.frame, let data = jpegData(bundle.resolve(f), maxPixels: 1280) {
                content.append(.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string(data.base64EncodedString())])]))
            }
            content.append(.object(["type": .string("text"), "text": .string(facts)]))
        }

        let system = """
        You are a narration writer for software product demos (the kind of voiceover Clueso or Screen Studio demos use). \
        You get one scene at a time: a frame of the screen, the text visible on it, what the user did and how long the scene lasts.

        Write one narration line per scene that tells viewers what they are seeing and why it matters, in the order it happens. \
        Rules: present tense; speak to the viewer ("you"); mention the exact label of a button or field in the scene when the user interacts with it; \
        never describe mouse movements or say "click on"; no filler openings ("In this video", "Let's dive in", "Welcome"), no exclamation marks, no emoji, no markdown. \
        Keep each scene within about its word budget (the video is retimed to the narration, so ±25% is fine; never more than double). \
        Scene 1 opens with a one-sentence hook that names the product and what the viewer will get. The last scene ends with a short, concrete close. \
        Scenes flow as one script, so avoid repeating the same opener. Write words as they should be spoken (expand abbreviations, spell numbers naturally). \
        Return JSON only, matching the schema: a title for the video, a one-sentence summary, and for every scene its id, a short title (2–5 words) and the narration text.
        """

        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")]),
                "scenes": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")]), "title": .object(["type": .string("string")]), "narration": .object(["type": .string("string")])]),
                    "required": .array([.string("id"), .string("title"), .string("narration")]),
                    "additionalProperties": .bool(false),
                ])]),
            ]),
            "required": .array([.string("title"), .string("summary"), .string("scenes")]),
            "additionalProperties": .bool(false),
        ])
        return (content, system, schema)
    }

    static func request(bundle: ProjectBundle, storyboard: Storyboard, options: NarrationOptions, key: String, content: [JSONValue], system: String, schema: JSONValue) async throws -> Storyboard {
        let body: JSONValue = .object([
            "model": .string(options.model),
            "max_tokens": .number(16000),
            "system": .string(system),
            "fallbacks": .string("default"),
            "output_config": .object(["format": .object(["type": .string("json_schema"), "schema": schema])]),
            "messages": .array([.object(["role": .string("user"), "content": .array(content)])]),
        ])
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONCoding.compactEncoder.encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONCoding.decoder.decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            throw NarratorError.http(status, json["error"]?["message"]?.stringValue ?? String(data: data, encoding: .utf8) ?? "")
        }
        if json["stop_reason"]?.stringValue == "refusal" {
            throw NarratorError.refused(json["stop_details"]?["explanation"]?.stringValue ?? json["stop_details"]?["category"]?.stringValue ?? "refusal")
        }
        guard let text = json["content"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue,
              let out = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8)) else {
            throw NarratorError.badResponse(String(data: data.prefix(400), encoding: .utf8) ?? "")
        }
        return try apply(out, writer: json["model"]?.stringValue ?? options.model, bundle: bundle, storyboard: storyboard, options: options)
    }

    public static func apply(_ out: JSONValue, writer: String, bundle: ProjectBundle, storyboard: Storyboard, options: NarrationOptions) throws -> Storyboard {
        var sb = storyboard
        for item in out["scenes"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue, let i = sb.scenes.firstIndex(where: { $0.id == id }) else { continue }
            let line = item["narration"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if options.keeps(sb.scenes[i]) { continue }
            sb.scenes[i].narration = line.isEmpty ? nil : line
            if let t = item["title"]?.stringValue, !t.isEmpty { sb.scenes[i].title = t }
        }
        sb.title = out["title"]?.stringValue ?? sb.title
        sb.summary = out["summary"]?.stringValue ?? sb.summary
        sb.brief = options.brief ?? sb.brief
        sb.writer = writer
        sb.createdAt = Date()
        try Task.checkCancellation()
        try bundle.writeStoryboard(sb)
        return sb
    }

    static func jpegData(_ url: URL, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
