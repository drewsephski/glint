import Foundation
import AVFoundation
import CoreImage
import Accelerate
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
    public static func inspect(url: URL, expectedDuration: Double? = nil, expectedSize: (Int, Int)? = nil, sampleRate: Double = 4) async throws -> RenderReport {
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
        if let at {
            let pcm = try AudioAnalysis.decodeMono(asset: asset, tracks: [at], sampleRate: 48000, timeRange: nil, mix: nil)
            audio = AudioAnalysis.stats(pcm, sampleRate: 48000)
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
            checks.append(QualityCheck("bitrate", bpp >= 0.03 ? .pass : .warn, value: bitrate, threshold: "≥ 0.03 bits/pixel/frame",
                                       String(format: "%.1f Mbit/s (%.3f bpp)", bitrate / 1e6, bpp)))
        }
        if let a = audio {
            if let l = a.integratedLUFS {
                checks.append(QualityCheck("loudness", (-20 ... -12).contains(l) ? .pass : (-26 ... -9).contains(l) ? .warn : .fail, value: l, threshold: "-16 LUFS ±4",
                                           String(format: "Integrated loudness %.1f LUFS", l), fix: (-20 ... -12).contains(l) ? nil : "adjust style.audio gains"))
            } else {
                checks.append(QualityCheck("loudness", .info, "Audio track is silent"))
            }
            checks.append(QualityCheck("clipping", a.clippedFraction < 0.0005 ? .pass : .warn, value: a.clippedFraction, threshold: "< 0.05%",
                                       String(format: "Peak %.1f dBFS", a.peakDBFS), fix: a.clippedFraction >= 0.0005 ? "lower style.audio gains" : nil))
        }
        let q = QualityReport(checks: checks, metrics: ["duration": duration, "bitrate": bitrate, "sharpness": sharpness, "mean_motion": motion.isEmpty ? 0 : motion.reduce(0, +) / Double(motion.count)])
        return RenderReport(path: url.path, fileBytes: bytes, duration: duration, width: width, height: height, frameRate: fps, codec: codec,
                            bitrate: bitrate, hasAudio: at != nil, audio: audio, sampledFrames: sampled, blackFrames: blacks, frozenRanges: frozen,
                            motion: motion.map { ($0 * 10000).rounded() / 10000 }, sharpness: sharpness, quality: q)
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
