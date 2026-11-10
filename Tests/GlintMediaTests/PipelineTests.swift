import Foundation
import Testing
import CoreGraphics
import AVFoundation
@testable import GlintCore
@testable import GlintRender
@testable import GlintAnalysis
@testable import GlintAgent

func fixtureURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("glint-media-\(name)-\(UUID().uuidString.prefix(6)).glint")
}

/// Fraction of pixels that are the fixture's red "Save" button colour.
func redFraction(_ img: CGImage) -> Double {
    let w = 320, h = Int(Double(img.height) / Double(img.width) * 320)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var red = 0
    for i in stride(from: 0, to: px.count, by: 4) where px[i] > 200 && px[i + 1] < 90 && px[i + 2] < 90 { red += 1 }
    return Double(red) / Double(w * h)
}

func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
    func gray(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 256 * 144)
        let ctx = CGContext(data: &px, width: 256, height: 144, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 256, height: 144))
        return px
    }
    let ga = gray(a), gb = gray(b)
    return Double(zip(ga, gb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(ga.count) / 255
}

/// Fraction of the pixels inside `region` (unit rect, origin top-left) that are close to `c`, and their mean x
/// position within the region (0 = left edge, 1 = right edge).
func colorPresence(_ img: CGImage, _ c: RGBA, in region: CGRect, tolerance: Int = 45) -> (fraction: Double, meanX: Double) {
    let w = 480, h = Int(Double(img.height) / Double(img.width) * 480)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let x0 = Int(region.minX * Double(w)), x1 = Int(region.maxX * Double(w)), y0 = Int(region.minY * Double(h)), y1 = Int(region.maxY * Double(h))
    let want = [Int(c.r * 255), Int(c.g * 255), Int(c.b * 255)]
    var hits = 0, sumX = 0.0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let i = (y * w + x) * 4          // row 0 is the top of the image
            if abs(Int(px[i]) - want[0]) < tolerance, abs(Int(px[i + 1]) - want[1]) < tolerance, abs(Int(px[i + 2]) - want[2]) < tolerance {
                hits += 1; sumX += Double(x - x0) / Double(max(1, x1 - x0))
            }
        }
    }
    return (Double(hits) / Double(max(1, (x1 - x0) * (y1 - y0))), hits > 0 ? sumX / Double(hits) : 0.5)
}

@Suite(.serialized) struct PipelineTests {
    @Test func facecamBubbleIsComposited() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("facecam"), duration: 4, camera: true)
        let e = Engine(bundle: b)
        let wall = SyntheticProject.presenterWall, lamp = SyntheticProject.presenterLamp
        let bottomRight = CGRect(x: 0.75, y: 0.6, width: 0.25, height: 0.4), topLeft = CGRect(x: 0, y: 0, width: 0.25, height: 0.4)
        func frame(_ doc: ProjectDocument, at t: Double = 1) async throws -> CGImage {
            try await Frames.image(try await EditComposition.build(bundle: b, document: doc, width: 960, height: 540), at: t)
        }
        var doc = try b.readDocument()
        #expect(doc.media.camera == "media/camera.mov" && doc.style.facecam.visible)
        // Default: a circle in the bottom-right corner, mirrored (the lamp on the picture's left shows on the right).
        let shown = try await frame(doc)
        #expect(colorPresence(shown, wall, in: bottomRight).fraction > 0.05)
        #expect(colorPresence(shown, wall, in: topLeft).fraction < 0.001)
        let mirrored = colorPresence(shown, lamp, in: bottomRight)
        #expect(mirrored.fraction > 0.002 && mirrored.meanX > 0.55, "lamp \(mirrored)")

        try e.apply([.style("facecam.mirror", .bool(false)), .style("facecam.position", .string("top-left")), .style("facecam.shape", .string("wide"))], author: .cli)
        doc = try b.readDocument()
        let moved = try await frame(doc)
        #expect(colorPresence(moved, wall, in: bottomRight).fraction < 0.001)
        #expect(colorPresence(moved, wall, in: topLeft).fraction > 0.05)
        let plain = colorPresence(moved, lamp, in: topLeft)
        #expect(plain.fraction > 0.002 && plain.meanX < 0.45, "lamp \(plain)")

        // Zoomed in, the bubble shrinks towards its corner.
        try e.apply([EditOperation(.addZoom, start: 1.5, end: 3.5, scale: 2.2), .style("facecam.scaleWhenZoomed", .number(0.5))], author: .cli)
        doc = try b.readDocument()
        let zoomed = try await frame(doc, at: 2.8)
        #expect(colorPresence(zoomed, wall, in: topLeft).fraction < colorPresence(moved, wall, in: topLeft).fraction * 0.5)

        // Cuts and speed changes apply to the camera too, and the export is exactly as long as the edit.
        try e.apply([EditOperation(.addCut, start: 0.5, end: 1.0), EditOperation(.setSpeed, start: 3.0, end: 4.0, rate: 2)], author: .cli)
        doc = try b.readDocument()
        let expected = TimeMap(document: doc).outputDuration
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("glint-facecam-\(UUID().uuidString.prefix(6)).mp4")
        _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant(name: "t", aspect: .landscape, size: 360, fps: 30), to: out)
        let report = try await RenderInspector.inspect(url: out, expectedDuration: expected, expectedSize: (640, 360))
        #expect(report.quality.checks.first { $0.id == "duration_matches_edit" }?.verdict == .pass, "\(report.duration) vs \(expected)")
        #expect(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).count == 1)

        // Hidden: no bubble, and no camera track to decode.
        try e.apply([.style("facecam.visible", .bool(false))], author: .cli)
        doc = try b.readDocument()
        let comp = try await EditComposition.build(bundle: b, document: doc, width: 960, height: 540)
        #expect(try await comp.asset.loadTracks(withMediaType: .video).count == 1)
        #expect(colorPresence(try await Frames.image(comp, at: 1), wall, in: topLeft).fraction < 0.001)
    }

    @Test func zoomPlanMagnifiesTheClickedControl() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("zoom"))
        let s = GlintService()
        let (ops, zooms) = try s.planZooms(b, options: ZoomPlanOptions())
        #expect(!zooms.isEmpty)
        #expect(zooms[0].start < 1.6 && zooms[0].end > 1.7)       // covers the Save click
        try Engine(bundle: b).apply(ops, author: Author(.agent, "test"))

        let doc = try b.readDocument()
        let comp = try await EditComposition.build(bundle: b, document: doc, width: 960, height: 540)
        let rest = try await Frames.image(comp, at: 0.1)            // before the zoom
        // 1.5s: camera has arrived on Save, before the click ripple (1.6s) tints the button.
        let zoomedRed = try await Frames.image(comp, at: 1.5)
        let r0 = redFraction(rest), r1 = redFraction(zoomedRed)
        // At ~2× magnification the button's area grows ~4×; demand at least 2.5×.
        #expect(r0 > 0.001)
        #expect(r1 > r0 * 2.5, "red fraction rest \(r0) zoomed \(r1)")
    }

    @Test func exportMatchesEditDurationAndPreview() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("export"))
        let e = Engine(bundle: b)
        try e.apply([EditOperation(.addCut, start: 6.5, end: 8.0), EditOperation(.setSpeed, start: 3.2, end: 4.8, rate: 2),
                     EditOperation(.addZoom, start: 1.0, end: 3.0, scale: 2)], author: .cli)
        let doc = try b.readDocument()
        let expected = TimeMap(document: doc).outputDuration
        #expect(abs(expected - (9 - 1.5 - 0.8)) < 0.01)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("glint-export-\(UUID().uuidString.prefix(6)).mp4")
        let variant = RenderVariant(name: "t", aspect: .landscape, size: 360, fps: 30)
        _ = try await Exporter.export(bundle: b, document: doc, variant: variant, to: out)
        let report = try await RenderInspector.inspect(url: out, expectedDuration: expected, expectedSize: (640, 360))
        #expect(report.quality.checks.first { $0.id == "duration_matches_edit" }?.verdict == .pass, "\(report.duration) vs \(expected)")
        #expect(report.quality.checks.first { $0.id == "resolution" }?.verdict == .pass)
        #expect(report.blackFrames.isEmpty)
        #expect(report.codec == "avc1")

        // Preview (AVAssetImageGenerator on the live composition) == export (decoded file).
        let comp = try await EditComposition.build(bundle: b, document: doc, width: 640, height: 360, frameRate: 30)
        for t in [0.5, 2.0, 4.0] {
            let preview = try await Frames.image(comp, at: t)
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            let exported = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let d = meanAbsDiff(preview, exported)
            #expect(d < 0.03, "preview/export differ by \(d) at \(t)s")
        }
    }

    @Test func variantsRender() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("variants"), duration: 4)
        try Engine(bundle: b).apply([EditOperation(.addZoom, start: 1.0, end: 3.0, scale: 2)], author: .cli)
        let doc = try b.readDocument()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-variants-\(UUID().uuidString.prefix(6))")
        var portrait = RenderVariant.preset("portrait")!; portrait.size = 360
        let p = try await Exporter.export(bundle: b, document: doc, variant: portrait, to: dir.appendingPathComponent("p.mp4"))
        let rp = try await RenderInspector.inspect(url: p)
        #expect(rp.width == 360 && rp.height == 640)
        var gif = RenderVariant.preset("gif")!; gif.size = 180
        let g = try await Exporter.export(bundle: b, document: doc, variant: gif, to: dir.appendingPathComponent("g.gif"))
        let attrs = try FileManager.default.attributesOfItem(atPath: g.path)
        #expect((attrs[.size] as? Int ?? 0) > 10_000)
    }

    @Test func silenceDetectionAndLoudness() async throws {
        // 1 s tone, 1.5 s silence, 1 s tone at 16 kHz.
        let sr = 16000.0
        var x: [Float] = []
        for (dur, amp) in [(1.0, 0.3), (1.5, 0.0), (1.0, 0.3)] as [(Double, Float)] {
            for i in 0..<Int(dur * sr) { x.append(amp * sin(Float(i) * 2 * .pi * 440 / Float(sr)) + Float.random(in: -0.0005...0.0005)) }
        }
        let sil = AudioAnalysis.silences(x, sampleRate: sr, minDuration: 0.6)
        #expect(sil.count == 1)
        #expect(abs(sil[0].start - 1.0) < 0.05 && abs(sil[0].end - 2.5) < 0.05)
        let l = AudioAnalysis.integratedLoudness(x, sampleRate: sr)
        #expect(l != nil && l! > -20 && l! < -5)
    }

    @Test func autopilotWithVoiceProducesVerifiedDeliverable() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("autopilot"), voice: true)
        let ctx = ToolContext(author: Author(.agent, "test"), service: GlintService())
        let out = try await ToolRegistry.call("autopilot", arguments: .object(["project": .string(b.url.path), "variants": .array([.string("preview")])]), context: ctx)
        let steps = out.json["steps"]?.arrayValue?.compactMap { $0.str("step") } ?? []
        #expect(steps.contains("plan_zooms"))
        #expect(steps.contains("plan_cuts"))
        let doc = try b.readDocument()
        #expect(!doc.timeline.zooms.isEmpty)
        let render = out.json["render"]?["outputs"]?.arrayValue?.first
        #expect(render?["report"]?["quality"]?["checks"]?.arrayValue?.first(where: { $0.str("id") == "duration_matches_edit" })?.str("verdict") == "pass")
        // Every autopilot step is a separate, attributed, undoable transaction.
        let h = Engine(bundle: b).history()
        #expect(h.count >= 2)
        #expect(h.allSatisfy { $0.author == Author(.agent, "test") })
    }

    @Test func narratedDemoRendersWithVoiceTrackAndCaptions() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("narration"), narration: true)
        let doc = try b.readDocument()
        #expect(doc.timeline.voiceover.count >= 1)
        #expect(!doc.timeline.captions.isEmpty && doc.style.captions.enabled)
        #expect(b.readStoryboard()?.narratedScenes.count == doc.timeline.voiceover.count)
        // Every scene lasts at least as long as its line after the fit.
        let map = TimeMap(document: doc)
        for c in doc.timeline.voiceover {
            let o = map.outputClamped(forSource: c.start)
            #expect(o + c.duration <= map.outputDuration + 0.6, "clip at \(c.start) runs past the end: \(o + c.duration) > \(map.outputDuration)")
        }
        // The composition carries one audio track per clip; the recorded tracks duck under them.
        let comp = try await EditComposition.build(bundle: b, document: doc)
        let audioTracks = try await comp.asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == doc.timeline.voiceover.count)
        #expect(comp.audioMix?.inputParameters.count == audioTracks.count)
        try FileManager.default.createDirectory(at: b.rendersURL.appendingPathComponent("vo-test"), withIntermediateDirectories: true)
        let out = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant.preset("preview")!, to: b.rendersURL.appendingPathComponent("vo-test/out.mp4"))
        let rendered = AVURLAsset(url: out)
        #expect(try await rendered.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await rendered.load(.duration).seconds - map.outputDuration) < 0.3)
        // Voiceover is speech: no dead-air failure over the narrated stretch.
        let q = EditQuality.report(document: doc, events: b.readEvents(), transcript: nil)
        #expect(q.checks.first { $0.id == "dead_air" }?.verdict != .fail)
    }
}
