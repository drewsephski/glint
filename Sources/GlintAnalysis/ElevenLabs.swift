import Foundation
import AVFoundation
import GlintCore

public enum VoiceError: Error, CustomStringConvertible {
    case noKey
    case http(Int, String)
    case badResponse(String)
    case noVoice
    public var description: String {
        switch self {
        case .noKey: return "Voiceover needs a voice pack or your own ElevenLabs key. Open Glint › Settings › Narration to choose."
        case .http(let c, let m): return "ElevenLabs request failed (HTTP \(c)): \(m)"
        case .badResponse(let m): return "Unexpected ElevenLabs response: \(m)"
        case .noVoice: return "No voice chosen. Pick one with glint_list_voices / `glint voices`, then pass voice (ID or name) or set style.voice.voiceID."
        }
    }
}

public struct Voice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String?
    public var description: String?
    public var labels: [String: String]
    public var previewURL: String?
    public init(id: String, name: String, category: String? = nil, description: String? = nil, labels: [String: String] = [:], previewURL: String? = nil) {
        self.id = id; self.name = name; self.category = category; self.description = description; self.labels = labels; self.previewURL = previewURL
    }
}

/// ElevenLabs text-to-speech. Synthesis uses the `with-timestamps` endpoint so every word has a time, which gives
/// exact captions and lets the fit planner know how long each line is.
public enum ElevenLabs {
    static let base = URL(string: "https://api.elevenlabs.io")!

    static func request(_ path: String, method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        guard let key = Secrets.get(.elevenlabs) else { throw VoiceError.noKey }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONCoding.compactEncoder.encode(body)
        }
        return req
    }

    static func send(_ req: URLRequest) async throws -> JSONValue {
        try Task.checkCancellation()
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONCoding.decoder.decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            let detail = json["error"]?.stringValue ?? json["detail"]?["message"]?.stringValue ?? json["detail"]?.stringValue ?? json["detail"]?.description ?? "Please try again."
            throw VoiceError.http(status, detail)
        }
        return json
    }

    /// Voices available to this account (premade and cloned), name-sorted.
    public static func voices() async throws -> [Voice] {
        var req: URLRequest
        if Secrets.get(.elevenlabs) != nil {
            req = try request("/v2/voices")
            req.url = URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100&include_total_count=false")
        } else {
            req = try HostedVoice.request("v1/voices")
        }
        let json = try await send(req)
        let vs = (json["voices"]?.arrayValue ?? []).compactMap { v -> Voice? in
            guard let id = v["voice_id"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
            var labels: [String: String] = [:]
            if case .object(let o)? = v["labels"] { for (k, val) in o { if let s = val.stringValue { labels[k] = s } } }
            return Voice(id: id, name: name, category: v["category"]?.stringValue, description: v["description"]?.stringValue, labels: labels, previewURL: v["preview_url"]?.stringValue)
        }
        return vs.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Resolve a voice by ID or (case-insensitive) name.
    public static func resolve(_ ref: String) async throws -> Voice {
        let all = try await voices()
        if let v = all.first(where: { $0.id == ref }) ?? all.first(where: { $0.name.lowercased() == ref.lowercased() }) ?? all.first(where: { $0.name.lowercased().hasPrefix(ref.lowercased()) }) { return v }
        throw VoiceError.badResponse("no voice named or with ID “\(ref)”. Available: \(all.map(\.name).joined(separator: ", "))")
    }

    public struct Synthesis: Sendable {
        public var audio: Data
        /// Word timings relative to the start of the audio.
        public var words: [CaptionWord]
    }

    public static func synthesize(text: String, voiceID: String, style: VoiceStyle, previous: String? = nil, next: String? = nil) async throws -> Synthesis {
        var settings: [String: JSONValue] = ["stability": .number(style.stability), "similarity_boost": .number(style.similarity),
                                             "style": .number(style.style), "use_speaker_boost": .bool(true)]
        if abs(style.speed - 1) > 0.001 { settings["speed"] = .number(max(0.7, min(1.2, style.speed))) }
        var body: [String: JSONValue] = ["text": .string(text), "model_id": .string(style.model), "output_format": .string("mp3_44100_128"),
                                         "voice_settings": .object(settings)]
        if let previous, !previous.isEmpty { body["previous_text"] = .string(previous) }
        if let next, !next.isEmpty { body["next_text"] = .string(next) }
        var req: URLRequest
        if Secrets.get(.elevenlabs) != nil {
            req = try request("/v1/text-to-speech/\(voiceID)/with-timestamps", method: "POST", body: .object(body))
        } else {
            body["voiceID"] = .string(voiceID)
            req = try HostedVoice.request("v1/synthesize", method: "POST", body: .object(body))
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        let json = try await send(req)
        guard let b64 = json["audio_base64"]?.stringValue, let audio = Data(base64Encoded: b64) else { throw VoiceError.badResponse("no audio in response") }
        let alignment = json["alignment"] ?? json["normalized_alignment"] ?? .null
        return Synthesis(audio: audio, words: words(from: alignment))
    }

    /// Character timings → word timings (split on whitespace, punctuation stays attached).
    static func words(from alignment: JSONValue) -> [CaptionWord] {
        guard let chars = alignment["characters"]?.arrayValue?.compactMap(\.stringValue),
              let starts = alignment["character_start_times_seconds"]?.arrayValue?.compactMap(\.doubleValue),
              let ends = alignment["character_end_times_seconds"]?.arrayValue?.compactMap(\.doubleValue),
              chars.count == starts.count, chars.count == ends.count else { return [] }
        var out: [CaptionWord] = []
        var cur = "", s = 0.0, e = 0.0
        for (i, c) in chars.enumerated() {
            if c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !cur.isEmpty { out.append(CaptionWord(text: cur, start: s, end: e)); cur = "" }
            } else {
                if cur.isEmpty { s = starts[i] }
                cur += c; e = ends[i]
            }
        }
        if !cur.isEmpty { out.append(CaptionWord(text: cur, start: s, end: e)) }
        return out
    }

    /// Generate one clip per narrated scene into `media/voiceover/`, returning clips anchored at each scene's start.
    public static func makeClips(bundle: ProjectBundle, storyboard: Storyboard, voice: Voice, style: VoiceStyle, scenes only: Set<String>? = nil,
                                 origin: Origin = .agent, progress: (@Sendable (String) -> Void)? = nil) async throws -> [VoiceoverClip] {
        try FileManager.default.createDirectory(at: bundle.voiceoverURL, withIntermediateDirectories: true)
        let narrated = storyboard.narratedScenes.filter { only?.contains($0.id) ?? true }
        if !narrated.isEmpty, Secrets.get(.elevenlabs) == nil {
            let lengths = narrated.map { ($0.narration ?? "").trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }
            guard lengths.allSatisfy({ $0 <= 5_000 }) else { throw VoiceError.badResponse("Split narration longer than 5,000 characters into smaller scenes.") }
            let access = try await HostedVoice.access()
            guard access.remaining >= lengths.reduce(0, +) else {
                throw VoiceError.http(402, "This script needs more characters than your remaining balance. Add a voice pack or use your own ElevenLabs key.")
            }
        }
        var clips: [VoiceoverClip] = []
        for (i, s) in narrated.enumerated() {
            try Task.checkCancellation()
            progress?("voice \(i + 1)/\(narrated.count): \(s.title)")
            let text = s.narration!.trimmingCharacters(in: .whitespacesAndNewlines)
            let prev = i > 0 ? narrated[i - 1].narration : nil
            let next = i + 1 < narrated.count ? narrated[i + 1].narration : nil
            let syn = try await synthesize(text: text, voiceID: voice.id, style: style, previous: prev, next: next)
            let id = IDs.make("vo")
            let rel = "media/voiceover/\(id).mp3"
            try Task.checkCancellation()
            try syn.audio.write(to: bundle.resolve(rel), options: .atomic)
            let duration = try await AVURLAsset(url: bundle.resolve(rel)).load(.duration).seconds
            let dur = duration.isFinite && duration > 0 ? duration : (syn.words.last?.end ?? Double(text.count) / 14)
            clips.append(VoiceoverClip(id: id, start: s.start, path: rel, text: text, duration: round3(dur), words: syn.words, voice: voice.id, voiceName: voice.name,
                                       scene: s.id, origin: origin, reason: "narration for “\(s.title)”"))
        }
        return clips
    }
}
