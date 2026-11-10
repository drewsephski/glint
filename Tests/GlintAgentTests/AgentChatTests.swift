import Foundation
import Testing
@testable import GlintCore
@testable import GlintAgent

@Suite struct ChatParserTests {
    func d(_ s: String) -> Data { Data(s.utf8) }

    @Test func claudeStreamJSON() {
        var names: [String: String] = [:]
        #expect(ChatParser.claude(d(#"{"type":"system","subtype":"hook_started","session_id":"s1"}"#), toolNames: &names).isEmpty)
        #expect(ChatParser.claude(d(#"{"type":"system","subtype":"init","session_id":"s1","tools":[]}"#), toolNames: &names) == [.session("s1")])
        let use = ChatParser.claude(d(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Planning zooms."},{"type":"tool_use","id":"t1","name":"mcp__glint__glint_plan_zooms","input":{"project":"/p.glint","apply":false}}]}}"#), toolNames: &names)
        #expect(use == [.message("Planning zooms."), .toolStarted(id: "t1", name: "plan_zooms", detail: "apply: false")])
        let ok = ChatParser.claude(d(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"{\"proposal_id\":\"p1\"}"}]}}"#), toolNames: &names)
        #expect(ok == [.toolFinished(id: "t1", name: "plan_zooms", outcome: .ok, detail: "")])
        let gated = ChatParser.claude(d(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"{\"status\":\"approval_required\",\"approval_id\":\"apr_1\"}"}]}]}}"#), toolNames: &names)
        #expect(gated.first.map { if case .toolFinished(_, _, .needsApproval, _) = $0 { true } else { false } } == true)
        #expect(ChatParser.claude(d(#"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","result":"Done"}"#), toolNames: &names) == [.session("s1"), .finished(ok: true)])
        let failed = ChatParser.claude(d(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s1"}"#), toolNames: &names)
        #expect(failed.last == .finished(ok: false))
        #expect(ChatParser.claude(d("not json"), toolNames: &names).isEmpty)
    }

    @Test func codexExecJSON() {
        #expect(ChatParser.codex(d(#"{"type":"thread.started","thread_id":"th1"}"#)) == [.session("th1")])
        // Unrelated problems (other MCP servers) aren't chat content.
        #expect(ChatParser.codex(d(#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Under-development features enabled"}}"#)).isEmpty)
        #expect(ChatParser.codex(d(#"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Looking."}}"#)) == [.message("Looking.")])
        #expect(ChatParser.codex(d(#"{"type":"item.started","item":{"id":"item_3","type":"mcp_tool_call","server":"glint","tool":"glint_project_info","arguments":{"project":"/p"},"status":"in_progress"}}"#))
                == [.toolStarted(id: "item_3", name: "project_info", detail: "")])
        #expect(ChatParser.codex(d(#"{"type":"item.completed","item":{"id":"item_3","type":"mcp_tool_call","server":"glint","tool":"glint_project_info","arguments":{},"result":{"content":[{"type":"text","text":"{}"}]},"error":null,"status":"completed"}}"#))
                == [.toolFinished(id: "item_3", name: "project_info", outcome: .ok, detail: "")])
        let failed = ChatParser.codex(d(#"{"type":"item.completed","item":{"id":"item_4","type":"mcp_tool_call","tool":"glint_render","status":"failed","error":{"message":"timed out"}}}"#))
        #expect(failed == [.toolFinished(id: "item_4", name: "render", outcome: .failed, detail: "timed out")])
        #expect(ChatParser.codex(d(#"{"type":"turn.completed","usage":{}}"#)) == [.finished(ok: true)])
        #expect(ChatParser.codex(d(#"{"type":"turn.failed","error":{"message":"usage limit"}}"#)) == [.failure("You've reached your ChatGPT plan's usage limit. Try again after it resets."), .finished(ok: false)])
    }

    @Test func transcriptRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-chat-\(UUID().uuidString.prefix(6)).glint")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = ProjectBundle(url: dir)
        var t = ChatTranscript()
        t.entries = [.init(role: .user, text: "hi"), .init(role: .tool, agent: .codex, text: "", tool: "plan_zooms", toolOutcome: .needsApproval)]
        t.sessions["codex"] = "th1"
        t.save(b)
        let back = ChatTranscript.load(b)
        #expect(back.entries.map(\.id) == t.entries.map(\.id))
        #expect(back.entries.map(\.toolOutcome) == t.entries.map(\.toolOutcome))
        #expect(back.sessions == ["codex": "th1"])
    }
}

/// Talks to the real Claude Code / Codex CLIs (uses the person's account). Run with GLINT_LIVE_CHAT=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GLINT_LIVE_CHAT"] == "1")) struct LiveChatTests {
    func runTurn(_ agent: ChatAgent, project: URL, prompt: String, session: String?, helper: String) async throws -> [ChatEvent] {
        let cli = try #require(agent.cliPath, "\(agent.title) not installed")
        let box = Box()
        let run = AgentChatRun(agent: agent, cli: cli, project: project, prompt: prompt, sessionID: session, helper: helper) { box.add($0) }
        try run.start()
        let deadline = Date().addingTimeInterval(240)
        while !box.done && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        if !box.done { run.cancel() }
        return box.events
    }

    final class Box: @unchecked Sendable {
        private var e: [ChatEvent] = []; private let l = NSLock()
        func add(_ x: ChatEvent) { l.withLock { e.append(x) } }
        var events: [ChatEvent] { l.withLock { e } }
        var done: Bool { events.contains { if case .finished = $0 { true } else { false } } }
    }

    @Test(arguments: ChatAgent.allCases) func agentEditsThroughGlintAndResumes(_ agent: ChatAgent) async throws {
        let helper = try #require(ProcessInfo.processInfo.environment["GLINT_LIVE_HELPER"], "set GLINT_LIVE_HELPER to a glint CLI")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-live-\(agent.rawValue)-\(UUID().uuidString.prefix(6)).glint")
        let b = try await SyntheticProject.make(at: url, duration: 5)
        let first = try await runTurn(agent, project: b.url, prompt: "Plan auto zooms for this project as a proposal (don't apply it). Reply with one short sentence.", session: nil, helper: helper)
        #expect(first.contains(.finished(ok: true)), "\(first)")
        #expect(first.contains { if case .toolFinished(_, "plan_zooms", .ok, _) = $0 { true } else { false } }, "\(first)")
        let session = try #require(first.compactMap { if case .session(let s) = $0 { s } else { nil } }.last)
        #expect(try Engine(bundle: b).proposals().contains { $0.status == .pending && $0.author.kind == .agent })

        let second = try await runTurn(agent, project: b.url, prompt: "What did you just propose? One sentence, no tools.", session: session, helper: helper)
        #expect(second.contains(.finished(ok: true)), "\(second)")
        #expect(second.contains { if case .message(let m) = $0 { m.lowercased().contains("zoom") } else { false } }, "\(second)")
    }
}
