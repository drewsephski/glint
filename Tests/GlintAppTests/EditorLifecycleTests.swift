import Foundation
import GlintAgent
import GlintCore
import Testing

@testable import GlintApp

@MainActor @Suite struct EditorLifecycleTests {
    private func makeEditor() throws -> EditorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = ProjectDocument(name: "Test", media: MediaInfo(screen: "screen.mov", width: 100, height: 100, scale: 1, duration: 5, frameRate: 30))
        let bundle = try ProjectBundle.create(at: directory, document: document, events: EventLog())
        return try EditorModel(bundle: bundle, service: GlintService())
    }

    @Test func cancellingOrClosingStopsForegroundWorkAndIgnoresLateProgress() async throws {
        for close in [false, true] {
            let model = try makeEditor()
            defer {
                model.close()
                try? FileManager.default.removeItem(at: model.bundle.url)
            }
            var started = false
            var finished = false
            var secondStarted = false
            model.runOperation("Working") {
                started = true
                try await Task.sleep(nanoseconds: 60_000_000_000)
                finished = true
            }
            let progress = model.progressSink()
            model.runOperation("Duplicate") { secondStarted = true }
            let deadline = Date().addingTimeInterval(3)
            while !started, Date() < deadline { await Task.yield() }
            #expect(started)
            if close { model.close() } else { model.cancelOperation() }
            while model.busy != nil, Date() < deadline { await Task.yield() }
            progress("Stale result")
            await Task.yield()
            #expect(model.busy == nil)
            #expect(!finished)
            #expect(!secondStarted)
            if close {
                model.runOperation("After close") { secondStarted = true }
                await Task.yield()
                #expect(!secondStarted)
            }
        }
    }

    @Test func scriptUndoRefreshesEditorAndSurvivesReopening() throws {
        let model = try makeEditor()
        defer {
            model.close()
            try? FileManager.default.removeItem(at: model.bundle.url)
        }
        try model.bundle.writeStoryboard(Storyboard(revision: 0, scenes: [Scene(id: "s1", start: 0, end: 5, title: "First", narration: "Before")]))
        model.setNarration("s1", "After")
        #expect(model.canUndo)
        #expect(model.storyboard?.scenes.first?.narration == "After")
        model.undo()
        #expect(model.storyboard?.scenes.first?.narration == "Before")
        #expect(model.canRedo)
        model.redo()
        #expect(model.storyboard?.scenes.first?.narration == "After")
    }
}
