import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import GlintCore

/// Turns a recording into a storyboard an agent (or a person) can write narration from: scenes from the input
/// events, one representative frame per scene, and the text visible in that frame (on-device OCR). Nothing leaves
/// the Mac here.
public enum SceneAnalyzer {
    public struct Options: Sendable {
        public var segment = SceneSegmentOptions()
        public var frames = true
        public var ocr = true
        public var maxFrameWidth = 1600
        public init() {}
    }

    public static func analyze(bundle: ProjectBundle, document doc: ProjectDocument, options: Options = .init(),
                               progress: (@Sendable (String) -> Void)? = nil) async throws -> Storyboard {
        let events = bundle.readEvents()
        let transcript = bundle.readTranscript()
        var scenes = SceneSegmenter.scenes(document: doc, events: events, transcript: transcript, options: options.segment)
        // Keep narration already written for scenes that still exist at (roughly) the same place.
        let previous = bundle.readStoryboard()
        if let previous {
            for i in scenes.indices {
                if let old = previous.scenes.first(where: { abs($0.start - scenes[i].start) < 0.75 && abs($0.end - scenes[i].end) < 1.5 }) {
                    scenes[i].narration = old.narration
                    if old.title != "Scene" && !old.title.hasPrefix("Scene ") { scenes[i].title = old.title }
                }
            }
        }
        if options.frames {
            try FileManager.default.createDirectory(at: bundle.analysisURL, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: bundle.resolve(doc.media.screen))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.maximumSize = CGSize(width: options.maxFrameWidth, height: options.maxFrameWidth)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            for i in scenes.indices {
                progress?("scene \(i + 1)/\(scenes.count)")
                let t = scenes[i].frameTime ?? (scenes[i].start + scenes[i].duration / 3)
                guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
                let url = bundle.analysisURL.appendingPathComponent("\(scenes[i].id).jpg")
                try writeJPEG(img, to: url)
                scenes[i].frame = "analysis/\(scenes[i].id).jpg"
                if options.ocr { scenes[i].onScreenText = recognizeText(img) }
                // Better titles than "Scene n": the clicked label, else the most prominent line of text.
                if scenes[i].title.hasPrefix("Scene "), let heading = scenes[i].onScreenText.first(where: { $0.count >= 3 && $0.count <= 40 }) {
                    scenes[i].title = heading
                }
            }
        }
        var sb = Storyboard(revision: doc.revision, scenes: scenes, brief: previous?.brief, title: previous?.title, summary: previous?.summary, writer: previous?.writer)
        sb.notes = ["\(scenes.count) scenes from \(events.clicks.count) clicks, \(events.keys.count) keys, \(doc.timeline.markers.count + events.markers.count) markers"]
        try bundle.writeStoryboard(sb)
        return sb
    }

    /// Visible text lines, top to bottom, left to right. Accurate on-device recognition; low-confidence and tiny
    /// fragments are dropped so the list reads like the screen does.
    public static func recognizeText(_ image: CGImage, maxLines: Int = 48) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        struct Line { var text: String; var x: CGFloat; var y: CGFloat; var height: CGFloat }
        var lines: [Line] = []
        for obs in results {
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.35 else { continue }
            let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 2, s.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            lines.append(Line(text: String(s.prefix(90)), x: obs.boundingBox.minX, y: obs.boundingBox.maxY, height: obs.boundingBox.height))
        }
        // Group into rows (same baseline within half a line height), then sort rows top-down and cells left-right.
        lines.sort { $0.y > $1.y }
        var rows: [[Line]] = []
        for l in lines {
            if let last = rows.last, let ref = last.first, abs(ref.y - l.y) < max(ref.height, l.height) * 0.6 {
                rows[rows.count - 1].append(l)
            } else { rows.append([l]) }
        }
        var out: [String] = []
        var seen = Set<String>()
        for row in rows {
            let text = row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "   ")
            let key = text.lowercased()
            if seen.insert(key).inserted { out.append(text) }
            if out.count >= maxLines { break }
        }
        return out
    }

    static func writeJPEG(_ img: CGImage, to url: URL, quality: Double = 0.82) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw RenderAnalysisError.failed("jpeg") }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw RenderAnalysisError.failed("jpeg write") }
    }
}
