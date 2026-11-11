import Foundation
import Testing
@testable import GlintCore

@Suite struct ReviewFixesCoreTests {
    let words = [CaptionWord(text: "hello", start: 1, end: 2), CaptionWord(text: "wrld", start: 4, end: 5)]
    @Test func captionMoveResizeAndCorrections() {
        let moved = CaptionRetimer.retime(words, from: TimeRange(0, 6), to: TimeRange(3, 9))
        #expect(moved.map(\.start) == [4, 7])
        #expect(moved.map(\.end) == [5, 8])
        let scaled = CaptionRetimer.retime(words, from: TimeRange(0, 6), to: TimeRange(0, 12))
        #expect(scaled.map(\.start) == [2, 8])
        #expect(scaled.map(\.end) == [4, 10])
        let fixed = CaptionRetimer.align(words, to: "Hello, world!", in: TimeRange(0, 6))
        #expect(fixed.map(\.start) == words.map(\.start))
        #expect(fixed.map(\.end) == words.map(\.end))
        let inserted = CaptionRetimer.align(words, to: "hello brave new wrld", in: TimeRange(0, 6))
        #expect(inserted.map(\.start) == [1, 2, 3, 4])
        #expect(inserted.map(\.end) == [2, 3, 4, 5])
    }
    @Test func cutBoundaryUsesEarlierEndAndLaterStart() {
        let map = TimeMap(kept: TimeRange(0, 10), cuts: [TimeRange(3, 6)], speeds: [])
        #expect(map.sourceEnd(forOutput: 3) == 3)
        #expect(map.source(forOutput: 3) == 6)
        #expect(map.sourceSpan(forOutput: TimeRange(1, 3)) == TimeRange(1, 3))
        #expect(!map.isVisible(TimeRange(3, 6)))
        #expect(map.isVisible(TimeRange(2, 4)))
    }
    @Test func waitingJobSurvivesDeadOwnerAndRetry() throws {
        let b = try tempBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        let store = JobStore(bundle: b)
        var job = Job(kind: .autopilot, idempotencyKey: nil, params: .object([:]), revision: 0, stages: ["voiceover"], author: .app)
        job.status = .waitingApproval; job.pid = 999_999
        job.stages[0].status = .waitingApproval; job.stages[0].approvalID = "approval"
        try store.save(job)
        #expect(!job.status.isTerminal && !job.status.isActive && job.status.isResumable)
        #expect(try store.get(job.id).status == .waitingApproval)
        let retry = try store.prepareRetry(job.id)
        #expect(retry.status == .queued)
        #expect(retry.stages[0].approvalID == "approval")
    }
}

extension ReviewFixesCoreTests {
    @Test func approvalsRemainActionScopedAndConsumedRequestsRefresh() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ApprovalStore(directory: dir)
        func request(_ action: String, _ candidates: [String]) throws -> ApprovalRequest {
            do {
                try store.authorize(action: action, risk: .external, summary: action, parameters: .object([:]), author: Author(.agent, "test"), candidates: candidates)
                throw CocoaError(.fileReadUnknown)
            } catch ApprovalError.required(let r) { return r }
        }
        let script = try request("write_narration", [])
        #expect(store.pick([script.id], for: "voiceover") == nil)
        let voice = try request("voiceover", [script.id])
        #expect(voice.id != script.id && voice.action == "voiceover")
        _ = try store.decide(voice.id, approve: true, by: "test")
        try store.authorize(action: "voiceover", risk: .external, summary: "voiceover", parameters: .object([:]), author: Author(.agent, "test"), candidates: [voice.id])
        #expect(try request("voiceover", [voice.id]).id != voice.id)
    }
    @Test func tighterCutsAreBoundedAndMonotonic() {
        for level in 1...10 {
            let before = CutPlanOptions.tightened(level - 1), after = CutPlanOptions.tightened(level)
            #expect(after.padding >= 0.15 && after.padding <= before.padding)
            #expect(after.minSilence <= before.minSilence)
            #expect(after.activityRate >= before.activityRate && after.activityRate <= 6)
            #expect(after.idleRate >= before.idleRate && after.idleRate <= 8)
        }
    }
    @Test func productionControlsDoNotInvalidateRecipeEvidence() {
        var recipe = DemoRecipe(title: "Demo", scenes: [RecipeScene(id: "s", title: "Scene")])
        let fingerprint = EvidenceContext.recipeFingerprint(recipe)
        recipe.scenes[0].locked = true
        recipe.scenes[0].targetDuration = 8
        recipe.targetDuration = 20
        #expect(EvidenceContext.recipeFingerprint(recipe) == fingerprint)
    }
}

extension ReviewFixesCoreTests {
    @Test func captionOperationsPreserveWordSpacing() throws {
        var doc = makeDoc()
        doc.timeline.captions = [CaptionSegment(id: "c", start: 0, end: 6, text: "hello wrld", words: words)]
        let moved = try OperationApplier.apply([EditOperation(.updateCaption, id: "c", start: 3, end: 9)], to: doc)
        #expect(moved.timeline.captions[0].words.map(\.start) == [4, 7])
        let unchanged = try OperationApplier.apply([EditOperation(.updateCaption, id: "c", text: "hello wrld")], to: doc)
        #expect(unchanged.timeline.captions[0].words == words)
    }
    @Test func movingPrivacyMaskInvalidatesStoryboard() {
        var doc = makeDoc()
        doc.timeline.redactions = [Redaction(start: 0, end: 5, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        var sb = Storyboard(revision: 0, scenes: [])
        sb.maskHash = PrivacyMasks.hash(doc.timeline.redactions)
        #expect(sb.masksCurrent(for: doc))
        doc.timeline.redactions[0].rect.x += 0.1
        #expect(!sb.masksCurrent(for: doc))
    }
}

extension ReviewFixesCoreTests {
    @Test func importedTranscriptMovesToProgramPosition() throws {
        var doc = makeDoc()
        doc.timeline.clips = [MediaClip(name: "primary", path: doc.media.screen, mediaEnd: 5, primary: true, width: 800, height: 600), MediaClip(name: "import", path: "import.mov", mediaStart: 2, mediaEnd: 6, audio: ["import.wav"], width: 800, height: 600)]
        let primary = Transcript(engine: "fixture", locale: "en", source: "primary", words: [CaptionWord(text: "first", start: 1, end: 2)])
        let shot = Transcript(engine: "fixture", locale: "en", source: "import.wav", words: [CaptionWord(text: "imported", start: 3, end: 4)])
        let merged = try #require(Transcript.program(document: doc, primary: primary, shots: ["import.wav": shot]))
        #expect(merged.words.map(\.text) == ["first", "imported"])
        #expect(merged.words.map(\.start) == [1, 6])
        #expect(merged.words.map(\.end) == [2, 7])
    }
}
