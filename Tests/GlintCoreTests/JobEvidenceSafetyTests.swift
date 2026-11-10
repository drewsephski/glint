import Foundation
import Testing
@testable import GlintCore

@Suite struct JobEvidenceSafetyTests {
    private func document() throws -> ProjectDocument {
        let doc = ProjectDocument(name: "safety", media: MediaInfo(screen: "media/screen.mov", width: 1280, height: 800, scale: 2, duration: 10, frameRate: 30))
        return try OperationApplier.apply([
            EditOperation(.splitClip, id: "second", time: 5),
            EditOperation(.updateClip, id: MediaClip.primaryID, scene: "intro"),
            EditOperation(.updateClip, id: "second", scene: "result"),
        ], to: doc)
    }

    private func recipe() -> DemoRecipe {
        DemoRecipe(title: "safety", scenes: [RecipeScene(id: "result", title: "Result", expectations: [
            RecipeExpectation(id: "saved", description: "Data saved", kind: .visibleText, text: "Saved"),
        ])])
    }

    @Test func legacyAndChangedExpectationsCannotVerify() throws {
        let doc = try document()
        let recipe = recipe()
        let raw = EvidenceRecord(scene: "result", expectation: "saved", status: .verified, source: .assertion,
                                 detail: "API returned saved", observed: "saved", take: "primary", author: .cli)
        let legacy = try JSONCoding.decoder.decode(EvidenceRecord.self, from: JSONCoding.encoder.encode(raw))
        #expect(RecipeReport.evaluate(recipe: recipe, document: doc, evidence: EvidenceLog(records: [legacy])).status == .needsReview)
        let checked = raw.bound(to: recipe, document: doc)
        #expect(RecipeReport.evaluate(recipe: recipe, document: doc, evidence: EvidenceLog(records: [checked])).status == .verified)
        var changed = recipe
        changed.scenes[0].expectations[0].text = "Deleted"
        // Even hand edits that forget to bump the version invalidate the old result.
        #expect(RecipeReport.evaluate(recipe: changed, document: doc, evidence: EvidenceLog(records: [checked])).status == .needsReview)
    }

    @Test func cutOrTrimInvalidatesEvidenceButAnUnchangedMovedSceneKeepsIt() throws {
        let doc = try document(), recipe = recipe()
        let evidence = EvidenceRecord(scene: "result", expectation: "saved", status: .verified, source: .assertion,
                                      detail: "API result", observed: "saved", take: "primary", author: .cli).bound(to: recipe, document: doc)
        let log = EvidenceLog(records: [evidence])
        let cut = try OperationApplier.apply([EditOperation(.addCut, start: 5, end: 10)], to: doc)
        let report = RecipeReport.evaluate(recipe: recipe, document: cut, evidence: log)
        #expect(report.status == .needsReview && report.scenes.first?.inEdit == false)
        let partial = try OperationApplier.apply([EditOperation(.addCut, start: 8, end: 10)], to: doc)
        #expect(RecipeReport.evaluate(recipe: recipe, document: partial, evidence: log).status == .needsReview)
        var moved = doc
        moved.timeline.clips.reverse()
        #expect(RecipeReport.evaluate(recipe: recipe, document: moved, evidence: log).status == .verified)
    }

    @Test func onlyOneContendingRunnerCanClaimAndCancelRetryIsAtomic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-claim-\(UUID().uuidString).glint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document()
        let bundle = try ProjectBundle.create(at: dir, document: doc, events: EventLog())
        let store = JobStore(bundle: bundle)
        let (job, _) = try store.create(Job(kind: .render, idempotencyKey: "once", params: .null, revision: 0, stages: ["render:preview"], author: .cli), document: doc)
        let claims = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 { group.addTask { (try? store.claim(job.id).claimed) ?? false } }
            var claimed = 0
            for await success in group { if success { claimed += 1 } }
            return claimed
        }
        #expect(claims == 1)
        #expect(try store.get(job.id).attempts == 1)
        #expect(throws: JobError.self) { _ = try store.prepareRetry(job.id) }
        #expect(try store.requestCancel(job.id).status == .running)
        #expect(store.isCancelRequested(job.id))
        _ = try store.update(job.id) { $0.status = .cancelled }
        let retry = try store.prepareRetry(job.id)
        #expect(retry.status == .queued && retry.pid == nil && !store.isCancelRequested(job.id))
        #expect(try store.requestCancel(job.id).status == .cancelled)
        #expect(try !store.claim(job.id).claimed)
        #expect(throws: JobError.self) { _ = try store.get("../../project") }
    }

    @Test func idempotentCreationPublishesTheSnapshotBeforeTheJob() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-create-\(UUID().uuidString).glint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document()
        let bundle = try ProjectBundle.create(at: dir, document: doc, events: EventLog())
        let store = JobStore(bundle: bundle)
        let ids = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let (job, _) = try store.create(Job(kind: .render, idempotencyKey: "shared", params: .null, revision: doc.revision, stages: ["render:preview"], author: .cli), document: doc)
                    let snapshot = try JSONCoding.decoder.decode(ProjectDocument.self, from: Data(contentsOf: store.snapshotURL(job.id)))
                    #expect(snapshot.timeline == doc.timeline && snapshot.style == doc.style && snapshot.revision == doc.revision)
                    return job.id
                }
            }
            var results: [String] = []
            for try await id in group { results.append(id) }
            return results
        }
        #expect(Set(ids).count == 1)
    }
}
