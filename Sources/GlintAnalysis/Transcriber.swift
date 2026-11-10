import Foundation
import AVFoundation
import Speech
import GlintCore

/// On-device transcription with word timings.
/// Primary engine: Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26, on-device, no network once the locale
/// model is installed). Fallback: the `whisper` CLI if present on PATH.
public enum Transcriber {
    public enum Engine: String, Codable, Sendable { case auto, apple, whisper }

    public static func transcribe(bundle: ProjectBundle, document: ProjectDocument, locale: String = "en-US", engine: Engine = .auto,
                                  source: String? = nil) async throws -> Transcript {
        let pick: (String, String)? = {
            if source == "system" { return document.media.systemAudio.map { ("system", $0) } }
            if source == "microphone" { return document.media.microphone.map { ("microphone", $0) } }
            if let m = document.media.microphone { return ("microphone", m) }
            if let s = document.media.systemAudio { return ("system", s) }
            return nil
        }()
        guard let (srcName, path) = pick else { throw RenderAnalysisError.unavailable("This project has no audio track to transcribe.") }
        let url = bundle.resolve(path)
        var words: [CaptionWord] = []
        var used = ""
        if engine != .whisper {
            do {
                words = try await apple(url: url, locale: locale)
                used = "apple-speechtranscriber"
            } catch {
                try Task.checkCancellation()
                if engine == .apple { throw error }
            }
        }
        if used.isEmpty {
            words = try await whisper(url: url, locale: locale)
            used = "whisper-cli"
        }
        return Transcript(engine: used, locale: locale, source: srcName, words: words)
    }

    /// Apple SpeechTranscriber with audio time ranges per run → words.
    public static func apple(url: URL, locale: String) async throws -> [CaptionWord] {
        guard SpeechTranscriber.isAvailable else { throw RenderAnalysisError.unavailable("SpeechTranscriber isn't available on this Mac") }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw RenderAnalysisError.unavailable("Locale \(locale) isn't supported by SpeechTranscriber")
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        // SpeechAnalyzer reads AVAudioFile; decode compressed/odd formats to a temporary PCM file first.
        let pcmURL = FileManager.default.temporaryDirectory.appendingPathComponent("glint-asr-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let samples = try await AudioAnalysis.decodeMono(url: url, sampleRate: 16000)
        guard !samples.isEmpty else { return [] }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            let f = try AVAudioFile(forWriting: pcmURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
            try f.write(from: buf)
        }
        let file = try AVAudioFile(forReading: pcmURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [CaptionWord] in
            var out: [CaptionWord] = []
            for try await result in transcriber.results {
                out += words(from: result.text)
            }
            return out
        }
        defer { collector.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let result = try await collector.value.sorted { $0.start < $1.start }
                try Task.checkCancellation()
                return result
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Split an attributed transcript into words, distributing each timed run's range across its words.
    static func words(from text: AttributedString) -> [CaptionWord] {
        var out: [CaptionWord] = []
        for run in text.runs {
            let s = String(text[run.range].characters)
            guard let tr = run.audioTimeRange else { continue }
            let tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { continue }
            let start = tr.start.seconds, end = tr.end.seconds
            let total = tokens.reduce(0) { $0 + $1.count }
            var t = start
            for tok in tokens {
                let d = (end - start) * Double(tok.count) / Double(max(1, total))
                out.append(CaptionWord(text: tok, start: t, end: t + d))
                t += d
            }
        }
        // Attach stray punctuation tokens to the previous word.
        var merged: [CaptionWord] = []
        for w in out {
            if let last = merged.last, w.text.allSatisfy({ $0.isPunctuation }) {
                merged[merged.count - 1] = CaptionWord(text: last.text + w.text, start: last.start, end: w.end)
            } else { merged.append(w) }
        }
        return merged
    }

    static func whisper(url: URL, locale: String) async throws -> [CaptionWord] {
        guard let exe = ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RenderAnalysisError.unavailable("No transcription engine available (SpeechTranscriber failed and no `whisper` CLI found)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [url.path, "--model", "base", "--language", String(locale.prefix(2)), "--word_timestamps", "True",
                       "--output_format", "json", "--output_dir", dir.path, "--fp16", "False"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try p.run()
        do {
            while p.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
            try Task.checkCancellation()
        } catch {
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning, Date() < deadline {
                await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            throw error
        }
        guard p.terminationStatus == 0,
              let json = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "json" }),
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
              let segments = root["segments"] as? [[String: Any]] else { throw RenderAnalysisError.failed("whisper failed") }
        var out: [CaptionWord] = []
        for s in segments {
            for w in (s["words"] as? [[String: Any]]) ?? [] {
                guard let text = (w["word"] as? String)?.trimmingCharacters(in: .whitespaces), let st = w["start"] as? Double, let en = w["end"] as? Double else { continue }
                out.append(CaptionWord(text: text, start: st, end: en))
            }
        }
        return out
    }
}
