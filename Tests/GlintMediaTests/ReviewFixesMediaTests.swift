import CoreGraphics
import CoreImage

import Foundation
import Testing
import GlintCore
@testable import GlintRender
import GlintAnalysis

@Suite struct ReviewFixesMediaTests {
    @Test func currentExportMatchesPreview() throws {
        let current = try #require(RenderVariant.preset("current"))
        for aspect in [Aspect.auto, .classic, .square] {
            var doc = ProjectDocument(name: "Aspect", media: MediaInfo(screen: "media/screen.mov", width: 800, height: 600, scale: 1, duration: 10, frameRate: 30))
            doc.style.canvas.aspect = aspect
            #expect(try current.resolve(doc) == doc)
            let output = current.output(for: doc)
            let size = RenderPlan.outputSize(document: doc, height: current.size)
            #expect(output.width == size.0 && output.height == size.1)
            #expect(output.estimatedBytes > 0)
            let landscape = try #require(RenderVariant.preset("landscape"))
            #expect(!landscape.preservesComposition(of: doc))
            #expect(try landscape.resolve(doc).style.canvas.aspect == .landscape)
            #expect(RenderVariant.presets["gif"]!.output(for: doc).estimatedBytes < RenderVariant.presets["prores"]!.output(for: doc).estimatedBytes)
        }
    }
    @Test func missingNarrationAndMutedTracks() async throws {
        var doc = ProjectDocument(name: "Missing", media: MediaInfo(screen: "media/screen.mov", width: 800, height: 600, scale: 1, duration: 10, frameRate: 30))
        doc.media.microphone = "media/missing.wav"
        doc.style.audio.muteMicrophone = true
        doc.timeline.cuts = [Cut(start: 1, end: 3)]
        doc.timeline.voiceover = [VoiceoverClip(start: 4, path: "media/voice.wav", text: "Create", duration: 2, scene: "create")]
        let b = try ProjectBundle.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID()).glint"), document: doc, events: EventLog())
        defer { try? FileManager.default.removeItem(at: b.url) }
        try b.writeStoryboard(Storyboard(revision: 0, scenes: [Scene(id: "create", start: 4, end: 6, title: "Create your first project")]))
        let problems = await MediaPreflight.check(bundle: b, document: doc)
        #expect(problems.contains { $0.kind == .voiceover && $0.blocking && $0.message.contains("Create your first project") })
        #expect(!problems.contains { $0.kind == .microphone })
        #expect(MediaPreflight.expectedSpeech(document: doc) == [TimeRange(2, 4)])
        do {
            _ = try await Exporter.export(bundle: b, document: doc, variant: RenderVariant.presets["current"]!, to: b.url.appendingPathComponent("out.mp4"))
            Issue.record("Missing media exported")
        } catch RenderError.mediaProblems(let issues) { #expect(issues.contains { $0.kind == .voiceover }) }
        doc.style.audio.muteVoiceover = true
        #expect(MediaPreflight.expectedSpeech(document: doc).isEmpty)
        #expect(await MediaPreflight.check(bundle: b, document: doc).allSatisfy { $0.kind != .voiceover })
    }
}

extension ReviewFixesMediaTests {
    @Test func narrationBudgetsRespectTargetOverridesAndLocks() {
        let doc = ProjectDocument(name: "Budget", media: MediaInfo(screen: "screen.mov", width: 800, height: 600, scale: 1, duration: 20, frameRate: 30))
        let sb = Storyboard(revision: 0, scenes: [Scene(id: "a", start: 0, end: 10, title: "A", narration: "Keep me"), Scene(id: "b", start: 10, end: 20, title: "B")])
        var options = NarrationOptions(); options.targetDuration = 10; options.keepScenes = ["a"]
        let budgets = Narrator.wordBudgets(storyboard: sb, document: doc, options: options)
        #expect(abs(Double(budgets.values.reduce(0, +)) - 9.1 * options.wordsPerSecond) <= 1)
        #expect(options.keeps(sb.scenes[0]) && !options.keeps(sb.scenes[1]))
        options.targetDuration = 0.1
        #expect(Narrator.wordBudgets(storyboard: sb, document: doc, options: options).values.allSatisfy { $0 >= Narrator.minimumWords })
        options.sceneWordBudgets = ["a": 17]
        #expect(Narrator.wordBudgets(storyboard: sb, document: doc, options: options)["a"] == 17)
    }
}

extension ReviewFixesMediaTests {
    @Test func inspectorDetectsSilentExpectedSpeech() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for audible in [false, true] {
            let url = dir.appendingPathComponent(audible ? "tone.wav" : "silence.wav")
            try toneFile(url, seconds: 2, level: audible ? 0.3 : 0)
            let report = try await RenderInspector.inspect(url: url, expectedSpeech: [TimeRange(0.2, 1.8)])
            let check = try #require(report.quality.checks.first { $0.id == "narration_present" })
            #expect(check.verdict == (audible ? .pass : .fail))
        }
    }
}

extension ReviewFixesMediaTests {
    @Test func privacySolidMaskChangesOnlyItsRectangle() throws {
        let context = CIContext()
        let image = try #require(context.createCGImage(CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)), from: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let mask = Redaction(start: 0, end: 1, rect: NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), mode: .solid, color: RGBA(1, 0, 0))
        let result = try SceneAnalyzer.mask(image, with: [mask])
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: result), toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes
        }
        #expect(pixel(50, 50) == [255, 0, 0, 255])
        #expect(pixel(10, 10) == [255, 255, 255, 255])
    }
}
