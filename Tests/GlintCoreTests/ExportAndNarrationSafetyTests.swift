import Foundation
import Testing

@testable import GlintCore

@Suite struct ExportAndNarrationSafetyTests {
    @Test func failedCopyKeepsPreviousExportAndCleansStagingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.mov")
        try Data("previous export".utf8).write(to: destination)
        #expect(throws: CocoaError.self) {
            try AtomicFile.copy(directory.appendingPathComponent("source"), to: destination) { _, stage in
                try Data("partial copy".utf8).write(to: stage)
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "previous export")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["export.mov"])
    }

    @Test func replacesOnlyAfterCopyAndSupportsSamePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("export.mov")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try AtomicFile.copy(source, to: destination) { source, stage in
            #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
            try FileManager.default.copyItem(at: source, to: stage)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(throws: (any Error).self) { try AtomicFile.copy(source, to: destination, replacing: false) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        try AtomicFile.copy(destination, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try AtomicFile.copy(source, to: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["export.mov", "folder", "source"])
    }

    @Test func scriptAndTimelineShareUndoRedoAcrossReopening() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let original = Storyboard(
            createdAt: Date(timeIntervalSince1970: 0), revision: 0, scenes: [Scene(id: "s1", start: 0, end: 10, title: "First", narration: "Before")])
        try bundle.writeStoryboard(original)
        let engine = Engine(bundle: bundle)
        try engine.editStoryboard(author: .app, label: "Edit narration") { $0.scenes[0].narration = "After" }
        try engine.apply([.style("captions.enabled", .bool(true))], author: .app)
        let reopened = Engine(bundle: bundle)
        try reopened.undo(author: .app)
        #expect(bundle.readStoryboard()?.scenes[0].narration == "After")
        try reopened.undo(author: .app)
        #expect(bundle.readStoryboard() == original)
        try reopened.redo(author: .app)
        #expect(bundle.readStoryboard()?.scenes[0].narration == "After")
        try reopened.redo(author: .app)
        #expect(try bundle.readDocument().style.captions.enabled)
        let scriptEdit = try #require(reopened.history().first)
        try reopened.revert(scriptEdit.id, author: .app)
        #expect(bundle.readStoryboard() == original)
        try reopened.undo(author: .app)
        #expect(bundle.readStoryboard()?.scenes[0].narration == "After")
    }

    @Test func scriptUndoRefusesToOverwriteExternalEdits() throws {
        let bundle = try tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        var storyboard = Storyboard(
            createdAt: Date(timeIntervalSince1970: 0), revision: 0, scenes: [Scene(id: "s1", start: 0, end: 10, title: "First", narration: "Before")])
        try bundle.writeStoryboard(storyboard)
        let engine = Engine(bundle: bundle)
        try engine.editStoryboard(author: .app, label: "Edit narration") { $0.scenes[0].narration = "After" }
        storyboard.scenes[0].narration = "External"
        try bundle.writeStoryboard(storyboard)
        let revision = try bundle.readDocument().revision
        #expect(throws: EditError.self) { try engine.undo(author: .app) }
        #expect(bundle.readStoryboard() == storyboard)
        #expect(try bundle.readDocument().revision == revision)
        #expect(engine.history().count == 1)
    }
}
