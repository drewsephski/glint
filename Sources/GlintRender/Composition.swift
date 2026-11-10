import Foundation
import AVFoundation
import CoreImage
import Metal
import GlintCore

public enum RenderError: Error, CustomStringConvertible {
    case missingMedia(String)
    case failed(String)
    public var description: String {
        switch self {
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
    let frameDuration: Double
    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, plan: RenderPlan, frameDuration: Double) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.plan = plan
        self.frameDuration = frameDuration
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
            let screen = request.sourceFrame(byTrackID: inst.trackID).map { CIImage(cvPixelBuffer: $0) }
            let image = SceneRenderer.render(plan: inst.plan, screen: screen, outputTime: request.compositionTime.seconds, frameDuration: inst.frameDuration)
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
        let (dw, dh) = RenderPlan.outputSize(document: document)
        let plan = RenderPlan(document: document, events: events ?? bundle.readEvents(), bundle: bundle, width: width ?? dw, height: height ?? dh)
        let fps = frameRate ?? min(60, max(24, document.media.frameRate))
        let comp = AVMutableComposition()
        let screenURL = bundle.resolve(document.media.screen)
        guard FileManager.default.fileExists(atPath: screenURL.path) else { throw RenderError.missingMedia(screenURL.path) }
        let screenAsset = AVURLAsset(url: screenURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let srcVideo = try await screenAsset.loadTracks(withMediaType: .video).first else { throw RenderError.missingMedia("no video track in \(screenURL.lastPathComponent)") }
        let srcDuration = try await screenAsset.load(.duration)
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.failed("can't add video track") }

        let ts: CMTimeScale = 60000
        func ct(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }

        func insert(_ src: AVAssetTrack, into dst: AVMutableCompositionTrack, sourceDuration: CMTime) throws {
            var cursor = CMTime.zero
            for p in plan.map.pieces {
                let start = ct(p.source.start)
                var dur = ct(p.source.duration)
                // Clamp to the media actually present.
                if CMTimeCompare(CMTimeAdd(start, dur), sourceDuration) > 0 { dur = CMTimeSubtract(sourceDuration, start) }
                guard dur.seconds > 0.001 else { continue }
                try dst.insertTimeRange(CMTimeRange(start: start, duration: dur), of: src, at: cursor)
                let outDur = ct(dur.seconds / p.rate)
                if abs(p.rate - 1) > 1e-6 { dst.scaleTimeRange(CMTimeRange(start: cursor, duration: dur), toDuration: outDur) }
                cursor = CMTimeAdd(cursor, outDur)
            }
        }
        try insert(srcVideo, into: vTrack, sourceDuration: srcDuration)

        var params: [AVMutableAudioMixInputParameters] = []
        let audio = document.style.audio
        for (path, gain, muted) in [(document.media.microphone, audio.microphoneGain, audio.muteMicrophone), (document.media.systemAudio, audio.systemGain, audio.muteSystem)] {
            guard let path, !muted else { continue }
            let url = bundle.resolve(path)
            let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let src = try? await a.loadTracks(withMediaType: .audio).first,
                  let d = try? await a.load(.duration),
                  let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try insert(src, into: t, sourceDuration: d)
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(gain * (loudnessGain[path] ?? 1)), at: .zero)
            params.append(p)
        }
        // Voiceover clips: anchored to a source instant, played at 1× from that instant's output time.
        var voiceRanges: [CMTimeRange] = []
        if !audio.muteVoiceover {
            let videoEnd = comp.duration
            for clip in document.timeline.voiceover.sorted(by: { $0.start < $1.start }) {
                let url = bundle.resolve(clip.path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let src = try? await a.loadTracks(withMediaType: .audio).first, let d = try? await a.load(.duration),
                      let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let at = ct(plan.map.outputClamped(forSource: clip.start))
                let avail = CMTimeSubtract(videoEnd, at)
                let dur = CMTimeMinimum(d, avail)
                guard dur.seconds > 0.05 else { continue }
                try t.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: at)
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(Float(clip.gain * audio.voiceoverGain * (loudnessGain["voiceover"] ?? 1)), at: .zero)
                params.append(p)
                voiceRanges.append(CMTimeRange(start: at, duration: dur))
            }
        }
        // Duck the recorded tracks under narration.
        if audio.duckUnderVoiceover, !voiceRanges.isEmpty {
            for p in params.prefix(params.count - voiceRanges.count) {
                duck(p, under: voiceRanges, level: Float(max(0, min(1, audio.duckLevel))), timescale: ts)
            }
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
        let range = CMTimeRange(start: .zero, duration: comp.duration)
        vc.instructions = [GlintInstruction(timeRange: range, trackID: vTrack.trackID, plan: plan, frameDuration: 1 / fps)]
        return EditComposition(asset: comp, videoComposition: vc, audioMix: mix, plan: plan)
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
