import Foundation
import AVFoundation
import GlintCore

/// A referenced media file the render needs but can't use. Muted tracks and hidden facecams are intentional and never
/// reported: only media the edit says should be seen or heard.
public struct MediaProblem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case screen, shot, shotAudio = "shot_audio", microphone, systemAudio = "system_audio", camera, voiceover, audioClip = "audio_clip"
    }
    public enum Reason: String, Codable, Sendable { case missing, unreadable, silentOutOfRange = "out_of_range" }
    public var kind: Kind
    public var reason: Reason
    /// Bundle-relative path (as stored in the document).
    public var path: String
    /// Timeline item the file belongs to (voiceover clip, audio clip or shot id), if any.
    public var itemID: String?
    /// Storyboard scene the item narrates, if any.
    public var scene: String?
    /// One sentence for a person, naming what is affected and what to do.
    public var message: String
    /// Blocking problems stop an export: the file would otherwise silently lose that picture or sound.
    public var blocking: Bool
    public var id: String { "\(kind.rawValue):\(itemID ?? path)" }
}

/// What a render of `document` is expected to contain, derived from the edit itself, and whether the media for it is
/// present and decodable. Export runs this before rendering so a missing narration file can't produce a "complete" video.
public enum MediaPreflight {
    public static func check(bundle: ProjectBundle, document doc: ProjectDocument) async -> [MediaProblem] {
        var out: [MediaProblem] = []
        let audio = doc.style.audio
        let layout = ClipLayout(document: doc)
        let sceneTitles = Dictionary((bundle.readStoryboard()?.scenes ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var probed: [String: MediaProblem.Reason?] = [:]
        func status(_ path: String, _ type: AVMediaType) async -> MediaProblem.Reason? {
            let key = "\(type.rawValue)|\(path)"
            if let r = probed[key] { return r }
            let r = await probe(bundle.resolve(path), type)
            probed[key] = r
            return r
        }
        func add(_ kind: MediaProblem.Kind, _ reason: MediaProblem.Reason, _ path: String, item: String? = nil, scene: String? = nil, _ message: String, blocking: Bool = true) {
            out.append(MediaProblem(kind: kind, reason: reason, path: path, itemID: item, scene: scene, message: message, blocking: blocking))
        }
        func what(_ r: MediaProblem.Reason) -> String { r == .missing ? "is missing" : "can't be read" }
        let file = { (p: String) in (p as NSString).lastPathComponent }

        // Picture: every shot on the program timeline.
        for seg in layout.segments {
            if let r = await status(seg.clip.path, .video) {
                add(seg.clip.primary ? .screen : .shot, r, seg.clip.path, item: seg.clip.id,
                    "The footage for shot “\(seg.clip.name)” \(what(r)) (\(file(seg.clip.path))). Re-import the shot or remove it.")
            }
        }
        let hasPrimary = layout.segments.contains { $0.clip.primary }
        // The recording's own tracks, unless muted on purpose.
        if hasPrimary, let mic = doc.media.microphone, !audio.muteMicrophone, let r = await status(mic, .audio) {
            add(.microphone, r, mic, "The microphone recording \(what(r)) (\(file(mic))). Restore the file, or mute the microphone to export without it.")
        }
        if hasPrimary, let sys = doc.media.systemAudio, !audio.muteSystem, let r = await status(sys, .audio) {
            add(.systemAudio, r, sys, "The system audio recording \(what(r)) (\(file(sys))). Restore the file, or mute system audio to export without it.")
        }
        if hasPrimary, doc.style.facecam.visible, let cam = doc.media.camera, let r = await status(cam, .video) {
            add(.camera, r, cam, "The camera recording \(what(r)) (\(file(cam))). Restore the file, or hide the facecam.")
        }
        if !audio.muteSystem {
            for seg in layout.segments where !seg.clip.primary {
                for p in seg.clip.audio { if let r = await status(p, .audio) {
                    add(.shotAudio, r, p, item: seg.clip.id, "The sound for shot “\(seg.clip.name)” \(what(r)) (\(file(p))). Re-import the shot or mute system audio.")
                } }
            }
        }
        // Narration and imported audio.
        let map = TimeMap(document: doc)
        let end = map.outputDuration
        if !audio.muteVoiceover {
            for clip in doc.timeline.voiceover.sorted(by: { $0.start < $1.start }) {
                let title = clip.scene.flatMap { sceneTitles[$0] }
                let name = title.map { "the voiceover for “\($0)”" } ?? "the voiceover “\(snippet(clip.text))”"
                if let r = await status(clip.path, .audio) {
                    add(.voiceover, r, clip.path, item: clip.id, scene: clip.scene,
                        "\(name.prefix(1).uppercased() + name.dropFirst()) \(what(r)). Regenerate it, locate the file, or remove it from this export.")
                } else if end - map.outputClamped(forSource: clip.start) <= 0.05 {
                    add(.voiceover, .silentOutOfRange, clip.path, item: clip.id, scene: clip.scene,
                        "\(name.prefix(1).uppercased() + name.dropFirst()) starts after the video ends, so it won't be heard. Move it earlier or remove it.", blocking: false)
                }
            }
        }
        for clip in doc.timeline.audio {
            if clip.kind == .music && audio.muteMusic { continue }
            if clip.kind == .voice && audio.muteVoiceover { continue }
            if let r = await status(clip.path, .audio) {
                let kind = clip.kind == .music ? "music" : clip.kind == .voice ? "voice clip" : "sound effect"
                add(.audioClip, r, clip.path, item: clip.id, "The \(kind) “\(clip.name)” \(what(r)) (\(file(clip.path))). Locate the file, or remove it from this export.")
            }
        }
        return out
    }

    /// Output-time intervals where the export should contain narration (voiceover clips and imported voice clips),
    /// clipped to the video. The render inspector checks these aren't silent.
    public static func expectedSpeech(document doc: ProjectDocument) -> [TimeRange] {
        guard !doc.style.audio.muteVoiceover else { return [] }
        let map = TimeMap(document: doc)
        let end = map.outputDuration
        var out: [TimeRange] = []
        for c in doc.timeline.voiceover where c.gain > 0.01 {
            let s = map.outputClamped(forSource: c.start)
            let e = min(end, s + c.duration)
            if e - s > 0.3 { out.append(TimeRange(s, e)) }
        }
        for c in doc.timeline.audio where c.kind == .voice && c.gain > 0.01 {
            let s = map.outputClamped(forSource: c.start)
            for span in c.playSpans(outputStart: s, videoEnd: end) where span.output.duration > 0.3 { out.append(span.output) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// nil when the file exists and has a decodable track of `type` with a positive duration.
    static func probe(_ url: URL, _ type: AVMediaType) async -> MediaProblem.Reason? {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let a = AVURLAsset(url: url)
        guard let track = try? await a.loadTracks(withMediaType: type).first,
              let range = try? await track.load(.timeRange), range.duration.seconds.isFinite, range.duration.seconds > 0 else { return .unreadable }
        return nil
    }

    static func snippet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}
