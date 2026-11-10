import Foundation
import AVFoundation
import CoreImage
import Metal
import GlintCore

public enum RenderError: Error, CustomStringConvertible {
    case missingMedia(String)
    case failed(String)
    case cancelled
    public var description: String {
        switch self {
        case .cancelled: return "Render cancelled"
        case .missingMedia(let s): return "Missing media: \(s)"
        case .failed(let s): return "Render failed: \(s)"
        }
    }
}

/// Instruction carrying the render plan to the compositor.
final class GlintInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlan
    let trackID: CMPersistentTrackID
    /// The facecam's track, when the project has a camera recording and the bubble is shown.
    let cameraTrackID: CMPersistentTrackID?
    let frameDuration: Double
    let screenTransforms: [String: CGAffineTransform]
    let cameraTransform: CGAffineTransform
    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, plan: RenderPlan, frameDuration: Double,
         screenTransforms: [String: CGAffineTransform], cameraTransform: CGAffineTransform) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.cameraTrackID = cameraTrackID
        self.requiredSourceTrackIDs = ([trackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
        self.plan = plan
        self.frameDuration = frameDuration
        self.screenTransforms = screenTransforms
        self.cameraTransform = cameraTransform
    }
}

/// Shared GPU context for all rendering.
public enum GPU {
    public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    public static let context: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false, .name: "glint"]
        if let d = device { return CIContext(mtlDevice: d, options: opts) }
        return CIContext(options: opts)
    }()
}

/// Custom compositor: renders each output frame with `SceneRenderer`. Used by AVPlayer (preview), AVAssetReader
/// (export) and AVAssetImageGenerator (frames, contact sheets, GIF) — one code path, so preview == export.
final class GlintCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                kCVPixelBufferMetalCompatibilityKey as String: true]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                kCVPixelBufferMetalCompatibilityKey as String: true]
    var supportsWideColorSourceFrames: Bool { false }
    private let queue = DispatchQueue(label: "glint.compositor", qos: .userInitiated, attributes: .concurrent)
    private var cancelled = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.cancelled { request.finishCancelledRequest(); return }
            guard let inst = request.videoCompositionInstruction as? GlintInstruction else {
                request.finish(with: RenderError.failed("unexpected instruction")); return
            }
            guard let out = request.renderContext.newPixelBuffer() else { request.finish(with: RenderError.failed("no output buffer")); return }
            let sourceTime = inst.plan.map.source(forOutput: request.compositionTime.seconds)
            let path = inst.plan.clips.segment(at: sourceTime)?.clip.path
            let transform = path.flatMap { inst.screenTransforms[$0] } ?? .identity
            let screen = request.sourceFrame(byTrackID: inst.trackID).map {
                SceneRenderer.oriented(CIImage(cvPixelBuffer: $0), preferredTransform: transform)
            }
            let camera = inst.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map {
                SceneRenderer.oriented(CIImage(cvPixelBuffer: $0), preferredTransform: inst.cameraTransform)
            }
            let image = SceneRenderer.render(plan: inst.plan, screen: screen, camera: camera, outputTime: request.compositionTime.seconds, frameDuration: inst.frameDuration)
            GPU.context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out)),
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async(flags: .barrier) { self.cancelled = false }
    }
}

/// An AVFoundation composition realizing a document: cuts/speed via the time map, audio mix, custom compositor.
public struct EditComposition: @unchecked Sendable {
    public let asset: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let plan: RenderPlan
    public var duration: Double { plan.map.outputDuration }

    public static func build(bundle: ProjectBundle, document: ProjectDocument, events: EventLog? = nil,
                             width: Int? = nil, height: Int? = nil, frameRate: Double? = nil,
                             loudnessGain: [String: Double] = [:]) async throws -> EditComposition {
        // Documents can arrive from disk or raw agent operations, bypassing import's media probe.
        // Reject unbounded sample counts before constructing cursor and camera paths.
        try OperationApplier.validate(document)
        let (dw, dh) = RenderPlan.outputSize(document: document)
        let plan = RenderPlan(document: document, events: events ?? bundle.programEvents(for: document), bundle: bundle, width: width ?? dw, height: height ?? dh)
        let fps = frameRate ?? min(60, max(24, document.media.frameRate))
        let comp = AVMutableComposition()
        let ts: CMTimeScale = 60000
        func ct(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }

        // Media cache: one asset + duration per file.
        var assets: [String: (AVURLAsset, CMTime)] = [:]
        var videoTransforms: [String: CGAffineTransform] = [:]
        var vTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        func asset(_ path: String) async -> (AVURLAsset, CMTime)? {
            if let a = assets[path] { return a }
            let url = bundle.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let d = try? await a.load(.duration) else { return nil }
            assets[path] = (a, d)
            return (a, d)
        }

        // The program's pieces: each time-map piece split at clip boundaries → (clip, file range, output range).
        struct Shot { var clip: MediaClip; var fileStart: Double; var duration: Double; var outStart: Double; var rate: Double }
        let layout = plan.clips
        var shots: [Shot] = []
        for p in plan.map.pieces {
            for (seg, sub) in layout.pieces(p.source) where sub.duration > 1e-6 {
                shots.append(Shot(clip: seg.clip, fileStart: seg.fileTime(sub.start), duration: sub.duration,
                                  outStart: p.outputStart + (sub.start - p.source.start) / p.rate, rate: p.rate))
            }
        }

        /// Insert the shots `include` selects from `path`'s track of `type` into `dst`, each at its own output time
        /// (so tracks stay aligned whatever media is missing).
        func place(_ dst: AVMutableCompositionTrack, type: AVMediaType, path: (MediaClip) -> String?, include: (MediaClip) -> Bool) async throws -> Bool {
            var placed = false
            for sh in shots where include(sh.clip) {
                guard let file = path(sh.clip), let (a, d) = await asset(file), let src = try? await a.loadTracks(withMediaType: type).first else {
                    if type == .video, dst.trackID == vTrackID { throw RenderError.missingMedia("no playable video for clip \(sh.clip.name)") }
                    continue
                }
                if type == .video {
                    if videoTransforms[file] == nil { videoTransforms[file] = try await src.load(.preferredTransform) }
                    if dst.trackID == vTrackID, !d.seconds.isFinite || sh.fileStart + sh.duration > d.seconds + 0.05 {
                        throw RenderError.failed("clip \(sh.clip.name) extends beyond its video file; re-import or trim the shot")
                    }
                }
                let start = ct(sh.fileStart)
                var dur = ct(sh.duration)
                if CMTimeCompare(CMTimeAdd(start, dur), d) > 0 { dur = CMTimeSubtract(d, start) }
                guard dur.seconds > 0.001 else { continue }
                let at = ct(sh.outStart)
                let end = dst.timeRange.end
                if dst.segments.isEmpty, at.seconds > 0.0005 { dst.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: at)) }
                else if !dst.segments.isEmpty, CMTimeCompare(at, end) > 0 { dst.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                let insertAt = dst.segments.isEmpty ? at : CMTimeMaximum(at, dst.timeRange.end)
                try dst.insertTimeRange(CMTimeRange(start: start, duration: dur), of: src, at: insertAt)
                if abs(sh.rate - 1) > 1e-6 { dst.scaleTimeRange(CMTimeRange(start: insertAt, duration: dur), toDuration: ct(dur.seconds / sh.rate)) }
                placed = true
            }
            return placed
        }

        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.failed("can't add video track") }
        vTrackID = vTrack.trackID
        let primaryURL = bundle.resolve(document.media.screen)
        if layout.segments.contains(where: { $0.clip.primary }), !FileManager.default.fileExists(atPath: primaryURL.path) { throw RenderError.missingMedia(primaryURL.path) }
        for c in Set(layout.segments.map(\.clip.path)) where !FileManager.default.fileExists(atPath: bundle.resolve(c).path) { throw RenderError.missingMedia(bundle.resolve(c).path) }
        guard try await place(vTrack, type: .video, path: { $0.path }, include: { _ in true }) else {
            throw RenderError.missingMedia("no video track in \(layout.segments.map { ($0.clip.path as NSString).lastPathComponent }.joined(separator: ", "))")
        }
        let videoEnd = vTrack.timeRange.end

        // Facecam: the camera movie shares the recording's clock, so it takes the primary shots' cuts and speeds.
        var cameraTrackID: CMPersistentTrackID?
        if document.style.facecam.visible, let camPath = document.media.camera,
           let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            if try await place(t, type: .video, path: { _ in camPath }, include: { $0.primary }) {
                if CMTimeCompare(t.timeRange.end, videoEnd) > 0 { t.removeTimeRange(CMTimeRange(start: videoEnd, end: t.timeRange.end)) }
                cameraTrackID = t.trackID
                plan.hasFacecam = true
            } else { comp.removeTrack(t) }
        }

        var params: [AVMutableAudioMixInputParameters] = []
        var duckable: [AVMutableAudioMixInputParameters] = []
        let audio = document.style.audio
        func audioTrack(_ build: (AVMutableCompositionTrack) async throws -> Bool) async throws -> AVMutableCompositionTrack? {
            guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            if try await build(t) {
                if CMTimeCompare(t.timeRange.end, videoEnd) > 0 { t.removeTimeRange(CMTimeRange(start: videoEnd, end: t.timeRange.end)) }
                return t
            }
            comp.removeTrack(t); return nil
        }
        // The recording's microphone and system audio (primary shots).
        for (path, gain, muted) in [(document.media.microphone, audio.microphoneGain, audio.muteMicrophone), (document.media.systemAudio, audio.systemGain, audio.muteSystem)] {
            guard let path, !muted else { continue }
            guard let t = try await audioTrack({ try await place($0, type: .audio, path: { _ in path }, include: { $0.primary }) }) else { continue }
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(gain * (loudnessGain[path] ?? 1)), at: .zero)
            params.append(p); duckable.append(p)
        }
        // Imported shots' own audio: one track per clip and file, at the clip's gain.
        if !audio.muteSystem {
            for seg in layout.segments where !seg.clip.primary {
                for path in seg.clip.audio {
                    let id = seg.clip.id
                    guard let t = try await audioTrack({ try await place($0, type: .audio, path: { _ in path }, include: { $0.id == id }) }) else { continue }
                    let p = AVMutableAudioMixInputParameters(track: t)
                    p.setVolume(Float(seg.clip.gain * audio.systemGain * (loudnessGain["clips"] ?? 1)), at: .zero)
                    params.append(p); duckable.append(p)
                }
            }
        }
        // Voiceover clips: anchored to a source instant, played at 1× from that instant's output time.
        var voiceRanges: [CMTimeRange] = []
        if !audio.muteVoiceover {
            for clip in document.timeline.voiceover.sorted(by: { $0.start < $1.start }) {
                guard let (a, d) = await asset(clip.path), let src = try? await a.loadTracks(withMediaType: .audio).first,
                      let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let at = ct(plan.map.outputClamped(forSource: clip.start))
                let dur = CMTimeMinimum(d, CMTimeSubtract(videoEnd, at))
                guard dur.seconds > 0.05 else { comp.removeTrack(t); continue }
                try t.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: at)
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(Float(clip.gain * audio.voiceoverGain * (loudnessGain["voiceover"] ?? 1)), at: .zero)
                params.append(p)
                voiceRanges.append(CMTimeRange(start: at, duration: dur))
            }
        }
        // Audio clips: imported voice, music beds and effects.
        struct Pending { var clip: AudioClip; var track: AVMutableCompositionTrack; var span: TimeRange }
        var pending: [Pending] = []
        for clip in document.timeline.audio {
            if clip.kind == .music && audio.muteMusic { continue }
            if clip.kind == .voice && audio.muteVoiceover { continue }
            guard let (a, _) = await asset(clip.path), let src = try? await a.loadTracks(withMediaType: .audio).first,
                  let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let at = plan.map.outputClamped(forSource: clip.start)
            var first: Double?, last = at
            for span in clip.playSpans(outputStart: at, videoEnd: videoEnd.seconds) {
                let start = CMTimeMaximum(t.timeRange.end, ct(span.output.start))
                if CMTimeCompare(start, t.timeRange.end) > 0 { t.insertEmptyTimeRange(CMTimeRange(start: t.timeRange.end, end: start)) }
                try t.insertTimeRange(CMTimeRange(start: ct(span.fileStart), duration: ct(span.output.duration)), of: src, at: start)
                first = first ?? span.output.start; last = span.output.end
            }
            guard let f = first else { comp.removeTrack(t); continue }
            if clip.kind == .voice { voiceRanges.append(CMTimeRange(start: ct(f), end: ct(last))) }
            pending.append(Pending(clip: clip, track: t, span: TimeRange(f, last)))
        }
        let voice = voiceRanges.map { TimeRange($0.start.seconds, $0.end.seconds) }
        for pd in pending {
            let p = AVMutableAudioMixInputParameters(track: pd.track)
            var base = pd.clip.gain
            switch pd.clip.kind {
            case .music: base *= audio.musicGain
            case .voice: base *= audio.voiceoverGain * (loudnessGain["voiceover"] ?? 1)
            case .effect: break
            }
            let duck = pd.clip.duckUnderVoice ? voice.filter { r in !(pd.clip.kind == .voice && abs(r.start - pd.span.start) < 1e-3) } : []
            let keys = AudioEnvelope.keys(span: pd.span, base: base, fadeIn: pd.clip.fadeIn, fadeOut: pd.clip.fadeOut, duck: duck,
                                          duckLevel: max(0, min(1, pd.clip.kind == .music ? audio.musicDuckLevel : audio.duckLevel)))
            apply(keys, to: p, timescale: ts)
            params.append(p)
        }
        // Duck the recorded tracks under narration.
        if audio.duckUnderVoiceover, !voiceRanges.isEmpty {
            for p in duckable { duck(p, under: voiceRanges, level: Float(max(0, min(1, audio.duckLevel))), timescale: ts) }
        }
        var mix: AVMutableAudioMix?
        if !params.isEmpty { let m = AVMutableAudioMix(); m.inputParameters = params; mix = m }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = GlintCompositor.self
        vc.renderSize = CGSize(width: plan.width, height: plan.height)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let range = CMTimeRange(start: .zero, duration: videoEnd)
        vc.instructions = [GlintInstruction(timeRange: range, trackID: vTrack.trackID, cameraTrackID: cameraTrackID, plan: plan, frameDuration: 1 / fps,
                                            screenTransforms: videoTransforms, cameraTransform: document.media.camera.flatMap { videoTransforms[$0] } ?? .identity)]
        // Audio may not run past the picture.
        for t in comp.tracks(withMediaType: .audio) where CMTimeCompare(t.timeRange.end, videoEnd) > 0 {
            t.removeTimeRange(CMTimeRange(start: videoEnd, end: t.timeRange.end))
        }
        return EditComposition(asset: comp, videoComposition: vc, audioMix: mix, plan: plan)
    }

    /// Piecewise-linear gain keys → volume ramps.
    static func apply(_ keys: [AudioEnvelope.Key], to p: AVMutableAudioMixInputParameters, timescale: CMTimeScale) {
        guard let f = keys.first else { return }
        p.setVolume(Float(f.gain), at: .zero)
        for (a, b) in zip(keys, keys.dropFirst()) where b.t - a.t > 1e-4 {
            p.setVolumeRamp(fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain),
                            timeRange: CMTimeRange(start: CMTime(seconds: a.t, preferredTimescale: timescale), end: CMTime(seconds: b.t, preferredTimescale: timescale)))
        }
    }

    /// Volume ramps so a track sits under voiceover: fade down 0.25 s before each clip, back up 0.35 s after.
    static func duck(_ p: AVMutableAudioMixInputParameters, under ranges: [CMTimeRange], level: Float, timescale: CMTimeScale) {
        var base: Float = 1
        var ramp: Float = 1
        p.getVolumeRamp(for: .zero, startVolume: &base, endVolume: &ramp, timeRange: nil)
        let down = CMTime(seconds: 0.25, preferredTimescale: timescale), up = CMTime(seconds: 0.35, preferredTimescale: timescale)
        // Merge overlapping / touching clip ranges so ramps never cross.
        var merged: [CMTimeRange] = []
        for r in ranges.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 }) {
            if let last = merged.last, CMTimeCompare(r.start, CMTimeAdd(last.end, CMTimeAdd(up, down))) <= 0 {
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, r.end))
            } else { merged.append(r) }
        }
        let low = base * level
        for r in merged {
            let fadeStart = CMTimeMaximum(.zero, CMTimeSubtract(r.start, down))
            p.setVolumeRamp(fromStartVolume: base, toEndVolume: low, timeRange: CMTimeRange(start: fadeStart, end: r.start))
            p.setVolume(low, at: r.start)
            p.setVolumeRamp(fromStartVolume: low, toEndVolume: base, timeRange: CMTimeRange(start: r.end, duration: up))
        }
    }

    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}
