import Foundation
import AVFoundation
import GlintCore
import GlintAnalysis

/// What a voiceover pass produced, in one shape for the app, CLI and MCP.
public struct VoiceoverResult: Codable, Sendable {
    public var operations: [EditOperation]
    public var clips: [VoiceoverClip]
    public var voice: String
    public var voiceName: String
    public var fitNotes: [String]
    public var captions: Int
    public var outputDuration: Double
}

/// Narration: scene analysis (on-device), script writing (Claude), voice synthesis (ElevenLabs) and the fit that
/// retimes the picture to the voice. Cloud steps are `external` actions: people are trusted for their own clicks,
/// agents need the user's approval (or an `external: allow` policy).
extension GlintService {
    public func analyzeScenes(_ b: ProjectBundle, options: SceneAnalyzer.Options = .init(), progress: (@Sendable (String) -> Void)? = nil) async throws -> Storyboard {
        try await SceneAnalyzer.analyze(bundle: b, document: try b.readDocument(), options: options, progress: progress)
    }

    public func storyboard(_ b: ProjectBundle) -> Storyboard? { b.readStoryboard() }

    /// Set narration lines by hand (a person in the app, or an agent that writes its own script).
    public func setNarration(_ b: ProjectBundle, lines: [String: String?], title: String? = nil, brief: String? = nil) throws -> Storyboard {
        guard var sb = b.readStoryboard() else { throw ServiceError.invalid("No storyboard yet. Run analyze_scenes first.") }
        for (id, text) in lines {
            guard let i = sb.scenes.firstIndex(where: { $0.id == id }) else { throw ServiceError.invalid("No scene \(id) in the storyboard") }
            let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            sb.scenes[i].narration = (t?.isEmpty ?? true) ? nil : t
        }
        if let title { sb.title = title }
        if let brief { sb.brief = brief }
        try b.writeStoryboard(sb)
        return sb
    }

    public func writeNarration(_ b: ProjectBundle, options: NarrationOptions, author: Author, approvalID: String?) async throws -> Storyboard {
        let doc = try b.readDocument()
        let sb = try await { if let s = b.readStoryboard(), s.revision == doc.revision || !s.scenes.isEmpty { return s }; return try await analyzeScenes(b) }()
        var params: [String: JSONValue] = ["project": .string(b.url.path), "model": .string(options.model), "scenes": .number(Double(sb.scenes.count))]
        if let brief = options.brief { params["brief"] = .string(brief) }
        try approvals.authorize(action: "write_narration", risk: .external,
                                summary: "Send \(sb.scenes.count) scene frames and their on-screen text to Anthropic (\(options.model)) to write the narration",
                                parameters: .object(params), author: author, approvalID: approvalID)
        return try await Narrator.write(bundle: b, storyboard: sb, document: doc, options: options)
    }

    public func voices() async throws -> [Voice] { try await ElevenLabs.voices() }

    /// Resolve the voice to use: an explicit reference, else the project's saved voice.
    public func resolveVoice(_ ref: String?, document doc: ProjectDocument) async throws -> Voice {
        if let ref, !ref.isEmpty { return try await ElevenLabs.resolve(ref) }
        if let id = doc.style.voice.voiceID { return Voice(id: id, name: doc.style.voice.voiceName ?? id, category: nil, description: nil, labels: [:], previewURL: nil) }
        throw VoiceError.noVoice
    }

    /// Synthesize narration for the storyboard's scenes and return the operations that add the clips (plus optional
    /// retiming and captions). Nothing is applied here: callers propose or apply.
    public func voiceover(_ b: ProjectBundle, voice ref: String?, scenes only: Set<String>? = nil, fit: Bool = true, captions: Bool = true,
                          author: Author, approvalID: String?, progress: (@Sendable (String) -> Void)? = nil) async throws -> VoiceoverResult {
        let doc = try b.readDocument()
        guard let sb = b.readStoryboard() else { throw ServiceError.invalid("No storyboard yet. Run analyze_scenes and write (or set) narration first.") }
        let requested = sb.narratedScenes.filter { only?.contains($0.id) ?? true }
        guard !requested.isEmpty else { throw ServiceError.invalid("No scene has narration yet. Use write_narration or set_narration first.") }
        let voice = try await resolveVoice(ref, document: doc)
        // Billing safety: a scene whose clip already speaks the same line in the same voice is not sent again.
        let narrated = requested.filter { s in
            !doc.timeline.voiceover.contains { v in
                v.scene == s.id && v.text == s.narration?.trimmingCharacters(in: .whitespacesAndNewlines) && v.voice == voice.id && FileManager.default.fileExists(atPath: b.resolve(v.path).path)
            }
        }
        guard !narrated.isEmpty else {
            return VoiceoverResult(operations: [], clips: [], voice: voice.id, voiceName: voice.name,
                                   fitNotes: ["Every requested scene already has a voiceover with this line and voice; nothing was sent to ElevenLabs."],
                                   captions: 0, outputDuration: TimeMap(document: doc).outputDuration)
        }
        let words = narrated.reduce(0) { $0 + ($1.narration ?? "").split(separator: " ").count }
        try approvals.authorize(action: "voiceover", risk: .external,
                                summary: "Send the \(words)-word script (\(narrated.count) scenes) to ElevenLabs to synthesize voice “\(voice.name)”",
                                parameters: .object(["project": .string(b.url.path), "voice": .string(voice.id), "scenes": .array(narrated.map { .string($0.id) }),
                                                     "script_hash": .string(StableHash.hex(narrated.compactMap(\.narration).joined(separator: "\n")))]),
                                author: author, approvalID: approvalID)
        let clips = try await ElevenLabs.makeClips(bundle: b, storyboard: sb, voice: voice, style: doc.style.voice, scenes: Set(narrated.map(\.id)),
                                                   origin: author.kind == .agent ? .agent : .manual, progress: progress)
        var ops: [EditOperation] = []
        // Replace earlier clips for the same scenes.
        let replaced = Set(clips.compactMap(\.scene))
        for old in doc.timeline.voiceover where old.scene.map(replaced.contains) ?? false { ops.append(EditOperation(.removeVoiceover, id: old.id)) }
        ops += clips.map(EditOperation.addVoiceover)
        if doc.style.voice.voiceID != voice.id {
            ops.append(.style("voice.voiceID", .string(voice.id)))
            ops.append(.style("voice.voiceName", .string(voice.name)))
        }
        var after = try OperationApplier.apply(ops, to: doc)
        var notes: [String] = []
        if fit {
            let r = NarrationFit.plan(document: after, events: b.programEvents(for: after), scenes: sb.scenes, clips: after.timeline.voiceover)
            if !r.operations.isEmpty { ops += r.operations; after = try OperationApplier.apply(r.operations, to: after) }
            notes = r.notes
        }
        var captionCount = 0
        if captions {
            let segs = NarrationFit.captions(document: after, clips: after.timeline.voiceover, maxChars: after.style.captions.maxCharsPerLine)
            captionCount = segs.count
            ops.append(EditOperation(.setCaptions, items: segs))
            ops.append(.style("captions.enabled", .bool(true)))
            after = try OperationApplier.apply(Array(ops.suffix(2)), to: after)
        }
        progress?("done: \(clips.count) clips")
        return VoiceoverResult(operations: ops, clips: clips, voice: voice.id, voiceName: voice.name, fitNotes: notes, captions: captionCount,
                               outputDuration: TimeMap(document: after).outputDuration)
    }

    /// Re-time the picture to the existing clips (after moving clips or changing cuts).
    public func fitToNarration(_ b: ProjectBundle, captions: Bool = true) throws -> (ops: [EditOperation], notes: [String]) {
        let doc = try b.readDocument()
        guard !doc.timeline.voiceover.isEmpty else { throw ServiceError.invalid("No voiceover clips to fit to.") }
        let scenes = b.readStoryboard()?.scenes ?? SceneSegmenter.scenes(document: doc, events: b.programEvents(for: doc), transcript: b.programTranscript(for: doc))
        let r = NarrationFit.plan(document: doc, events: b.programEvents(for: doc), scenes: scenes, clips: doc.timeline.voiceover)
        var ops = r.operations
        if captions {
            let after = try OperationApplier.apply(ops, to: doc)
            let segs = NarrationFit.captions(document: after, clips: after.timeline.voiceover, maxChars: doc.style.captions.maxCharsPerLine)
            // Only rewrite captions when they'd actually change (ids aside).
            let same = segs.count == doc.timeline.captions.count && zip(segs, doc.timeline.captions).allSatisfy { a, b in
                a.text == b.text && abs(a.start - b.start) < 1e-3 && abs(a.end - b.end) < 1e-3
            }
            if !same { ops.append(EditOperation(.setCaptions, items: segs)) }
        }
        return (ops, r.notes)
    }
}
