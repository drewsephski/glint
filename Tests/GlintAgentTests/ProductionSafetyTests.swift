import Foundation
import Testing
@testable import GlintCore
@testable import GlintAgent

@Suite(.serialized) struct ProductionSafetyTests {
    private func project() async throws -> ProjectBundle {
        try await SyntheticProject.make(at: FileManager.default.temporaryDirectory.appendingPathComponent("glint-production-safety-\(UUID().uuidString).glint"), duration: 2, width: 640, height: 400, fps: 15)
    }

    private func recipe() -> DemoRecipe {
        DemoRecipe(title: "Outcome", scenes: [RecipeScene(id: "result", title: "Result", expectations: [RecipeExpectation(id: "saved", description: "Saved state")])])
    }

    @Test func productionRetryKeepsFailingSnapshotQuality() async throws {
        let bundle = try await project()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let service = GlintService()
        _ = try service.saveRecipe(bundle, recipe())
        try Engine(bundle: bundle).apply([EditOperation(.updateClip, id: MediaClip.primaryID, scene: "result")], author: .cli)
        _ = try service.recordEvidence(bundle, EvidenceRecord(scene: "result", expectation: "saved", status: .verified, source: .assertion, detail: "API", observed: "saved", author: .cli))
        let (job, _) = try JobRunner.createProduction(service, bundle, variant: "preview", repair: false, maxAttempts: 0,
                                                     targetDuration: 30, idempotencyKey: nil, expectedRevision: nil, author: .cli)
        let first = await JobRunner.run(service, bundle, job.id)
        #expect(first.status == .needsReview, "\(first.error ?? first.message ?? "")")
        #expect(first.review.contains { $0.hasPrefix("Edit:") && $0.contains("target") })
        _ = try JobRunner.prepareRetry(bundle, job.id)
        let retried = await JobRunner.run(service, bundle, job.id)
        #expect(retried.status == .needsReview)
        #expect(retried.review.contains { $0.hasPrefix("Edit:") && $0.contains("target") })
        #expect(retried.stage("render:preview")?.attempts == first.stage("render:preview")?.attempts)
        // Losing the inspection sidecar must trigger another measurement, never turn a failing checkpoint green.
        let reportPath = try #require(retried.stage("render:preview")?.artifacts.first { $0.hasSuffix(".report.json") })
        try FileManager.default.removeItem(at: bundle.resolve(reportPath))
        _ = try JobRunner.prepareRetry(bundle, job.id)
        let measuredAgain = await JobRunner.run(service, bundle, job.id)
        #expect(measuredAgain.status == .needsReview)
        #expect(measuredAgain.stage("render:preview")?.attempts == (retried.stage("render:preview")?.attempts ?? 0) + 1)
    }

    @Test func productionDoesNotCertifyLaterLiveEditsOrRecipe() async throws {
        let bundle = try await project()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let service = GlintService()
        let originalRecipe = try service.saveRecipe(bundle, recipe())
        let original = try bundle.readDocument() // The exported snapshot has no bound scene.
        let (job, _) = try JobRunner.createProduction(service, bundle, variant: "preview", repair: false, maxAttempts: 0,
                                                     targetDuration: nil, idempotencyKey: nil, expectedRevision: nil, author: .cli)
        try Engine(bundle: bundle).apply([EditOperation(.updateClip, id: MediaClip.primaryID, scene: "result")], author: .cli)
        _ = try service.recordEvidence(bundle, EvidenceRecord(scene: "result", expectation: "saved", status: .verified, source: .assertion, detail: "API", observed: "saved", author: .cli))
        #expect(try await service.verifyRecipe(bundle, author: .cli, ocr: false).status == .verified)
        let done = await JobRunner.run(service, bundle, job.id)
        #expect(done.status == .needsReview, "\(done.error ?? done.message ?? "")")
        #expect(done.review.contains { $0.contains("not in the rendered edit") })
        #expect(done.revision == original.revision)
        let snapshotReport = try await service.verifyRecipe(bundle, author: .cli, ocr: false, document: original, recipe: originalRecipe)
        #expect(snapshotReport.status == .needsReview)
    }

    @Test func unboundOptionalSceneStillGatesProduction() async throws {
        let bundle = try await project()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let service = GlintService()
        _ = try service.saveRecipe(bundle, DemoRecipe(title: "Missing scene", scenes: [RecipeScene(id: "missing", title: "Missing")]))
        let (job, _) = try JobRunner.createProduction(service, bundle, variant: "preview", repair: false, maxAttempts: 0,
                                                     targetDuration: nil, idempotencyKey: nil, expectedRevision: nil, author: .cli)
        let done = await JobRunner.run(service, bundle, job.id)
        #expect(done.status == .needsReview)
        #expect(done.review.contains { $0 == "Evidence missing: scene is not in the rendered edit" })
    }

    @Test func recipeChangesInvalidatePreviouslyRecordedAssertions() async throws {
        let bundle = try await project()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let service = GlintService()
        var recipe = try service.saveRecipe(bundle, recipe())
        try Engine(bundle: bundle).apply([EditOperation(.updateClip, id: MediaClip.primaryID, scene: "result")], author: .cli)
        _ = try service.recordEvidence(bundle, EvidenceRecord(scene: "result", expectation: "saved", status: .verified, source: .assertion, detail: "API", observed: "saved", author: .cli))
        #expect(try await service.verifyRecipe(bundle, author: .cli, ocr: false).status == .verified)
        recipe.scenes[0].expectations[0].description = "Deleted state"
        _ = try service.saveRecipe(bundle, recipe)
        #expect(try await service.verifyRecipe(bundle, author: .cli, ocr: false).status == .needsReview)
    }
    @Test func ocrRechecksRecipeAndRedactedRenderedFrames() async throws {
        let bundle = try await SyntheticProject.make(at: FileManager.default.temporaryDirectory.appendingPathComponent("glint-ocr-safety-\(UUID().uuidString).glint"), duration: 2, fps: 15)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let service = GlintService()
        var recipe = DemoRecipe(title: "Visible title", scenes: [RecipeScene(id: "result", title: "Result", expectations: [
            RecipeExpectation(id: "title", description: "Visible heading", kind: .visibleText, text: "Quarterly revenue"),
        ])])
        recipe = try service.saveRecipe(bundle, recipe)
        try Engine(bundle: bundle).apply([EditOperation(.updateClip, id: MediaClip.primaryID, scene: "result")], author: .cli)
        #expect(try await service.verifyRecipe(bundle, author: .cli).status == .verified)
        // Even with matching cached OCR, an unreadable output cannot inherit the editor frame's verification.
        let missingOutput = bundle.rendersURL.appendingPathComponent("missing.mp4")
        #expect(try await service.verifyRecipe(bundle, author: .cli, renderedURL: missingOutput).status == .needsReview)
        recipe.scenes[0].expectations[0].text = "Not anywhere on this screen"
        recipe = try service.saveRecipe(bundle, recipe)
        #expect(try await service.verifyRecipe(bundle, author: .cli).status == .needsReview)
        recipe.scenes[0].expectations[0].text = "Quarterly revenue"
        _ = try service.saveRecipe(bundle, recipe)
        #expect(try await service.verifyRecipe(bundle, author: .cli).status == .verified)
        try Engine(bundle: bundle).apply([EditOperation(.addRedaction, item: .object([
            "start": .number(0), "end": .number(2), "mode": .string("solid"),
            "rect": .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)]),
        ]))], author: .cli)
        #expect(try await service.verifyRecipe(bundle, author: .cli).status == .needsReview)
    }

}
