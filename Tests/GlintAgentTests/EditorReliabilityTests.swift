import Foundation
import GlintAnalysis
import GlintCore
import Testing

@testable import GlintAgent

@Suite struct EditorReliabilityTests {
    @Test func usageErrorsKeepOnlyResetInformation() {
        for provider in SubscriptionProvider.allCases {
            for (input, reset) in [
                ("You've hit your limit · resets 3pm (America/Chicago) SECRET", "3pm (America/Chicago)"),
                ("rate_limit resets 2026-11-11T00:30:00Z SECRET", "2026-11-11T00:30:00Z"),
                ("usage limit resets in 2 hours 15 minutes SECRET", "in 2 hours 15 minutes"),
                ("usage limit. Try again at Nov 10th, 2026 2:00 PM SECRET", "Nov 10th, 2026 2:00 PM"),
                ("quota exceeded resets at 16:30 UTC SECRET", "16:30 UTC"),
            ] {
                #expect(Subscriptions.resetTime(in: input) == reset)
                let message = Subscriptions.failureMessage(input, provider: provider)
                #expect(message.contains(reset))
                #expect(!message.contains("SECRET"))
            }
            #expect(Subscriptions.failureMessage("usage limit SECRET", provider: provider).hasSuffix("Try again after it resets."))
        }
    }

    @Test func savePanelConfirmationDoesNotAuthorizeAnAgent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let destination = directory.appendingPathComponent("saved.mov")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let service = GlintService(approvals: ApprovalStore(directory: directory.appendingPathComponent("approvals")))
        #expect(throws: ApprovalError.self) {
            try service.export(file: source, to: destination, author: Author(.agent, "test"), approvalID: nil, confirmedByUser: true)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
        _ = try service.export(file: source, to: destination, author: .app, approvalID: nil, confirmedByUser: true)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    }

    @Test func cancelledAnalysisAndScriptCannotSave() async throws {
        let document = ProjectDocument(name: "Test", media: MediaInfo(screen: "screen.mov", width: 100, height: 100, scale: 1, duration: 5, frameRate: 30))
        let bundle = try ProjectBundle.create(
            at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), document: document, events: EventLog())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let storyboard = Storyboard(
            createdAt: Date(timeIntervalSince1970: 0), revision: 0, scenes: [Scene(id: "s1", start: 0, end: 5, title: "First", narration: "Keep")])
        try bundle.writeStoryboard(storyboard)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var options = SceneAnalyzer.Options()
            options.frames = false
            do {
                _ = try await SceneAnalyzer.analyze(bundle: bundle, document: document, options: options)
                Issue.record("Analysis ignored cancellation")
            } catch is CancellationError {}
            do {
                _ = try Narrator.apply(
                    .object(["title": .string("Changed")]), writer: "test", bundle: bundle, storyboard: storyboard, options: NarrationOptions())
                Issue.record("Script ignored cancellation")
            } catch is CancellationError {}
        }
        try await operation.value
        #expect(bundle.readStoryboard() == storyboard)
    }
}

@Suite struct SubscriptionInstallerTests {
    @Test func installerReportsFailureAndCancellationStopsChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("installer.sh")
        try "exit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try await SubscriptionInstaller.runScript(script, shell: "/bin/sh")
        try "exit 1\n".write(to: script, atomically: true, encoding: .utf8)
        do {
            try await SubscriptionInstaller.runScript(script, shell: "/bin/sh")
            Issue.record("Failed installer accepted")
        } catch is AgentSetupError {}
        for cancel in [true, false] {
            let marker = directory.appendingPathComponent("child")
            try? FileManager.default.removeItem(at: marker)
            try "sleep 60 & echo $! > child; wait\n".write(to: script, atomically: true, encoding: .utf8)
            let task = Task { try await SubscriptionInstaller.runScript(script, shell: "/bin/sh", timeout: cancel ? 10 : 1) }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if cancel { task.cancel() }
            do {
                try await task.value
                Issue.record("Installer didn't stop")
            } catch is CancellationError { #expect(cancel) } catch is AgentSetupError { #expect(!cancel) }
            let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            let until = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0, Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(kill(pid, 0) != 0, "Installer child survived")
        }
    }
}
