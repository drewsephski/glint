import Foundation
import Testing
import CoreGraphics
import AVFoundation
@testable import GlintCore
@testable import GlintRender
@testable import GlintAnalysis
@testable import GlintAgent

/// A movie that is one flat colour (stands in for another take or an imported clip).
func solidMovie(_ url: URL, color: RGBA, duration: Double, width: Int = 1280, height: Int = 800) async throws {
    try await SyntheticProject.writeVideo(to: url, duration: duration, width: width, height: height, fps: 15) { ctx, _, w, h in
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
}

/// A sine tone (PCM WAV) for music/voice import tests.
func toneFile(_ url: URL, seconds: Double, hz: Double = 440, level: Float = 0.3) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
    let n = AVAudioFrameCount(seconds * 48000)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for i in 0..<Int(n) { buf.floatChannelData![0][i] = level * Float(sin(2 * .pi * hz * Double(i) / 48000)) }
    try f.write(from: buf)
}

/// Mean absolute difference between horizontally adjacent pixels inside a unit-rect region: high for text and
/// detail, low for a flat or pixelated area.
func edgeEnergy(_ img: CGImage, in region: CGRect) -> Double {
    let w = 640, h = Int(Double(img.height) / Double(img.width) * 640)
    var px = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let x0 = Int(region.minX * Double(w)), x1 = Int(region.maxX * Double(w)) - 1, y0 = Int(region.minY * Double(h)), y1 = Int(region.maxY * Double(h))
    var sum = 0, n = 0
    for y in y0..<y1 { for x in x0..<x1 { sum += abs(Int(px[y * w + x]) - Int(px[y * w + x + 1])); n += 1 } }
    return Double(sum) / Double(max(1, n))
}

/// The screen fills the canvas exactly (no background, no padding, canvas = source shape), so normalized screen
/// rects are image rects in the rendered frame.
let fullBleed: [EditOperation] = [.style("background.kind", .string("none")), .style("frame.padding", .number(0)), .style("canvas.aspect", .string("auto")),
                                  .style("cursor.visible", .bool(false)), .style("zoom.motionBlur", .number(0))]

func frame(_ b: ProjectBundle, _ doc: ProjectDocument, at t: Double, w: Int = 960) async throws -> CGImage {
    let h = Int(Double(w) * Double(doc.media.height) / Double(doc.media.width))
    return try await Frames.image(try await EditComposition.build(bundle: b, document: doc, width: w, height: h - h % 2), at: t)
}

@Suite(.serialized) struct OverlayRenderTests {
    @Test func redactionMasksPreviewStillsAndExport() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("redact"), duration: 4)
        let e = Engine(bundle: b)
        try e.apply(fullBleed, author: .cli)
        // The header text "Quarterly revenue" sits around x 0.21–0.5, y 0.05–0.1.
        let header = CGRect(x: 0.2, y: 0.04, width: 0.32, height: 0.08)
        let before = try await frame(b, try b.readDocument(), at: 1)
        let detail = edgeEnergy(before, in: header)
        #expect(detail > 4, "fixture header should have text detail (\(detail))")

        try e.apply([EditOperation(.addRedaction, id: "pix", item: .object(["start": .number(0.5), "end": .number(3), "mode": .string("pixelate"), "strength": .number(1),
                                                                             "rect": .object(["x": .number(0.2), "y": .number(0.04), "width": .number(0.32), "height": .number(0.08)])]))], author: .cli)
        var doc = try b.readDocument()
        let masked = try await frame(b, doc, at: 1)
        #expect(edgeEnergy(masked, in: header.insetBy(dx: 0.01, dy: 0.01)) < detail * 0.6, "pixelated header must lose its detail")
        // The privacy claim itself: the text can't be read any more (on-device OCR finds it before, not after).
        #expect(SceneAnalyzer.recognizeText(before).contains { $0.contains("Quarterly") })
        #expect(!SceneAnalyzer.recognizeText(masked).contains { $0.localizedCaseInsensitiveContains("quarterly") || $0.localizedCaseInsensitiveContains("revenue") })
        // Outside the mask, and outside its time range, nothing changes.
        #expect(meanAbsDiff(try await frame(b, doc, at: 3.5), try await frame(b, try b.readDocument(), at: 3.5)) < 0.002)
        let after = try await frame(b, doc, at: 3.5)
        #expect(edgeEnergy(after, in: header) > detail * 0.8)

        // A solid mask is exactly its colour — in the exported movie too.
        try e.apply([EditOperation(.updateRedaction, id: "pix", item: .object(["mode": .string("solid"), "color": .string("#00FF00")]))], author: .cli)
        doc = try b.readDocument()
        #expect(colorPresence(try await frame(b, doc, at: 1), RGBA(0, 1, 0), in: header.insetBy(dx: 0.01, dy: 0.01), tolerance: 20).fraction > 0.97)
        let out = b.rendersURL.appendingPathComponent("t/redact.mp4")
        _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant(name: "t", aspect: .auto, size: 540, fps: 15), to: out)
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let exported = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(colorPresence(exported, RGBA(0, 1, 0), in: header.insetBy(dx: 0.02, dy: 0.015), tolerance: 40).fraction > 0.9, "export must contain the mask")
    }

    @Test func calloutsAreDrawnAndFollowTheZoom() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("callout"), duration: 4)
        let e = Engine(bundle: b)
        try e.apply(fullBleed, author: .cli)
        let magenta = RGBA(1, 0, 1)
        try e.apply([
            EditOperation(.addAnnotation, id: "box", item: .object(["kind": .string("box"), "start": .number(0.5), "end": .number(3.5), "color": .string("#FF00FF"), "strokeWidth": .number(0.012),
                                                                     "rect": .object(["x": .number(0.6), "y": .number(0.5), "width": .number(0.3), "height": .number(0.3)])])),
            EditOperation(.addAnnotation, id: "label", item: .object(["kind": .string("text"), "start": .number(0.5), "end": .number(3.5), "text": .string("Click Save"),
                                                                       "color": .string("#00FFFF"), "textColor": .string("#000000"),
                                                                       "rect": .object(["x": .number(0.25), "y": .number(0.2), "width": .number(0.3), "height": .number(0.1)])])),
        ], author: .cli)
        let doc = try b.readDocument()
        let img = try await frame(b, doc, at: 1.5)
        // The box's left edge is around x 0.6; its centre stays clear.
        #expect(colorPresence(img, magenta, in: CGRect(x: 0.59, y: 0.55, width: 0.025, height: 0.2), tolerance: 40).fraction > 0.15)
        #expect(colorPresence(img, magenta, in: CGRect(x: 0.7, y: 0.6, width: 0.1, height: 0.1), tolerance: 40).fraction < 0.01)
        #expect(colorPresence(img, RGBA(0, 1, 1), in: CGRect(x: 0.25, y: 0.2, width: 0.15, height: 0.05), tolerance: 40).fraction > 0.3)
        // Not shown outside its time range (fades in over 0.2 s).
        #expect(colorPresence(try await frame(b, doc, at: 0.2), magenta, in: CGRect(x: 0.59, y: 0.55, width: 0.025, height: 0.2), tolerance: 40).fraction < 0.01)
        // Zoomed 2× on the box: its left edge moves left on the canvas, with the content.
        try e.apply([EditOperation(.addZoom, start: 0.2, end: 3.8, scale: 2, focus: .object(["x": .number(0.75), "y": .number(0.65)]))], author: .cli)
        let zoomed = try await frame(b, try b.readDocument(), at: 2.5)
        #expect(colorPresence(zoomed, magenta, in: CGRect(x: 0.59, y: 0.55, width: 0.025, height: 0.2), tolerance: 40).fraction < 0.05)
        #expect(colorPresence(zoomed, magenta, in: CGRect(x: 0.18, y: 0.3, width: 0.06, height: 0.4), tolerance: 40).fraction > 0.1)
    }

    @Test func previewCoordinatesRoundTripUnderZoom() throws {
        var d = ProjectDocument(name: "p", media: MediaInfo(screen: "media/screen.mov", width: 1280, height: 800, scale: 2, duration: 6, frameRate: 30))
        d.timeline.zooms = [ZoomSegment(start: 1, end: 5, scale: 2, focus: .point(NormPoint(0.7, 0.6)))]
        let plan = RenderPlan(document: d, events: EventLog(), bundle: nil, width: 1920, height: 1080)
        for t in [0.2, 3.0] {
            for p in [NormPoint(0.1, 0.2), NormPoint(0.75, 0.6), NormPoint(0.5, 0.5)] {
                let v = plan.viewPoint(p, outputTime: t)
                let back = plan.shotPoint(forView: v, outputTime: t)
                #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
            }
        }
        // At rest the screen sits inside the padded 16:9 canvas; zoomed in, the focus point moves towards the centre.
        let rest = plan.viewPoint(NormPoint(0.7, 0.6), outputTime: 0.2), zoomed = plan.viewPoint(NormPoint(0.7, 0.6), outputTime: 3)
        #expect(abs(zoomed.x - 0.5) < abs(rest.x - 0.5))
    }

    @Test func transitionDipsToBlack() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("dip"), duration: 4)
        try Engine(bundle: b).apply(fullBleed + [EditOperation(.addTransition, time: 2, item: .object(["kind": .string("dip_black"), "duration": .number(1)]))], author: .cli)
        let doc = try b.readDocument()
        let mid = try await frame(b, doc, at: 2), off = try await frame(b, doc, at: 0.8)
        #expect(colorPresence(mid, .black, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), tolerance: 12).fraction > 0.95)
        #expect(colorPresence(off, .black, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), tolerance: 12).fraction < 0.2)
    }
}

@Suite(.serialized) struct MultiShotTests {
    @Test func importedShotsPlayInOrderWithCorrectTiming() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("shots"), duration: 4)
        let s = GlintService()
        try Engine(bundle: b).apply(fullBleed, author: .cli)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-src-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blue = dir.appendingPathComponent("blue.mov"), orange = dir.appendingPathComponent("orange.mov")
        try await solidMovie(blue, color: RGBA(0.1, 0.2, 0.9), duration: 3)
        try await solidMovie(orange, color: RGBA(1, 0.5, 0), duration: 2, width: 1280, height: 720)   // a different shape
        let (opA, _) = try await s.importClip(b, file: blue, at: nil, name: "Blue", scene: nil)
        try Engine(bundle: b).apply([opA], author: .cli)
        // Insert the orange shot in the middle of the recording, using only 0.5–1.5 s of it.
        let (opB, clipB) = try await s.importClip(b, file: orange, at: 2, name: "Orange", scene: nil, start: 0.5, end: 1.5)
        try Engine(bundle: b).apply([opB, EditOperation(.addCut, start: 0.5, end: 1)], author: .cli)
        let doc = try b.readDocument()
        // 2 + 1 + 2 + 3, give or take the fixture movies' last frame.
        #expect(abs(doc.duration - 8) < 0.12, "\(doc.duration)")
        #expect(FileManager.default.fileExists(atPath: b.resolve(clipB.path).path))
        let comp = try await EditComposition.build(bundle: b, document: doc, width: 640, height: 400)
        #expect(abs(comp.duration - (doc.duration - 0.5)) < 0.05, "\(comp.duration)")      // 0.5 s cut
        // Output 1.6 → program 2.1: the orange shot, letterboxed (16:9 inside 16:10).
        let o = try await Frames.image(comp, at: 1.6)
        #expect(colorPresence(o, RGBA(1, 0.5, 0), in: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)).fraction > 0.95)
        #expect(colorPresence(o, RGBA(1, 0.5, 0), in: CGRect(x: 0.3, y: 0.0, width: 0.4, height: 0.03)).fraction < 0.05)
        // Output 3.0 → program 3.5: back in the recording (not orange, not blue).
        let r = try await Frames.image(comp, at: 3.0)
        #expect(colorPresence(r, RGBA(1, 0.5, 0), in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)).fraction < 0.01)
        #expect(colorPresence(r, RGBA(0.1, 0.2, 0.9), in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)).fraction < 0.2)
        // Output 6.0 → program 6.5: the blue shot.
        #expect(colorPresence(try await Frames.image(comp, at: 6.0), RGBA(0.1, 0.2, 0.9), in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)).fraction > 0.95)
        // The rendered file has the edit's duration.
        let out = b.rendersURL.appendingPathComponent("t/shots.mp4")
        _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant(name: "t", aspect: .auto, size: 400, fps: 15), to: out)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(d - comp.duration) < 0.12, "exported \(d)")
    }

    @Test func musicBedAndImportedVoiceAreMixed() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("music"), duration: 4)
        let s = GlintService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-aud-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bed = dir.appendingPathComponent("bed.wav"), vo = dir.appendingPathComponent("vo.wav")
        try toneFile(bed, seconds: 1.5, hz: 220)
        try toneFile(vo, seconds: 1, hz: 660, level: 0.5)
        let (m, music) = try await s.importAudio(b, file: bed, kind: .music, at: 0, name: nil)
        let (v, _) = try await s.importAudio(b, file: vo, kind: .voice, at: 1.5, name: nil)
        try Engine(bundle: b).apply([m, v], author: .cli)
        let doc = try b.readDocument()
        #expect(music.loop && music.duckUnderVoice && doc.timeline.audio.count == 2)
        let comp = try await EditComposition.build(bundle: b, document: doc)
        let audio = try await comp.asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 2)
        // The looping bed fills the video exactly and no audio runs past the picture.
        for t in audio { #expect(t.timeRange.end.seconds <= comp.duration + 0.01) }
        let bedTrack = audio.max { $0.timeRange.duration.seconds < $1.timeRange.duration.seconds }!
        #expect(abs(bedTrack.timeRange.end.seconds - comp.duration) < 0.05)
        let out = b.rendersURL.appendingPathComponent("t/music.mp4")
        _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant(name: "t", aspect: .auto, size: 360, fps: 15), to: out)
        let rep = try await RenderInspector.inspect(url: out, expectedDuration: comp.duration)
        #expect(rep.hasAudio && (rep.audio?.integratedLUFS ?? -99) > -40)
    }

    @Test func exportedSubtitlesMatchTheRenderedTimeline() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("subs"), duration: 6)
        let s = GlintService()
        try Engine(bundle: b).apply([EditOperation(.setCaptions, items: [CaptionSegment(start: 0.5, end: 1.5, text: "First line"), CaptionSegment(start: 4, end: 5.5, text: "After the cut")]),
                                     EditOperation(.addCut, start: 2, end: 3.5), EditOperation(.setSpeed, start: 4, end: 6, rate: 2)], author: .cli)
        let (url, n) = try s.exportSubtitles(b, format: .vtt)
        #expect(n == 2)
        let cues = try Subtitles.parse(try String(contentsOf: url, encoding: .utf8))
        let comp = try await EditComposition.build(bundle: b, document: try b.readDocument(), width: 640, height: 400)
        // 4–5.5 s in the recording: after 1.5 s of cut and at 2× → 2.5…3.25 on the output; the movie ends at 3.5.
        #expect(abs(cues[1].start - 2.5) < 0.002 && abs(cues[1].end - 3.25) < 0.002)
        #expect(cues.last!.end <= comp.duration + 0.001)
        // Re-importing it yields the same output cues (round trip through the time map).
        try Engine(bundle: b).apply(try s.importSubtitles(b, file: url), author: .cli)
        #expect(Subtitles.cues(document: try b.readDocument()).map { ($0.start * 100).rounded() } == cues.map { ($0.start * 100).rounded() })
    }
}

@Suite(.serialized) struct JobTests {
    @Test func renderJobCheckpointsCancelsAndResumes() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("job"), duration: 6)
        let s = GlintService()
        // 1. A job that is cancelled mid-render leaves no partial file and no completed stage.
        let (job, _) = try JobRunner.createRender(s, b, variants: ["gif", "preview"], proposal: nil, idempotencyKey: "first", expectedRevision: 0, inspect: true, author: .cli)
        let store = JobStore(bundle: b)
        let runner = Task { await JobRunner.run(s, b, job.id) }
        // Wait until it is really rendering, then ask it to stop.
        for _ in 0..<400 { if (try? store.get(job.id))?.progress ?? 0 > 0.01 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try store.requestCancel(job.id)
        let cancelled = await runner.value
        #expect(cancelled.status == .cancelled, "\(cancelled.status) \(cancelled.error ?? "")")
        #expect(cancelled.stages.allSatisfy { $0.status != .done })
        #expect(!FileManager.default.fileExists(atPath: b.rendersURL.appendingPathComponent("\(job.id)/gif.gif").path))

        // 2. Edits made after the job started don't change what it renders (it works from its snapshot).
        try Engine(bundle: b).apply([.style("cursor.scale", .number(3))], author: .app)
        let retried = await JobRunner.run(s, b, try JobRunner.prepareRetry(b, job.id).id)
        #expect([.succeeded, .needsReview].contains(retried.status), "\(retried.status) \(retried.error ?? "")")
        #expect(retried.revision == 0 && retried.stages.allSatisfy { $0.status == .done && !$0.hashes.isEmpty })
        let gifStage = try #require(retried.stage("render:gif"))
        let mtime = try FileManager.default.attributesOfItem(atPath: b.resolve(gifStage.artifacts[0]).path)[.modificationDate] as? Date

        // 3. A job interrupted after its first stage resumes without redoing it.
        _ = try store.update(job.id) { j in j.status = .running; j.pid = 999_999; j.stages[1].status = .running }
        #expect(try store.get(job.id).status == .interrupted)
        let resumed = await JobRunner.run(s, b, try JobRunner.prepareRetry(b, job.id).id)
        #expect([.succeeded, .needsReview].contains(resumed.status))
        #expect(resumed.stage("render:gif")?.attempts == gifStage.attempts)
        #expect(try FileManager.default.attributesOfItem(atPath: b.resolve(gifStage.artifacts[0]).path)[.modificationDate] as? Date == mtime)
        #expect(FileManager.default.fileExists(atPath: b.rendersURL.appendingPathComponent("\(job.id)/manifest.json").path))

        // 4. A tampered artifact is not trusted: its stage runs again.
        try Data("x".utf8).write(to: b.resolve(gifStage.artifacts[0]))
        _ = try store.update(job.id) { $0.status = .failed }
        let redone = await JobRunner.run(s, b, try JobRunner.prepareRetry(b, job.id).id)
        #expect(redone.stage("render:gif")!.attempts == gifStage.attempts + 1)

        // 5. Idempotency and revision guards: the same key returns the same job; reusing it for different work
        //    (here: the project moved on to another revision) is refused rather than silently replaced.
        #expect(throws: JobError.self) { _ = try JobRunner.createRender(s, b, variants: ["gif", "preview"], proposal: nil, idempotencyKey: "first", expectedRevision: nil, inspect: true, author: .cli) }
        let (k1, existed1) = try JobRunner.createRender(s, b, variants: ["preview"], proposal: nil, idempotencyKey: "second", expectedRevision: nil, inspect: false, author: .cli)
        let (k2, existed2) = try JobRunner.createRender(s, b, variants: ["preview"], proposal: nil, idempotencyKey: "second", expectedRevision: nil, inspect: false, author: .cli)
        #expect(!existed1 && existed2 && k1.id == k2.id)
        #expect(throws: EditError.self) { _ = try JobRunner.createRender(s, b, variants: ["preview"], proposal: nil, idempotencyKey: nil, expectedRevision: 0, inspect: true, author: .cli) }
    }

    @Test func productionJobNeverPassesAnUncheckedDraft() async throws {
        let b = try await SyntheticProject.make(at: fixtureURL("prod"), duration: 6)
        let s = GlintService()
        // Two very short zooms: a repairable problem.
        try Engine(bundle: b).apply([EditOperation(.addZoom, start: 1.5, end: 2.0, scale: 2), EditOperation(.addZoom, start: 3, end: 3.6, scale: 2)], author: .cli)
        let (job, _) = try JobRunner.createProduction(s, b, variant: "gif", repair: true, maxAttempts: 2, targetDuration: nil, idempotencyKey: nil, expectedRevision: 1, author: Author(.agent, "test"))
        let done = await JobRunner.run(s, b, job.id)
        #expect(done.stage("repair")?.detail?.contains("lengthened") == true, "\(done.stage("repair")?.detail ?? "")")
        let zooms = try b.readDocument().timeline.zooms
        #expect(zooms.allSatisfy { $0.end - $0.start >= 1.2 })
        #expect(Engine(bundle: b).history().last?.author == Author(.agent, "test"))   // repairs are attributed, undoable transactions
        // No recipe: what the video demonstrates is unchecked, so it is not "succeeded".
        #expect(done.status == .needsReview)
        #expect(done.review.contains { $0.contains("No recipe") })
    }
}

@Suite(.serialized) struct RecipeWorkflowTests {
    /// The agent-native loop end to end with fixtures: recipe → recording with scene markers → bind shots →
    /// evidence (OCR + reported assertions; a click doesn't count) → a product change → re-record one scene →
    /// refresh it from the new take, keeping manual edits elsewhere → evidence resets for the refreshed scene.
    @Test func recordBindVerifyRefresh() async throws {
        let s = GlintService()
        let b = try await SyntheticProject.make(at: fixtureURL("recipe"), duration: 9)
        // OCR checks the rendered frame: keep the cursor from obscuring the button label being asserted.
        try Engine(bundle: b).apply([EditOperation(.addMarker, time: 0, text: "scene:save"), EditOperation(.addMarker, time: 2.5, text: "scene:search"),
                                     .style("cursor.visible", .bool(false))], author: Author(.agent, "driver"))
        let recipe = DemoRecipe(title: "Save and search", audience: "first-time admins", scenes: [
            RecipeScene(id: "save", title: "Save the report", steps: ["click Save"], expectations: [RecipeExpectation(id: "saved", description: "Save confirms", kind: .visibleText, text: "Saved")]),
            RecipeScene(id: "search", title: "Search customers", steps: ["type the query"], expectations: [
                RecipeExpectation(id: "query", description: "Query shown", kind: .visibleText, text: "EMEA"),
                RecipeExpectation(id: "results", description: "Results come back from the API", kind: .state)]),
        ])
        let saved = try s.saveRecipe(b, recipe)
        #expect(saved.version == 1)

        // Bind: one shot per scene.
        let (bindOps, ranges) = try s.recipeBindOps(b)
        #expect(ranges.map(\.scene) == ["save", "search"])
        try Engine(bundle: b).apply(bindOps, author: Author(.agent, "driver"))
        var doc = try b.readDocument()
        #expect(doc.effectiveClips.map(\.scene) == ["save", "search"] && doc.duration == 9)

        // Manual edits in both scenes.
        try Engine(bundle: b).apply([EditOperation(.addZoom, id: "zsearch", start: 3, end: 5, scale: 2, origin: "manual"),
                                     EditOperation(.addAnnotation, id: "note", item: .object(["kind": .string("box"), "start": .number(0.5), "end": .number(1.5),
                                                                                              "rect": .object(["x": .number(0.7), "y": .number(0.05), "width": .number(0.25), "height": .number(0.12)])]))],
                                    author: .app)

        // Evidence: the driver's click is not proof; the API assertion is.
        let click = try s.recordEvidence(b, EvidenceRecord(scene: "search", expectation: "results", status: .verified, source: .action, detail: "pressed Enter", author: Author(.agent, "driver")))
        #expect(click.status == .needsReview && click.take == "primary")
        var report = try await s.verifyRecipe(b, author: Author(.agent, "driver"))
        #expect(report.items.first { $0.expectation == "saved" }?.status == .verified, "\(report.items)")
        #expect(report.items.first { $0.expectation == "query" }?.status == .verified, "\(report.items)")
        #expect(report.status == .needsReview)
        _ = try s.recordEvidence(b, EvidenceRecord(scene: "search", expectation: "results", status: .verified, source: .assertion,
                                                   detail: "GET /api/search?q=EMEA → 200", observed: "12 results", author: Author(.agent, "driver")))
        report = try await s.verifyRecipe(b, author: Author(.agent, "driver"))
        #expect(report.status == .verified, "\(report.summary)")

        // The product changed: the driver records the save scene again, as a new take with its own marker and evidence.
        let takeURL = fixtureURL("take")
        let teal = RGBA(0.1, 0.6, 0.6)
        var takeDoc = ProjectDocument(name: "take", media: MediaInfo(screen: "media/screen.mov", width: 1280, height: 800, scale: 2, duration: 3.5, frameRate: 15))
        takeDoc.timeline.markers = [Marker(time: 0.5, note: "scene:save", author: Author(.agent, "driver"))]
        var takeEvents = EventLog()
        takeEvents.clicks = [ClickEvent(t: 1.5, x: 0.5, y: 0.5, button: .left)]
        let take = try ProjectBundle.create(at: takeURL, document: takeDoc, events: takeEvents)
        try await solidMovie(take.mediaURL.appendingPathComponent("screen.mov"), color: teal, duration: 3.5)
        _ = try s.saveRecipe(take, saved)
        try Engine(bundle: take).apply([EditOperation(.updateClip, id: MediaClip.primaryID, scene: "save")], author: .cli)
        _ = try s.recordEvidence(take, EvidenceRecord(scene: "save", expectation: "saved", status: .verified, source: .assertion,
                                                     detail: "PUT /reports/1 → 200", observed: "saved", author: Author(.agent, "driver")))

        let rev = try b.readDocument().revision
        let refresh = try s.refreshScene(b, scene: "save", take: take, range: nil, author: Author(.agent, "driver"), expectedRevision: rev, apply: true)
        #expect(refresh.range == TimeRange(0.5, 3.5) && refresh.importedEvidence == 1)
        #expect(refresh.retimedProportionally.contains("note"))
        doc = try b.readDocument()
        #expect(doc.effectiveClips.map(\.scene) == ["save", "search"] && doc.effectiveClips[0].take == takeDoc.id)
        #expect(abs(doc.duration - (3.0 + 6.5)) < 1e-6)
        // The manual zoom in the untouched scene still shows the same content: shifted by the change in length.
        let z = try #require(doc.timeline.zooms.first { $0.id == "zsearch" })
        #expect(abs(z.start - 3.5) < 1e-6 && abs(z.end - 5.5) < 1e-6)
        // The picture is the new take; the take's input events drive the cursor in that shot.
        try Engine(bundle: b).apply(fullBleed, author: .app)
        doc = try b.readDocument()
        #expect(colorPresence(try await frame(b, doc, at: 1.0), teal, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)).fraction > 0.95)
        #expect(colorPresence(try await frame(b, doc, at: 4.5), teal, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)).fraction < 0.05)
        #expect(b.programEvents(for: doc).clicks.contains { abs($0.t - 1.0) < 1e-6 })
        // Evidence: the old take's OCR no longer counts; the take's assertion does. The teal take shows no "Saved",
        // so OCR leaves it for review rather than failing it — and the take's API assertion verifies it.
        report = try await s.verifyRecipe(b, author: Author(.agent, "driver"))
        let savedItem = try #require(report.items.first { $0.expectation == "saved" })
        #expect(savedItem.status == .verified && savedItem.reason.hasPrefix("assertion"), "\(savedItem)")
        #expect(report.scenes.first { $0.scene == "save" }?.take != "primary")
        #expect(report.items.first { $0.expectation == "results" }?.status == .verified)

        // One undo restores the original scene.
        try Engine(bundle: b).undo(author: .app)   // fullBleed
        try Engine(bundle: b).undo(author: .app)   // refresh
        doc = try b.readDocument()
        #expect(doc.duration == 9 && doc.effectiveClips[0].take == nil)
        #expect(doc.timeline.zooms.first { $0.id == "zsearch" }?.start == 3)
    }
}
