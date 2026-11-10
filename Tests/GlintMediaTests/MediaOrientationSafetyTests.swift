import Foundation
import Testing
import CoreGraphics
import AVFoundation
@testable import GlintCore
@testable import GlintRender
@testable import GlintAgent

@Suite(.serialized) struct MediaOrientationSafetyTests {
    /// Make real rotation metadata without rotating the encoded pixels. Red on the encoded left becomes
    /// the displayed top half. An identity-transform shot follows it to exercise a mixed-track boundary.
    private func rotatedMovie(in directory: URL) async throws -> URL {
        let raw = directory.appendingPathComponent("landscape.mov")
        try await SyntheticProject.writeVideo(to: raw, duration: 2, width: 320, height: 180, fps: 15) { ctx, _, w, h in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
        let asset = AVURLAsset(url: raw)
        let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let rotated = directory.appendingPathComponent("portrait.mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: rotated, as: .mov)
        return rotated
    }

    @Test func rotatedImportsMatchPresentationAndKeepMasksAlignedInExport() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("orientation"), duration: 2)
        defer { try? FileManager.default.removeItem(at: b.url) }
        let directory = b.mediaURL.appendingPathComponent("orientation-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rotated = try await rotatedMovie(in: directory)
        let service = GlintService()
        let (op, clip) = try await service.importClip(b, file: rotated, at: 1, name: "Portrait", scene: nil)
        #expect(clip.width == 180 && clip.height == 320)
        try Engine(bundle: b).apply(fullBleed + [op], author: .cli)
        var doc = try b.readDocument()
        let comp = try await EditComposition.build(bundle: b, document: doc, width: 640, height: 400)
        let shotRect = comp.plan.contentRect(outputTime: 1.5)
        func region(_ r: NormRect) -> CGRect {
            CGRect(x: shotRect.x + r.x * shotRect.width, y: shotRect.y + r.y * shotRect.height,
                   width: r.width * shotRect.width, height: r.height * shotRect.height)
        }
        let top = region(NormRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3))
        let bottom = region(NormRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3))
        let preview = try await Frames.image(comp, at: 1.5)
        #expect(colorPresence(preview, RGBA(1, 0, 0), in: top).fraction > 0.95)
        #expect(colorPresence(preview, RGBA(0, 0, 1), in: bottom).fraction > 0.95)
        // A normal shot after the portrait retains its original orientation and placement.
        let original = try await EditComposition.build(bundle: b, document: try OperationApplier.apply(fullBleed, to: ProjectDocument(name: "Original", media: doc.media)), width: 640, height: 400)
        #expect(meanAbsDiff(try await Frames.image(comp, at: 3.5), try await Frames.image(original, at: 1.5)) < 0.02)

        // Use the same inverse mapping as drawing in the preview, then assert actual pixels at that region.
        let start = comp.plan.shotPoint(forView: NormPoint(top.minX, top.minY), outputTime: 1.5)
        let end = comp.plan.shotPoint(forView: NormPoint(top.maxX, top.maxY), outputTime: 1.5)
        doc.timeline.redactions = [Redaction(start: 1, end: 3, rect: NormRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y), mode: .solid, color: RGBA(0, 1, 0))]
        let masked = try await EditComposition.build(bundle: b, document: doc, width: 640, height: 400)
        let inset = top.insetBy(dx: 0.01, dy: 0.01)
        #expect(colorPresence(try await Frames.image(masked, at: 1.5), RGBA(0, 1, 0), in: inset).fraction > 0.95)
        let output = b.rendersURL.appendingPathComponent("orientation/movie.mp4")
        _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant(name: "orientation", aspect: .auto, size: 400, fps: 15), to: output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let exported = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        #expect(colorPresence(exported, RGBA(0, 1, 0), in: inset).fraction > 0.95)
        #expect(colorPresence(exported, RGBA(0, 0, 1), in: bottom).fraction > 0.95)
    }

    @Test func renderRejectsInvalidPersistedDurationsBeforeAllocatingMotion() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("invalid-duration"), duration: 1)
        defer { try? FileManager.default.removeItem(at: b.url) }
        var doc = try b.readDocument()
        doc.media.duration = 1e308
        await #expect(throws: EditError.self) { try await EditComposition.build(bundle: b, document: doc) }
        doc = try b.readDocument()
        doc.timeline.clips = [MediaClip(name: "Overrun", path: doc.media.screen, mediaEnd: 5, width: doc.media.width, height: doc.media.height)]
        await #expect(throws: RenderError.self) { try await EditComposition.build(bundle: b, document: doc) }
    }
}
