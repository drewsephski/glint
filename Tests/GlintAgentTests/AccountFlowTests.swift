import Foundation
import Testing
import GlintCore
@testable import GlintAgent

@Suite(.serialized) struct AccountFlowTests {
    @Test func fakeFlows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = ["GLINT_CLAUDE_CLI", "GLINT_CODEX_CLI"]
        let old = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key, value) in zip(keys, old) { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: dir)
        }
        let previousPreference = Subscriptions.preferred
        defer { if ProcessInfo.processInfo.environment["GLINT_HOME"] != nil { Subscriptions.preferred = previousPreference } }
        let cli = dir.appendingPathComponent("vendor")
        for key in keys.prefix(2) { setenv(key, cli.path, 1) }
        func script(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        for provider in SubscriptionProvider.allCases {
            for (output, expected) in [(provider == .claude ? "{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}" : "Logged in using ChatGPT", SubscriptionStatus.State.signedIn), (provider == .claude ? "{\"loggedIn\":false}" : "Not logged in", .signedOut), ("token has expired", .expired), (provider == .claude ? "{\"loggedIn\":true,\"authMethod\":\"api_key\"}" : "Logged in using an API key", .usingAPIKey)] {
                try script("echo '\(output)'\n")
                #expect(Subscriptions.status(provider).state == expected)
            }
            try script("echo unexpected\n")
            if case .unknown = Subscriptions.status(provider).state {} else { Issue.record("Expected unknown") }
            try script("exit 0\n"); try Subscriptions.signOut(provider)
            try script("exit 1\n")
            #expect(throws: (any Error).self) { try Subscriptions.signOut(provider) }
            for mode in ["success", "code", "failure", "signed-out", "cancel", "timeout"] {
                let signed = provider == .claude ? "{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}" : "Logged in using ChatGPT"
                try script("""
                case "$*" in
                  *status*) echo '\(mode == "signed-out" ? "Not logged in" : signed)'; exit 0;;
                esac
                printf '\\033[32mhttps://example.com/login\\033[0m\\n'
                \(mode == "code" ? "echo 'Paste code:'; read code; [ \"$code\" = test-code ] || exit 1" : "")
                \(["timeout", "cancel"].contains(mode) ? "sleep 60 & echo $! > '\(dir.path)/child'; wait" : "")
                exit \(mode == "failure" ? 1 : 0)
                """)
                let events = Events()
                let flow = SubscriptionSignIn(provider: provider, timeout: mode == "timeout" ? 1 : 5) { events.add($0) }
                try flow.start()
                if mode == "cancel" {
                    let until = Date().addingTimeInterval(2)
                    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("child").path), Date() < until { Thread.sleep(forTimeInterval: 0.01) }
                    flow.cancel(); flow.cancel()
                }
                let deadline = Date().addingTimeInterval(8)
                var submitted = false
                while events.terminalCount == 0 && Date() < deadline {
                    if events.values.contains(.needsCode), !submitted { flow.submit(code: "test-code"); submitted = true }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                flow.cancel()
                Thread.sleep(forTimeInterval: 0.15)
                if ["cancel", "timeout"].contains(mode) {
                    let file = dir.appendingPathComponent("child")
                    let pid = try #require(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                    let until = Date().addingTimeInterval(4)
                    while kill(pid, 0) == 0, Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                    #expect(kill(pid, 0) == -1)
                    try FileManager.default.removeItem(at: file)
                }
                #expect(events.terminalCount == 1)
                if mode == "cancel" { #expect(events.values.contains(.failed("Sign-in cancelled."))) }
                if mode == "timeout" { #expect(events.values.contains(.failed("Sign-in timed out. Try again."))) }
                if mode == "code" { #expect(submitted) }
                if ["success", "code"].contains(mode) {
                    #expect(events.values.contains { if case .finished = $0 { true } else { false } })
                    #expect(events.values.contains { if case .openedBrowser = $0 { true } else { false } })
                } else { #expect(events.values.contains { if case .failed = $0 { true } else { false } }) }
            }
            try script("sleep 1\n")
            #expect(Subscriptions.status(provider, timeout: 0.05).state == .unknown("Couldn't check. Try again."))
            if ProcessInfo.processInfo.environment["GLINT_HOME"] != nil {
                Subscriptions.preferred = provider
                #expect(Subscriptions.preferred == provider)
            }
        }
        for key in keys.prefix(2) { setenv(key, "", 1) }
        for p in SubscriptionProvider.allCases { #expect(Subscriptions.status(p).state == .notInstalled) }
    }
    @Test func preservesCorruptTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = ProjectBundle(url: dir)
        let original = Data("broken json".utf8)
        try original.write(to: ChatTranscript.url(for: bundle))
        let transcript = ChatTranscript.load(bundle)
        transcript.save(bundle)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("agent-chat.corrupt-") })
        #expect(try Data(contentsOf: backup) == original)
    }
    @Test func parserFailures() {
        for message in ["not logged in", "usage limit", "network failed"] {
            var names: [String: String] = [:]
            let claude = Data("{\"type\":\"result\",\"is_error\":true,\"result\":\"\(message)\"}".utf8)
            #expect(ChatParser.claude(claude, toolNames: &names).contains(.failure(Subscriptions.failureMessage(message, provider: .claude))))
            let codex = Data("{\"type\":\"turn.failed\",\"error\":{\"message\":\"\(message)\"}}".utf8)
            #expect(ChatParser.codex(codex).contains(.failure(Subscriptions.failureMessage(message, provider: .chatgpt))))
        }
    }
    @Test func cleanFailures() {
        for p in SubscriptionProvider.allCases {
            #expect(Subscriptions.failureMessage("not logged in SECRET", provider: p).contains("Sign in"))
            #expect(Subscriptions.failureMessage("usage limit SECRET", provider: p).contains("usage limit"))
            #expect(Subscriptions.failureMessage("network failed SECRET", provider: p).contains("connection"))
            #expect(!Subscriptions.failureMessage("unexpected SECRET", provider: p).contains("SECRET"))
        }
    }
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SubscriptionSignIn.Event] = []
    func add(_ event: SubscriptionSignIn.Event) { lock.withLock { storage.append(event) } }
    var values: [SubscriptionSignIn.Event] { lock.withLock { storage } }
    var terminalCount: Int { values.filter { switch $0 { case .finished, .failed: true; default: false } }.count }
}
