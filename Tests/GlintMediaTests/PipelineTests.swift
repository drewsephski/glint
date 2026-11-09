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

@Suite(.serialized) struct PipelineTests {
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
}
