import Foundation
import AVFoundation
import CoreImage
import Accelerate
import ImageIO
import GlintCore
import GlintRender

/// Measures a rendered file: container facts, decoded-frame statistics and audio loudness, with verdicts.
public struct RenderReport: Codable, Hashable, Sendable {
    public var path: String
    public var fileBytes: Int
    public var duration: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: String
    public var bitrate: Double
    public var hasAudio: Bool
    public var audio: AudioStats?
    public var sampledFrames: Int
    public var blackFrames: [Double]
    public var frozenRanges: [TimeRange]
    /// Mean absolute luma change between consecutive samples (0…1) — how much is moving over time.
    public var motion: [Double]
    public var sharpness: Double
    public var quality: QualityReport
}

public enum RenderInspector {
    /// `expectedSpeech`: output-time intervals where the edit places narration (`MediaPreflight.expectedSpeech`). Each
    /// must carry sound in the file; a render whose narration was dropped fails `narration_present` even when music or
    /// the recording's audio keeps the track as a whole from being silent elsewhere.
    public static func inspect(url: URL, expectedDuration: Double? = nil, expectedSize: (Int, Int)? = nil, expectedSpeech: [TimeRange] = [],
                               sampleRate: Double = 4) async throws -> RenderReport {
        if url.pathExtension.lowercased() == "gif" { return try inspectGIF(url: url, expectedDuration: expectedDuration, expectedSize: expectedSize) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let vt = try await asset.loadTracks(withMediaType: .video).first
        let at = try await asset.loadTracks(withMediaType: .audio).first
        var width = 0, height = 0, fps = 0.0, codec = "gif"
        if let vt {
            let size = try await vt.load(.naturalSize)
            width = Int(size.width); height = Int(size.height)
            fps = Double(try await vt.load(.nominalFrameRate))
            if let desc = try await vt.load(.formatDescriptions).first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                codec = String(bytes: [UInt8(sub >> 24 & 0xff), UInt8(sub >> 16 & 0xff), UInt8(sub >> 8 & 0xff), UInt8(sub & 0xff)], encoding: .ascii) ?? "?"
            }
        }
        // Frames.
        var lumas: [Double] = [], motion: [Double] = [], sharp: [Double] = []
        var blacks: [Double] = [], frozen: [TimeRange] = []
        var prev: [Float]?
        var frozenStart: Double?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 320, height: 320)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let times = stride(from: 0.0, to: max(0.01, duration - 0.05), by: 1 / sampleRate).map { $0 }
        var sampled = 0
        for t in times {
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, let g = gray(img) else { continue }
            sampled += 1
            let mean = Double(g.pixels.reduce(0, +)) / Double(g.pixels.count)
            let variance = g.pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(g.pixels.count)
            lumas.append(mean)
            // Black = dark AND featureless (dark-mode UIs are dark but full of detail).
            if mean < 0.04 && variance.squareRoot() < 0.012 { blacks.append(t) }
            sharp.append(laplacianVariance(g))
            if let p = prev, p.count == g.pixels.count {
                var d = [Float](repeating: 0, count: p.count)
                vDSP_vsub(p, 1, g.pixels, 1, &d, 1, vDSP_Length(p.count))
                var m: Float = 0
                vDSP_meamgv(d, 1, &m, vDSP_Length(d.count))
                motion.append(Double(m))
                if m < 0.0008 { if frozenStart == nil { frozenStart = t - 1 / sampleRate } }
                else if let s = frozenStart { if t - s >= 2 { frozen.append(TimeRange(s, t)) }; frozenStart = nil }
            }
            prev = g.pixels
        }
        if let s = frozenStart, duration - s >= 2 { frozen.append(TimeRange(s, duration)) }
        // Audio.
        var audio: AudioStats?
        var silentSpeech: [TimeRange] = []
        if let at {
            // Per-channel decode: true sample peaks and BS.1770 channel summation (a mono downmix would misstate both).
            let channels = try AudioAnalysis.decodeChannels(asset: asset, track: at)
            audio = AudioAnalysis.stats(channels: channels, sampleRate: 48000)
            silentSpeech = silentWindows(channels, sampleRate: 48000, in: expectedSpeech)
        } else {
            silentSpeech = expectedSpeech
        }
        let bitrate = duration > 0 ? Double(bytes * 8) / duration : 0
        let sharpness = sharp.isEmpty ? 0 : sharp.sorted()[sharp.count / 2]

        // Verdicts.
        var checks: [QualityCheck] = []
        if let e = expectedDuration {
            let ok = abs(duration - e) <= max(0.1, 2 / max(1, fps))
            checks.append(QualityCheck("duration_matches_edit", ok ? .pass : .fail, value: duration, threshold: String(format: "%.2fs", e),
                                       String(format: "Rendered %.2fs vs edit %.2fs", duration, e)))
        }
        if let (ew, eh) = expectedSize {
            checks.append(QualityCheck("resolution", width == ew && height == eh ? .pass : .fail, threshold: "\(ew)×\(eh)", "Rendered \(width)×\(height)"))
        }
        let blackFrac = sampled > 0 ? Double(blacks.count) / Double(sampled) : 0
        checks.append(QualityCheck("black_frames", blackFrac < 0.02 ? .pass : .fail, value: blackFrac, threshold: "< 2%",
                                   String(format: "%.1f%% black frames", blackFrac * 100), fix: blackFrac >= 0.02 ? "check media paths / cuts at the start" : nil))
        let frozenTotal = frozen.reduce(0) { $0 + $1.duration }
        checks.append(QualityCheck("frozen_video", frozenTotal < 3 ? .pass : .warn, value: frozenTotal, threshold: "< 3s",
                                   String(format: "%.1fs of unchanged picture", frozenTotal), fix: frozenTotal >= 3 ? "speed up or cut the static stretches" : nil))
        checks.append(QualityCheck("sharpness", sharpness > 0.002 ? .pass : .warn, value: sharpness, threshold: "> 0.002",
                                   String(format: "Median sharpness %.4f", sharpness), fix: sharpness <= 0.002 ? "raise quality or output size; avoid zoom > 2.5 on low-res sources" : nil))
        if vt != nil && codec != "gif" {
            let bpp = bitrate / max(1, Double(width * height) * max(1, fps))
            // Encoders spend few bits on static UI, so a low average isn't a defect by itself; only starved streams warn.
            checks.append(QualityCheck("bitrate", bpp >= 0.004 ? .info : .warn, value: bitrate, threshold: "≥ 0.004 bits/pixel/frame",
                                       String(format: "%.1f Mbit/s (%.3f bpp)", bitrate / 1e6, bpp), fix: bpp < 0.004 ? "raise the variant quality" : nil))
        }
        if let a = audio {
            if let l = a.integratedLUFS {
                checks.append(QualityCheck("loudness", (-20 ... -12).contains(l) ? .pass : (-26 ... -9).contains(l) ? .warn : .fail, value: l, threshold: "-16 LUFS ±4",
                                           String(format: "Integrated loudness %.1f LUFS", l), fix: (-20 ... -12).contains(l) ? nil : "adjust style.audio gains"))
            } else {
                checks.append(QualityCheck("loudness", .info, "Audio track is silent"))
            }
            let over = a.peakDBFS > -0.1 || a.clippedFraction >= 0.0005
            checks.append(QualityCheck("clipping", over ? .warn : .pass, value: a.peakDBFS, threshold: "peak ≤ -0.1 dBFS",
                                       String(format: "Peak %.1f dBFS, %.3f%% samples at full scale", a.peakDBFS, a.clippedFraction * 100),
                                       fix: over ? "lower style.audio gains or targetLUFS" : nil))
        }
        if !expectedSpeech.isEmpty {
            let ok = silentSpeech.isEmpty
            let where_ = silentSpeech.prefix(3).map { String(format: "%.1f–%.1fs", $0.start, $0.end) }.joined(separator: ", ")
            checks.append(QualityCheck("narration_present", ok ? .pass : .fail, value: Double(silentSpeech.count), threshold: "\(expectedSpeech.count) narrated interval(s) audible",
                                       ok ? "Narration is audible in all \(expectedSpeech.count) interval(s)" : "Narration is silent at \(where_)\(silentSpeech.count > 3 ? " and \(silentSpeech.count - 3) more" : "")",
                                       fix: ok ? nil : "regenerate or locate the missing voiceover files, then render again"))
        }
        let q = QualityReport(checks: checks, metrics: ["duration": duration, "bitrate": bitrate, "sharpness": sharpness, "mean_motion": motion.isEmpty ? 0 : motion.reduce(0, +) / Double(motion.count)])
        return RenderReport(path: url.path, fileBytes: bytes, duration: duration, width: width, height: height, frameRate: fps, codec: codec,
                            bitrate: bitrate, hasAudio: at != nil, audio: audio, sampledFrames: sampled, blackFrames: blacks, frozenRanges: frozen,
                            motion: motion.map { ($0 * 10000).rounded() / 10000 }, sharpness: sharpness, quality: q)
    }

    /// Expected-speech intervals whose audio stays near digital silence (RMS below -50 dBFS over every 200 ms window
    /// inside the interval, ignoring 150 ms at each edge for fades and ducking ramps).
    static func silentWindows(_ channels: [[Float]], sampleRate fs: Double, in ranges: [TimeRange]) -> [TimeRange] {
        guard let n = channels.first?.count, n > 0 else { return ranges }
        let floor = Float(pow(10, -50.0 / 20))
        return ranges.filter { r in
            let a = max(0, Int((r.start + 0.15) * fs)), b = min(n, Int((r.end - 0.15) * fs))
            guard b - a > Int(0.1 * fs) else { return a >= n }
            let win = Int(0.2 * fs)
            var i = a
            while i < b {
                let j = min(b, i + win)
                var sum: Float = 0
                for c in channels { var ms: Float = 0; c.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(j - i)) }; sum += ms }
                if (sum / Float(channels.count)).squareRoot() >= floor { return false }
                i = j
            }
            return true
        }
    }

    /// GIFs aren't AVFoundation media: read frames and delays with ImageIO.
    static func inspectGIF(url: URL, expectedDuration: Double?, expectedSize: (Int, Int)?) throws -> RenderReport {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw RenderAnalysisError.failed("can't read GIF") }
        let n = CGImageSourceGetCount(src)
        var duration = 0.0, width = 0, height = 0, blacks: [Double] = []
        var prev: [Float]?, motion: [Double] = [], sharp: [Double] = []
        for i in 0..<n {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            if i % max(1, n / 40) == 0, let img = CGImageSourceCreateImageAtIndex(src, i, nil), let g = gray(img) {
                width = img.width; height = img.height
                let mean = Double(g.pixels.reduce(0, +)) / Double(g.pixels.count)
                let variance = g.pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(g.pixels.count)
                if mean < 0.04 && variance.squareRoot() < 0.012 { blacks.append(duration) }
                sharp.append(laplacianVariance(g))
                if let p = prev, p.count == g.pixels.count { motion.append(Double(zip(p, g.pixels).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }) / Double(p.count)) }
                prev = g.pixels
            }
            duration += delay
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var checks: [QualityCheck] = []
        if let e = expectedDuration {
            checks.append(QualityCheck("duration_matches_edit", abs(duration - e) <= 0.25 ? .pass : .fail, value: duration, threshold: String(format: "%.2fs", e),
                                       String(format: "GIF lasts %.2fs vs edit %.2fs (%d frames)", duration, e, n)))
        }
        if let (ew, eh) = expectedSize { checks.append(QualityCheck("resolution", width == ew && height == eh ? .pass : .fail, threshold: "\(ew)×\(eh)", "GIF is \(width)×\(height)")) }
        checks.append(QualityCheck("black_frames", blacks.isEmpty ? .pass : .fail, value: Double(blacks.count), "\(blacks.count) black frame(s)"))
        checks.append(QualityCheck("file_size", bytes < 15_000_000 ? .pass : .warn, value: Double(bytes), threshold: "< 15 MB",
                                   String(format: "%.1f MB", Double(bytes) / 1e6), fix: bytes >= 15_000_000 ? "lower size or fps, or shorten" : nil))
        let sharpness = sharp.isEmpty ? 0 : sharp.sorted()[sharp.count / 2]
        return RenderReport(path: url.path, fileBytes: bytes, duration: duration, width: width, height: height, frameRate: duration > 0 ? Double(n) / duration : 0,
                            codec: "gif", bitrate: duration > 0 ? Double(bytes * 8) / duration : 0, hasAudio: false, audio: nil, sampledFrames: min(n, 40),
                            blackFrames: blacks, frozenRanges: [], motion: motion, sharpness: sharpness,
                            quality: QualityReport(checks: checks, metrics: ["duration": duration, "frames": Double(n)]))
    }

    struct Gray { var width: Int; var height: Int; var pixels: [Float] }

    static func gray(_ img: CGImage) -> Gray? {
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Gray(width: w, height: h, pixels: bytes.map { Float($0) / 255 })
    }

    static func laplacianVariance(_ g: Gray) -> Double {
        guard g.width > 2, g.height > 2 else { return 0 }
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let i = y * g.width + x
                let l = Double(4 * g.pixels[i] - g.pixels[i - 1] - g.pixels[i + 1] - g.pixels[i - g.width] - g.pixels[i + g.width])
                sum += l; sum2 += l * l; n += 1
            }
        }
        let mean = sum / n
        return sum2 / n - mean * mean
    }
}
