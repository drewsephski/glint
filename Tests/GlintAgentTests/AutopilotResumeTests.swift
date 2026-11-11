import Foundation
import Testing
import GlintCore
@testable import GlintAgent

@Suite(.serialized) struct AutopilotResumeTests {
    @Test func offlineRunPersistsAndDoesNotRepeatFinishedStages() async throws {
        let b = try await SyntheticProject.make(at: FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID()).glint"), duration: 2, width: 640, height: 400, fps: 15)
        defer { try? FileManager.default.removeItem(at: b.url) }
        let context = ToolContext(author: .app, service: GlintService())
        _ = try await Autopilot.run(b, args: .object(["narrate": .bool(false)]), context: context)
        let store = JobStore(bundle: b)
        let first = try #require(store.list().first { $0.kind == .autopilot })
        #expect(first.status.isTerminal)
        #expect(first.stages.map(\.name) == Autopilot.stages)
        _ = try await Autopilot.run(b, args: .object(["run_id": .string(first.id)]), context: context)
        let second = try store.get(first.id)
        #expect(store.list().count == 1)
        for stage in first.stages where !["quality", "evidence"].contains(stage.name) {
            #expect(second.stage(stage.name)?.attempts == stage.attempts)
        }
        #expect(second.id == first.id)
    }
}

extension AutopilotResumeTests {
    @Test func lockedNarrationAllowsOnlyAppChanges() throws {
        let doc = ProjectDocument(name: "Lock", media: MediaInfo(screen: "screen.mov", width: 640, height: 400, scale: 1, duration: 10, frameRate: 30))
        let b = try ProjectBundle.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID()).glint"), document: doc, events: EventLog())
        defer { try? FileManager.default.removeItem(at: b.url) }
        let service = GlintService()
        _ = try service.saveRecipe(b, DemoRecipe(title: "Locked", scenes: [RecipeScene(id: "s", title: "Scene", locked: true)]))
        try b.writeStoryboard(Storyboard(revision: 0, scenes: [Scene(id: "s", start: 0, end: 10, title: "Scene", narration: "Original")]))
        #expect(throws: ServiceError.self) { try service.setNarration(b, lines: ["s": "Changed"], author: Author(.agent, "test")) }
        #expect(try service.setNarration(b, lines: ["s": "Changed"], author: .app).scenes[0].narration == "Changed")
    }
}
