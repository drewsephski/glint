import Foundation
import Testing
import GlintAnalysis
import GlintCore
@testable import GlintAgent

@Suite struct SubscriptionNarratorTests {
    @Test func legacyOptions() throws {
        let options = try JSONDecoder().decode(NarrationOptions.self, from: Data("{}".utf8))
        #expect(options.writer == .auto)
        #expect(options.includeFrames)
    }
    @Test func outputShapes() throws {
        let json = #"{"title":"Demo","summary":"Summary","scenes":[{"id":"s1","title":"Start","narration":"Hello"}]}"#
        for text in [json, "Here is your script:\n```json\n" + json + "\n```"] {
            #expect(try SubscriptionNarrator.parse(text)["title"]?.stringValue == "Demo")
        }
    }
    @Test func invalidOutput() {
        for text in ["invalid", "{}", #"{"title":"Demo","summary":"Summary","scenes":[{}]}"#] {
            #expect(throws: SubscriptionNarratorError.self) { try SubscriptionNarrator.parse(text) }
        }
    }
}

@Suite(.serialized) struct FakeSubscriptionWriterTests {
    @Test func fakeProviders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let doc = ProjectDocument(name: "test", media: MediaInfo(screen: "screen.mov", width: 100, height: 100, scale: 1, duration: 5, frameRate: 30))
        let bundle = try ProjectBundle.create(at: root.appendingPathComponent("test.glint"), document: doc, events: EventLog())
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=")!.write(to: bundle.url.appendingPathComponent("frame.png"))
        let storyboard = Storyboard(revision: doc.revision, scenes: [Scene(id: "s1", start: 0, end: 5, title: "Test", frame: "frame.png", narration: "Keep me")])
        var options = NarrationOptions(); options.onlyMissing = true
        for provider in SubscriptionProvider.allCases {
            let key = provider == .claude ? "GLINT_CLAUDE_CLI" : "GLINT_CODEX_CLI"
            let old = ProcessInfo.processInfo.environment[key]
            defer { if let old { setenv(key, old, 1) } else { unsetenv(key) } }
            let script = root.appendingPathComponent(provider.rawValue)
            let marker = root.appendingPathComponent("cwd")
            setenv(key, script.path, 1)
            try "#!/bin/sh\nif [ \"$1\" = auth ]; then echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}'; else echo 'Logged in using ChatGPT'; fi\n".write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let approvals = ApprovalStore(directory: root.appendingPathComponent("approvals"))
            let service = GlintService(approvals: approvals)
            options.writer = provider == .claude ? .claude : .chatgpt
            #expect(service.resolvedNarrationWriter(options) == options.writer)
            try bundle.writeStoryboard(storyboard)
            do {
                _ = try await service.writeNarration(bundle, options: options, author: Author(.agent, "test"), approvalID: nil)
                Issue.record("Expected approval")
            } catch ApprovalError.required(let request) {
                if let other = approvals.all().first(where: { $0.parameters["writer"] != request.parameters["writer"] }) {
                    _ = try approvals.decide(other.id, approve: true, by: "test")
                    do {
                        _ = try await service.writeNarration(bundle, options: options, author: Author(.agent, "test"), approvalID: other.id)
                        Issue.record("Cross-provider approval accepted")
                    } catch ApprovalError.invalid {} 
                }
                #expect(request.parameters["writer"]?.stringValue == options.writer.rawValue)
                #expect(request.summary.contains(provider == .claude ? "Anthropic through your Claude subscription" : "OpenAI through your ChatGPT subscription"))
            }
            for response in [#"{"title":"Demo","summary":"Summary","scenes":[{"id":"s1","title":"Start","narration":"New"}]}"#, "invalid", "Not logged in", "usage limit"] {
                try "#!/bin/sh\npwd > '\(marker.path)'\ncat > received\ntest -f frame-0.jpg || exit 3\ncat <<'REPLY'\n\(response)\nREPLY\n".write(to: script, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                do {
                    let result = try await SubscriptionNarrator.write(provider: provider, bundle: bundle, storyboard: storyboard, document: doc, options: options)
                    #expect(response.hasPrefix("{"))
                    #expect(result.scenes.first?.narration == "Keep me")
                } catch { #expect(!response.hasPrefix("{")) }
                let cwd = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!fm.fileExists(atPath: cwd))
            }
            try "#!/bin/sh\npwd > '\(marker.path)'\n/bin/sleep 60 & echo $! > '\(root.path)/child'; wait\n".write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            do {
                _ = try await SubscriptionNarrator.write(provider: provider, bundle: bundle, storyboard: storyboard, document: doc, options: options, timeout: 1)
                Issue.record("Expected timeout")
            } catch SubscriptionNarratorError.timedOut {} catch { throw error }
            func checkChild() throws {
                let file = root.appendingPathComponent("child")
                let pid = try #require(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                let until = Date().addingTimeInterval(4)
                while kill(pid, 0) == 0, Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                #expect(kill(pid, 0) == -1)
                try fm.removeItem(at: file)
            }
            try checkChild()
            let task = Task { try await SubscriptionNarrator.write(provider: provider, bundle: bundle, storyboard: storyboard, document: doc, options: options) }
            let until = Date().addingTimeInterval(3)
            while !fm.fileExists(atPath: root.appendingPathComponent("child").path), Date() < until {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            task.cancel()
            do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
            try checkChild()
        }
    }
}

@Suite struct WriterResolutionTests {
    @Test func availabilityMatrix() {
        let service = GlintService()
        for claude in [false, true] {
            for chatgpt in [false, true] {
                for key in [false, true] {
                    let statuses = [SubscriptionStatus(provider: .claude, state: claude ? .signedIn : .signedOut), SubscriptionStatus(provider: .chatgpt, state: chatgpt ? .signedIn : .signedOut)]
                    #expect(service.resolveNarrationWriter(.claude, statuses: statuses, hasKey: key) == (claude ? .claude : nil))
                    #expect(service.resolveNarrationWriter(.chatgpt, statuses: statuses, hasKey: key) == (chatgpt ? .chatgpt : nil))
                    #expect(service.resolveNarrationWriter(.apiKey, statuses: statuses, hasKey: key) == (key ? .apiKey : nil))
                    let auto = service.resolveNarrationWriter(.auto, statuses: statuses, hasKey: key)
                    if claude || chatgpt { #expect(auto == .claude || auto == .chatgpt) }
                    else { #expect(auto == (key ? .apiKey : nil)) }
                }
            }
        }
    }
}

@Suite struct ExistingVoiceoverTests {
    @Test func captionsWithoutSynthesis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = ProjectDocument(name: "test", media: MediaInfo(screen: "screen.mov", width: 100, height: 100, scale: 1, duration: 5, frameRate: 30))
        doc.style.voice.voiceID = "test-voice"
        doc.timeline.voiceover = [VoiceoverClip(start: 0, path: "existing.mp3", text: "Hello", duration: 2, voice: "test-voice", scene: "s1")]
        let bundle = try ProjectBundle.create(at: root, document: doc, events: EventLog())
        try Data().write(to: root.appendingPathComponent("existing.mp3"))
        try bundle.writeStoryboard(Storyboard(revision: doc.revision, scenes: [Scene(id: "s1", start: 0, end: 5, title: "Test", narration: "Hello")]))
        let service = GlintService(approvals: ApprovalStore(directory: root.appendingPathComponent("approvals")))
        let result = try await service.voiceover(bundle, voice: nil, fit: true, captions: true, author: Author(.agent, "test"), approvalID: nil)
        #expect(!result.operations.isEmpty)
        #expect(result.clips.isEmpty)
        #expect(result.fitNotes.contains { $0.contains("Nothing was sent") })
    }
}

@Suite struct StoryboardFreshnessTests {
    @Test func analysisCarriesMatchingLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = ProjectDocument(name: "test", media: MediaInfo(screen: "screen.mov", width: 100, height: 100, scale: 1, duration: 5, frameRate: 30))
        let bundle = try ProjectBundle.create(at: root, document: doc, events: EventLog())
        var scenes = SceneAnalyzer.boundaries(bundle: bundle, document: doc)
        #expect(!scenes.isEmpty)
        scenes[0].narration = "Handwritten"
        try bundle.writeStoryboard(Storyboard(revision: doc.revision, scenes: scenes))
        doc.revision += 1
        var options = SceneAnalyzer.Options(); options.frames = false; options.ocr = false
        let updated = try await SceneAnalyzer.analyze(bundle: bundle, document: doc, options: options)
        #expect(updated.scenes[0].narration == "Handwritten")
        #expect(updated.revision == doc.revision)
    }
}
