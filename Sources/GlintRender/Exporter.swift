import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GlintCore
import AppKit
import CoreText

/// A deliverable: size, aspect, codec and optional style overrides (applied in memory, not saved to the project).
public struct RenderVariant: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Sendable { case mp4, mov, gif }
    public enum Codec: String, Codable, Sendable { case h264, hevc, prores }
    public var name: String
    public var format: Format = .mp4
    public var codec: Codec = .h264
    public var aspect: Aspect?
    /// Short side in pixels (1080 → 1920×1080 landscape, 1080×1920 portrait).
    public var size: Int = 1080
    public var fps: Double?
    /// Bits per pixel per frame for H.264/HEVC.
    public var quality: Double = 0.09
    public var style: [EditOperation] = []
    public init(name: String, format: Format = .mp4, codec: Codec = .h264, aspect: Aspect? = nil, size: Int = 1080, fps: Double? = nil, style: [EditOperation] = []) {
        self.name = name; self.format = format; self.codec = codec; self.aspect = aspect; self.size = size; self.fps = fps; self.style = style
    }

    public static let presets: [String: RenderVariant] = [
        "landscape": RenderVariant(name: "landscape", aspect: .landscape, size: 1080),
        "landscape-4k": RenderVariant(name: "landscape-4k", codec: .hevc, aspect: .landscape, size: 2160),
        "square": RenderVariant(name: "square", aspect: .square, size: 1080,
                                style: [.style("canvas.baseScale", .number(1.35)), .style("frame.padding", .number(0.05))]),
        "portrait": RenderVariant(name: "portrait", aspect: .portrait, size: 1080,
                                  style: [.style("canvas.baseScale", .number(1.75)), .style("frame.padding", .number(0.04)), .style("captions.size", .number(0.03))]),
        "gif": RenderVariant(name: "gif", format: .gif, aspect: .landscape, size: 540, fps: 15),
        "prores": RenderVariant(name: "prores", format: .mov, codec: .prores, aspect: .landscape, size: 1080),
        "preview": RenderVariant(name: "preview", aspect: nil, size: 720, fps: 30),
    ]
    public static func preset(_ name: String) -> RenderVariant? { presets[name] }
}

public enum Exporter {
    /// Render a document (optionally with variant style overrides) to a file. Progress is 0…1.
    public static func export(bundle: ProjectBundle, document: ProjectDocument, variant: RenderVariant, to url: URL,
                              progress: (@Sendable (Double) -> Void)? = nil, shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> URL {
        var doc = try OperationApplier.apply(variant.style, to: document)
        if let a = variant.aspect { doc.style.canvas.aspect = a }
        let (w, h) = RenderPlan.outputSize(document: doc, height: variant.size)
        let fps = variant.fps ?? min(60, max(24, doc.media.frameRate))
        let gains = await Loudness.normalizationGains(bundle: bundle, document: doc)
        let comp = try await EditComposition.build(bundle: bundle, document: doc, width: w, height: h, frameRate: fps, loudnessGain: gains)
        comp.plan.motionSamples = 12
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        if variant.format == .gif {
            do { try await gif(comp, to: url, fps: fps, progress: progress, shouldCancel: shouldCancel) } catch { try? FileManager.default.removeItem(at: url); throw error }
            return url
        }
        do { try await movie(comp, variant: variant, fps: fps, to: url, progress: progress, shouldCancel: shouldCancel) } catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }

    static func movie(_ comp: EditComposition, variant: RenderVariant, fps: Double, to url: URL, progress: (@Sendable (Double) -> Void)?,
                      shouldCancel: (@Sendable () -> Bool)? = nil) async throws {
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        let reader = try AVAssetReader(asset: comp.asset)
        let vTracks = try await comp.asset.loadTracks(withMediaType: .video)
        let aTracks = try await comp.asset.loadTracks(withMediaType: .audio)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = comp.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                                                                     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            o.audioMix = comp.audioMix
            o.audioTimePitchAlgorithm = .spectral
            reader.add(o); aOut = o
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: variant.format == .mov ? .mov : .mp4)
        let w = comp.plan.width, h = comp.plan.height
        var vSettings: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h,
                                        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        switch variant.codec {
        case .prores:
            vSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .h264, .hevc:
            vSettings[AVVideoCodecKey] = variant.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            var props: [String: Any] = [AVVideoAverageBitRateKey: Double(w * h) * fps * variant.quality * (variant.codec == .hevc ? 0.7 : 1),
                                        AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2]
            if variant.codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            vSettings[AVVideoCompressionPropertiesKey] = props
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            a.expectsMediaDataInRealTime = false
            writer.add(a); aIn = a
        }
        guard reader.startReading() else { throw RenderError.failed(reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw RenderError.failed(writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)
        let total = max(0.001, comp.duration)

        final class Box: @unchecked Sendable { var cont: CheckedContinuation<Void, Never>? }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let q = DispatchQueue(label: "glint.export.video")
                    vIn.requestMediaDataWhenReady(on: q) {
                        while vIn.isReadyForMoreMediaData {
                            if shouldCancel?() == true { flag.cancelled = true; reader.cancelReading(); vIn.markAsFinished(); c.resume(); return }
                            guard reader.status == .reading, let sb = vOut.copyNextSampleBuffer() else {
                                vIn.markAsFinished(); c.resume(); return
                            }
                            progress?(min(1, sb.presentationTimeStamp.seconds / total))
                            if !vIn.append(sb) { vIn.markAsFinished(); c.resume(); return }
                        }
                    }
                }
            }
            if let aIn, let aOut {
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let q = DispatchQueue(label: "glint.export.audio")
                        aIn.requestMediaDataWhenReady(on: q) {
                            while aIn.isReadyForMoreMediaData {
                                guard reader.status == .reading, let sb = aOut.copyNextSampleBuffer() else {
                                    aIn.markAsFinished(); c.resume(); return
                                }
                                if !aIn.append(sb) { aIn.markAsFinished(); c.resume(); return }
                            }
                        }
                    }
                }
            }
        }
        if flag.cancelled || shouldCancel?() == true { writer.cancelWriting(); throw RenderError.cancelled }
        if reader.status == .failed { writer.cancelWriting(); throw RenderError.failed(reader.error?.localizedDescription ?? "reading failed") }
        await writer.finishWriting()
        if writer.status != .completed { throw RenderError.failed(writer.error?.localizedDescription ?? "writing failed") }
        progress?(1)
    }

    static func gif(_ comp: EditComposition, to url: URL, fps: Double, progress: (@Sendable (Double) -> Void)?, shouldCancel: (@Sendable () -> Bool)? = nil) async throws {
        // GIF delays are stored in hundredths of a second: step frames by a whole number of centiseconds so the
        // file's duration matches the edit exactly (1/15 s would round to 0.07 s and drift).
        let delay = max(0.02, (100 / fps).rounded() / 100)
        let times = stride(from: 0.0, to: comp.duration - 0.001, by: delay).map { $0 }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else { throw RenderError.failed("can't create GIF") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        var i = 0
        for try await img in Frames.images(comp, at: times) {
            if shouldCancel?() == true { throw RenderError.cancelled }
            CGImageDestinationAddImage(dest, img, frameProps)
            i += 1
            progress?(Double(i) / Double(times.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw RenderError.failed("GIF finalize failed") }
    }
}

/// Frame access for inspection: single frames, contact sheets.
public enum Frames {
    static func generator(_ comp: EditComposition) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: comp.asset)
        g.videoComposition = comp.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.appliesPreferredTrackTransform = true
        return g
    }

    public static func image(_ comp: EditComposition, at t: Double) async throws -> CGImage {
        let g = generator(comp)
        let time = CMTime(seconds: min(max(0, t), max(0, comp.duration - 0.02)), preferredTimescale: 60000)
        return try await g.image(at: time).image
    }

    static func images(_ comp: EditComposition, at times: [Double]) -> AsyncThrowingStream<CGImage, Error> {
        let g = generator(comp)
        let cm = times.map { NSValue(time: CMTime(seconds: min($0, max(0, comp.duration - 0.02)), preferredTimescale: 60000)) }
        return AsyncThrowingStream { cont in
            let total = cm.count
            var done = 0
            var buffer: [Int: CGImage] = [:]
            var next = 0
            let lock = NSLock()
            g.generateCGImagesAsynchronously(forTimes: cm) { requested, image, _, result, error in
                lock.lock(); defer { lock.unlock() }
                let idx = cm.firstIndex(of: NSValue(time: requested)) ?? done
                if let image { buffer[idx] = image }
                done += 1
                while let img = buffer[next] { cont.yield(img); buffer[next] = nil; next += 1 }
                if result == .failed, let error { cont.finish(throwing: error); return }
                if done == total { cont.finish() }
            }
        }
    }

    public static func writePNG(_ img: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.failed("png") }
        CGImageDestinationAddImage(d, img, nil)
        guard CGImageDestinationFinalize(d) else { throw RenderError.failed("png write") }
    }

    public static func writeJPEG(_ img: CGImage, to url: URL, quality: Double = 0.85) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw RenderError.failed("jpeg") }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw RenderError.failed("jpeg write") }
    }

    /// Grid of frames with timestamps — lets an agent "watch" a cut at a glance.
    public static func contactSheet(images: [(Double, CGImage)], columns: Int = 4, cellWidth: Int = 480) -> CGImage? {
        guard let first = images.first?.1 else { return nil }
        let aspect = Double(first.height) / Double(first.width)
        let cellH = Int(Double(cellWidth) * aspect)
        let rows = (images.count + columns - 1) / columns
        let gap = 8, label = 28
        let W = columns * cellWidth + (columns + 1) * gap
        let H = rows * (cellH + label) + (rows + 1) * gap
        return Artwork.bitmap(W, H) { ctx in
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for (i, (t, img)) in images.enumerated() {
                let col = i % columns, row = i / columns
                let x = gap + col * (cellWidth + gap)
                let yTop = gap + row * (cellH + label + gap)
                let y = H - yTop - cellH
                ctx.draw(img, in: CGRect(x: x, y: y, width: cellWidth, height: cellH))
                let text = String(format: "%d  ·  %.2fs", i + 1, t)
                let attr = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: x + 4, y: y - 21)
                CTLineDraw(line, ctx)
            }
        }
    }
}


/// Loudness normalization for export: measure the primary voice track (BS.1770) and compute a gain that reaches
/// `style.audio.targetLUFS`, capped so source peaks stay below -3 dBFS. Other tracks keep their relative level.
public enum Loudness {
    public static func normalizationGains(bundle: ProjectBundle, document: ProjectDocument) async -> [String: Double] {
        guard document.style.audio.normalizeLoudness else { return [:] }
        let target = document.style.audio.targetLUFS
        var out: [String: Double] = [:]
        let primary = document.style.audio.muteMicrophone ? document.media.systemAudio : (document.media.microphone ?? document.media.systemAudio)
        if let path = primary, let g = await gain(toReach: target, files: [bundle.resolve(path)]) {
            // Apply the same gain to every recorded track so the mix balance the user set is preserved.
            for p in [document.media.microphone, document.media.systemAudio].compactMap({ $0 }) { out[p] = g }
        }
        // The narration track is measured on its own (all clips together) and brought to the same target.
        // Imported voice clips count as narration.
        let clips = (document.timeline.voiceover.map(\.path) + document.timeline.audio.filter { $0.kind == .voice }.map(\.path))
            .map { bundle.resolve($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !clips.isEmpty, !document.style.audio.muteVoiceover, let g = await gain(toReach: target, files: clips) { out["voiceover"] = g }
        // Imported shots' own audio is measured together and brought to the same target.
        let shotAudio = Array(Set(document.timeline.clips.filter { !$0.primary }.flatMap(\.audio))).sorted()
            .map { bundle.resolve($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !shotAudio.isEmpty, let g = await gain(toReach: target, files: shotAudio) { out["clips"] = g }
        return out
    }

    /// Gain that brings the concatenated files to `target` LUFS, capped so peaks stay under -3 dBFS.
    static func gain(toReach target: Double, files: [URL]) async -> Double? {
        var samples: [Float] = []
        var mono = false
        for url in files {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let x = try? decode(asset: asset, track: track) else { continue }
            let channels = (try? await track.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }) ?? 2
            if channels == 1 { mono = true }
            samples += x
        }
        guard !samples.isEmpty, var measured = integratedLUFS(samples, sampleRate: 48000) else { return nil }
        // A mono track is played on both channels of the stereo output, which BS.1770 measures as +3 dB.
        if mono { measured += 3.01 }
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        let wanted = pow(10, (target - measured) / 20)
        // 3 dB headroom: AAC encoding and pitch-preserving time-stretch can overshoot source peaks by ~2 dB.
        let peakCap = peak > 0 ? pow(10, -3.0 / 20) / Double(peak) : wanted
        return max(0.25, min(8, min(wanted, peakCap)))
    }

    static func decode(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                                                          AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var x: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
            x.append(contentsOf: chunk)
        }
        return x
    }

    /// BS.1770 integrated loudness (same algorithm as GlintAnalysis, kept here so rendering has no analysis dependency).
    static func integratedLUFS(_ x: [Float], sampleRate fs: Double) -> Double? {
        guard x.count > Int(fs * 0.4) else { return nil }
        func biquad(_ input: [Float], _ b: [Double], _ a: [Double]) -> [Float] {
            var y = [Float](repeating: 0, count: input.count); var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<input.count { let x0 = Double(input[i]); let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2; x2 = x1; x1 = x0; y2 = y1; y1 = y0; y[i] = Float(y0) }
            return y
        }
        var K = tan(.pi * 1681.974450955533 / fs); var Q = 0.7071752369554196
        let Vh = pow(10, 3.999843853973347 / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let y1 = biquad(x, [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0], [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
        K = tan(.pi * 38.13547087602444 / fs); Q = 0.5003270373238773; a0 = 1 + K / Q + K * K
        let y = biquad(y1, [1, -2, 1], [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
        let block = Int(fs * 0.4), hop = Int(fs * 0.1)
        var e: [Double] = []; var i = 0
        while i + block <= y.count { var s = 0.0; for j in i..<(i + block) { s += Double(y[j] * y[j]) }; e.append(s / Double(block)); i += hop }
        func l(_ v: Double) -> Double { -0.691 + 10 * log10(max(1e-12, v)) }
        let abs = e.filter { l($0) > -70 }; guard !abs.isEmpty else { return nil }
        let rel = l(abs.reduce(0, +) / Double(abs.count)) - 10
        let g = abs.filter { l($0) > rel }; guard !g.isEmpty else { return nil }
        return l(g.reduce(0, +) / Double(g.count))
    }
}
