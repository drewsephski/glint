import Foundation
import AVFoundation
import Accelerate
import GlintCore

public struct AudioStats: Codable, Hashable, Sendable {
    public var duration: Double
    /// Integrated loudness (ITU-R BS.1770 K-weighted, gated), LUFS.
    public var integratedLUFS: Double?
    public var peakDBFS: Double
    public var clippedFraction: Double
    /// Short-term (100 ms) RMS envelope in dBFS — handy for agents to see where sound is.
    public var envelope: [Double]
    public var envelopeRate: Double
}

public enum AudioAnalysis {
    /// Decode any audio file / track to mono Float32 at `sampleRate`.
    public static func decodeMono(url: URL, sampleRate: Double = 16000, timeRange: CMTimeRange? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        return try decodeMono(asset: asset, tracks: [track], sampleRate: sampleRate, timeRange: timeRange, mix: nil)
    }

    public static func decodeMono(asset: AVAsset, tracks: [AVAssetTrack], sampleRate requested: Double, timeRange: CMTimeRange?, mix: AVAudioMix?) throws -> [Float] {
        // AVFoundation raises an Objective-C exception outside 8–192 kHz; clamp instead of crashing.
        let sampleRate = min(192_000, max(8_000, requested))
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        out.audioMix = mix
        reader.add(out)
        guard reader.startReading() else { throw RenderAnalysisError.failed(reader.error?.localizedDescription ?? "audio read") }
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// RMS in dBFS over windows of `window` seconds.
    public static func envelope(_ x: [Float], sampleRate: Double, window: Double = 0.02) -> [Double] {
        let n = max(1, Int(sampleRate * window))
        var out: [Double] = []
        out.reserveCapacity(x.count / n + 1)
        var i = 0
        x.withUnsafeBufferPointer { buf in
            while i < buf.count {
                let len = min(n, buf.count - i)
                var ms: Float = 0
                vDSP_measqv(buf.baseAddress! + i, 1, &ms, vDSP_Length(len))
                out.append(10 * log10(max(1e-12, Double(ms))))
                i += n
            }
        }
        return out
    }

    /// Speech-free ranges: windows below an adaptive threshold (noise floor + 14 dB, at least -48 dBFS),
    /// with hangover so word gaps don't count.
    public static func silences(_ x: [Float], sampleRate: Double, minDuration: Double = 0.6) -> [TimeRange] {
        let win = 0.02
        let env = envelope(x, sampleRate: sampleRate, window: win)
        guard !env.isEmpty else { return [] }
        let sorted = env.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.1)]
        let speechLevel = sorted[Int(Double(sorted.count) * 0.95)]
        let threshold = max(-55, min(-30, max(floor + 14, (floor + speechLevel) / 2 - 4)))
        var out: [TimeRange] = []
        var start: Int?
        for (i, v) in env.enumerated() {
            if v < threshold { if start == nil { start = i } }
            else if let s = start {
                if Double(i - s) * win >= minDuration { out.append(TimeRange(Double(s) * win, Double(i) * win)) }
                start = nil
            }
        }
        if let s = start, Double(env.count - s) * win >= minDuration { out.append(TimeRange(Double(s) * win, Double(env.count) * win)) }
        return out
    }

    /// BS.1770-4 integrated loudness with absolute (-70) and relative (-10 LU) gating, mono input at 48 kHz-ish rates.
    public static func integratedLoudness(_ x: [Float], sampleRate: Double) -> Double? {
        guard x.count > Int(sampleRate * 0.4) else { return nil }
        // K-weighting: high-shelf + high-pass biquads (coefficients derived for the given rate).
        func biquad(_ input: [Float], b: [Double], a: [Double]) -> [Float] {
            var y = [Float](repeating: 0, count: input.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<input.count {
                let x0 = Double(input[i])
                let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                y[i] = Float(y0)
            }
            return y
        }
        let fs = sampleRate
        // Stage 1 (shelf)
        var f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(.pi * f0 / fs)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let b1s = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
        let a1s = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        // Stage 2 (high-pass)
        f0 = 38.13547087602444; Q = 0.5003270373238773; G = 0
        K = tan(.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        let b2 = [1.0, -2.0, 1.0]
        let a2 = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        let y = biquad(biquad(x, b: b1s, a: a1s), b: b2, a: a2)
        // 400 ms blocks, 75% overlap.
        let block = Int(fs * 0.4), hop = Int(fs * 0.1)
        var energies: [Double] = []
        var i = 0
        y.withUnsafeBufferPointer { buf in
            while i + block <= buf.count {
                var ms: Float = 0
                vDSP_measqv(buf.baseAddress! + i, 1, &ms, vDSP_Length(block))
                energies.append(Double(ms))
                i += hop
            }
        }
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(1e-12, e)) }
        let abs = energies.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return nil }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    public static func stats(_ x: [Float], sampleRate: Double) -> AudioStats {
        var peak: Float = 0
        if !x.isEmpty { vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count)) }
        let clipped = x.isEmpty ? 0 : Double(x.lazy.filter { abs($0) >= 0.999 }.count) / Double(x.count)
        return AudioStats(duration: Double(x.count) / sampleRate, integratedLUFS: integratedLoudness(x, sampleRate: sampleRate),
                          peakDBFS: 20 * log10(max(1e-9, Double(peak))), clippedFraction: clipped,
                          envelope: envelope(x, sampleRate: sampleRate, window: 0.1).map { ($0 * 10).rounded() / 10 }, envelopeRate: 10)
    }
}

public enum RenderAnalysisError: Error, CustomStringConvertible {
    case failed(String)
    case unavailable(String)
    public var description: String {
        switch self {
        case .failed(let s): return "Analysis failed: \(s)"
        case .unavailable(let s): return s
        }
    }
}
