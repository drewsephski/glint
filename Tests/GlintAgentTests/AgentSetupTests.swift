import Foundation
import Testing
@testable import GlintCore
@testable import GlintAgent

@Suite struct CodexTOMLTests {
    let helper = "/Applications/Glint.app/Contents/Helpers/glint"
    let existing = """
    model = "gpt-6"

    # my servers
    [mcp_servers.chrome-devtools]
    command = "npx"
    args = ["-y", "chrome-devtools-mcp@latest"]

    [mcp_servers.chrome-devtools.tools.evaluate_script]
    approval_mode = "approve"

    [profiles.fast]
    model = "x"
    """

    @Test func appendsWithoutTouchingAnythingElse() throws {
        let out = try CodexTOML.upsert(existing, command: helper)
        #expect(out.hasPrefix(existing))
        #expect(out.contains("[mcp_servers.glint]\ncommand = \"\(helper)\"\nargs = [\"mcp\"]\nstartup_timeout_sec = 30\ntool_timeout_sec = 900\n"))
        let e = try #require(try CodexTOML.entry(in: out))
        #expect(e.command == helper && e.enabled && e.toolTimeout == 900)
        // Idempotent.
        #expect(try CodexTOML.upsert(out, command: helper) == out)
    }

    @Test func updatesInPlaceKeepingUserKeysAndSubtables() throws {
        let text = """
        [mcp_servers."glint"]
        command = "/old/build/Glint.app/Contents/Helpers/glint"
        args = ["mcp"]
        enabled = false
        cwd = "/tmp"

        [mcp_servers.glint.env]
        GLINT_HOME = "/tmp/g"

        [mcp_servers.other]
        command = "x"
        """
        let out = try CodexTOML.upsert(text, command: helper)
        #expect(out.contains("cwd = \"/tmp\""))
        #expect(out.contains("[mcp_servers.glint.env]\nGLINT_HOME = \"/tmp/g\""))
        #expect(out.contains("[mcp_servers.other]\ncommand = \"x\""))
        #expect(!out.contains("/old/build"))
        #expect(!out.contains("enabled = false"))
        #expect(try CodexTOML.entry(in: out)?.command == helper)
        #expect(out.components(separatedBy: "[mcp_servers.glint]").count == 2)   // still one table
    }

    @Test func removeDropsTableAndSubtablesOnly() throws {
        let added = try CodexTOML.upsert(existing + "\n\n[mcp_servers.glint.env]\nA = \"1\"\n", command: helper)
        let removed = try CodexTOML.remove(added)
        #expect(!removed.contains("glint"))
        #expect(removed.contains("[mcp_servers.chrome-devtools.tools.evaluate_script]"))
        #expect(removed.contains("[profiles.fast]"))
        #expect(try CodexTOML.entry(in: removed) == nil)
    }

    @Test func refusesFormsItCannotRewrite() throws {
        let inline = "[mcp_servers]\nglint = { command = \"/x\", args = [\"mcp\"] }\n"
        #expect(throws: AgentSetupError.self) { try CodexTOML.upsert(inline, command: helper) }
        let dotted = "mcp_servers.glint.command = \"/x\"\n"
        #expect(throws: AgentSetupError.self) { try CodexTOML.upsert(dotted, command: helper) }
    }

    @Test func ignoresHeadersInsideMultilineStrings() throws {
        let text = "instructions = \"\"\"\n[mcp_servers.glint]\nnot a table\n\"\"\"\n"
        #expect(try CodexTOML.entry(in: text) == nil)
        let out = try CodexTOML.upsert(text, command: helper)
        #expect(out.hasPrefix(text))
    }

    // Cases from review: values spanning lines, comments that look like strings, escaped keys, inline tables.
    @Test func replacesMultilineOwnedValuesWhole() throws {
        let text = "[mcp_servers.glint]\ncommand = \"/old/glint\"\nargs = [\n  \"mcp\",  # the server\n]\ncwd = \"/tmp\"\n"
        let out = try CodexTOML.upsert(text, command: helper)
        #expect(!out.contains("the server"))
        #expect(out.contains("cwd = \"/tmp\""))
        let e = try #require(try CodexTOML.entry(in: out))
        #expect(e.command == helper && e.args == ["mcp"])
        #expect(try CodexTOML.entry(in: text)?.args == ["mcp"])
    }

    @Test func commentsWithQuotesDontHideTables() throws {
        let text = "[mcp_servers.glint]\ncommand = \"/g\"\n# \"\"\" not a string\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let removed = try CodexTOML.remove(text)
        #expect(removed == "[mcp_servers.other]\ncommand = \"x\"\n")
    }

    @Test func removalKeepsEveryOtherByte() throws {
        let other = "developer_instructions = \"\"\"one\n\n\n[mcp_servers.glint]\ntwo\"\"\"\n\n\n[mcp_servers.x]\nurl = \"u\"\n"
        let added = try CodexTOML.upsert(other, command: helper)
        #expect(try CodexTOML.remove(added) == other)
        #expect(try CodexTOML.entry(in: other) == nil)
    }

    @Test func escapedAndQuotedHeaderKeysAreRecognized() throws {
        let text = "[mcp_servers.\"gl\\u0069nt\"]\ncommand = \"/old\"\nargs = [\"mcp\"]\n"
        #expect(try CodexTOML.entry(in: text)?.command == "/old")
        let out = try CodexTOML.upsert(text, command: helper)
        #expect(out.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count == 1)
        #expect(try CodexTOML.entry(in: out)?.command == helper)
    }

    @Test func rootInlineServersTableIsRefused() throws {
        let text = "mcp_servers = { other = { command = \"x\" } }\n"
        #expect(throws: AgentSetupError.self) { try CodexTOML.upsert(text, command: helper) }
        #expect(throws: AgentSetupError.self) { try CodexTOML.upsert("[[mcp_servers.glint]]\ncommand = \"x\"\n", command: helper) }
    }

    @Test func crlfFilesStayCRLF() throws {
        let text = "model = \"x\"\r\n"
        let out = try CodexTOML.upsert(text, command: helper)
        #expect(out.hasPrefix(text))
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(try CodexTOML.entry(in: out)?.command == helper)
        #expect(try CodexTOML.remove(out) == text)
    }

    @Test func quotesPathsSafely() throws {
        let odd = "/Users/a \"b\"/Glint.app/Contents/Helpers/glint"
        let out = try CodexTOML.upsert("", command: odd)
        #expect(out.contains(#"command = "/Users/a \"b\"/Glint.app/Contents/Helpers/glint""#))
        #expect(try CodexTOML.entry(in: out)?.command == odd)
    }
}

@Suite struct ClaudeDesktopJSONTests {
    @Test func upsertKeepsOtherServersAndKeys() throws {
        let data = Data(#"{"mcpServers":{"rea":{"command":"/r"}},"preferences":{"x":true}}"#.utf8)
        let out = try ClaudeDesktopJSON.upsert(data, command: "/A/glint")
        let root = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect((servers["rea"] as? [String: Any])?["command"] as? String == "/r")
        #expect((servers["glint"] as? [String: Any])?["args"] as? [String] == ["mcp"])
        #expect((root["preferences"] as? [String: Any])?["x"] as? Bool == true)
        #expect(try ClaudeDesktopJSON.command(in: out) == "/A/glint")
        let removed = try #require(try ClaudeDesktopJSON.remove(out))
        #expect(try ClaudeDesktopJSON.command(in: removed) == nil)
        #expect(try ClaudeDesktopJSON.remove(removed) == nil)
    }

    @Test func emptyOrMissingFileIsFineButBrokenJSONIsNotOverwritten() throws {
        #expect(try ClaudeDesktopJSON.command(in: try ClaudeDesktopJSON.upsert(nil, command: "/g")) == "/g")
        #expect(try ClaudeDesktopJSON.command(in: try ClaudeDesktopJSON.upsert(Data("  \n".utf8), command: "/g")) == "/g")
        #expect(throws: AgentSetupError.self) { try ClaudeDesktopJSON.upsert(Data("{ nope".utf8), command: "/g") }
    }
}

@Suite struct OtherClientTests {
    @Test func eachClientGetsItsOwnShape() throws {
        func root(_ c: OtherClient) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(c.snippet(helper: "/g").utf8)) as? [String: Any]) }
        #expect(((try root(.vscode)["servers"] as? [String: Any])?["glint"] as? [String: Any])?["type"] as? String == "stdio")
        #expect(((try root(.zed)["context_servers"] as? [String: Any])?["glint"] as? [String: Any])?["command"] as? String == "/g")
        for c in [OtherClient.cursor, .windsurf, .generic] {
            #expect(((try root(c)["mcpServers"] as? [String: Any])?["glint"] as? [String: Any])?["args"] as? [String] == ["mcp"])
        }
    }
}

@Suite struct AgentLocationTests {
    @Test func classifiesWhereGlintRuns() {
        #expect(AgentSetup.location(of: "/Applications/Glint.app/Contents/Helpers/glint") == .installed)
        #expect(AgentSetup.location(of: "/Volumes/Glint/Glint.app/Contents/Helpers/glint") == .diskImage)
        #expect(AgentSetup.location(of: "/private/var/folders/x/AppTranslocation/ABC/d/Glint.app/Contents/Helpers/glint") == .translocated)
        #expect(AgentSetup.location(of: "/Users/a/src/glint/build/Glint.app/Contents/Helpers/glint") == .development)
        #expect(AgentSetup.locationProblem("/Volumes/Glint/Glint.app/Contents/Helpers/glint") != nil)
        #expect(AgentSetup.appBundle(containing: "/Applications/Glint.app/Contents/Helpers/glint")?.path == "/Applications/Glint.app")
        #expect(AgentSetup.appBundle(containing: "/usr/local/bin/glint") == nil)
    }

    @Test func statusComparesResolvedPaths() {
        #expect(AgentSetup.classify(command: nil, helper: "/a") == .notConnected)
        #expect(AgentSetup.classify(command: "/a", enabled: false, helper: "/a") == .disabled)
        #expect(AgentSetup.classify(command: "/b", helper: "/a") == .otherCopy("/b"))
        #expect(AgentSetup.classify(command: "/a", helper: "/a") == .connected)
        #expect(AgentSetup.classify(command: "/a", args: ["--help"], helper: "/a") == .misconfigured("runs glint --help instead of glint mcp"))
        #expect(AgentSetup.classify(command: "/a", transport: "sse", helper: "/a") != .connected)
        // Only absolute paths to missing files count as broken; a bare name may resolve on PATH.
        #expect(AgentSetup.certainlyMissing("/nonexistent/Glint.app/Contents/Helpers/glint"))
        #expect(!AgentSetup.certainlyMissing("glint"))
        #expect(!AgentSetup.certainlyMissing("/bin/sh"))
    }
}

/// An agent's capture calls travel from its `glint mcp` process to the app's CaptureHost and back.
@Suite(.serialized) struct CaptureBrokerTests {
    @Test func captureToolsRunInTheHostAndEverythingElseStaysLocal() async throws {
        let dir = URL(fileURLWithPath: "/tmp/glint-broker-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("a.sock").path

        let appApprovals = ApprovalStore(directory: dir.appendingPathComponent("app-approvals"))
        let host = CaptureHost(service: GlintService(approvals: appApprovals))
        try host.start(socketPath: sock)
        defer { host.stop() }
        // A second host on the same socket refuses instead of stealing it.
        #expect(throws: (any Error).self) { try CaptureHost(service: GlintService(approvals: appApprovals)).start(socketPath: sock) }

        let h = MCPHarness()
        h.server.enableCaptureForwarding(socketPath: sock, launchApp: false)
        _ = try await h.call("initialize", .object(["clientInfo": .object(["name": .string("codex-test")])]))

        // Recording as an agent: the approval is created by the app (its store), attributed to the agent.
        let r = try await h.tool("glint_record_start", ["max_duration": .number(2)])
        #expect(r["structuredContent"]?.str("status") == "approval_required")
        let pending = appApprovals.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.requestedBy.name == "codex-test")
        #expect(h.approvals.pending().isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.clients == ["codex-test"])

        // Status follows the session to the app.
        let s = try await h.tool("glint_record_status", [:])
        #expect(s["structuredContent"]?["recording"]?.boolValue == false)

        // Non-capture tools never leave the MCP process.
        let projects = try await h.tool("glint_list_projects", [:])
        #expect(projects["isError"]?.boolValue == false)
    }

    @Test func concurrentConnectsOpenOneConnectionAndIDsCantCollide() async throws {
        let dir = URL(fileURLWithPath: "/tmp/glint-broker-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("a.sock").path
        let host = CaptureHost(service: GlintService(approvals: ApprovalStore(directory: dir.appendingPathComponent("ap"))))
        try host.start(socketPath: sock)
        defer { host.stop() }

        let sink = Pipe()
        let client = CaptureClient(socketPath: sock, canLaunch: false) { d in try? sink.fileHandleForWriting.write(contentsOf: d) }
        await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<16 { g.addTask { client.connect(author: Author(.agent, "racer")) } }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.clients.count == 1)

        // An agent may use any ID, including ones that look like the broker's own.
        for id in ["glint-hello-1", "glint-1"] {
            #expect(client.forward(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string("tools/call"),
                                            "params": .object(["name": .string("glint_record_status"), "arguments": .object([:])])])))
            var line = Data()
            while true { let b = sink.fileHandleForReading.readData(ofLength: 1); if b.isEmpty || b == Data([0x0A]) { break }; line.append(b) }
            let reply = try JSONCoding.decoder.decode(JSONValue.self, from: line)
            #expect(reply["id"]?.stringValue == id)
            #expect(reply["result"] != nil)
        }
    }

    @Test func aRefusedHostLeavesTheOwnersSocketAlone() throws {
        let dir = URL(fileURLWithPath: "/tmp/glint-broker-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("a.sock").path
        let svc = GlintService(approvals: ApprovalStore(directory: dir.appendingPathComponent("ap")))
        let owner = CaptureHost(service: svc)
        try owner.start(socketPath: sock)
        let second = CaptureHost(service: svc)
        #expect(throws: (any Error).self) { try second.start(socketPath: sock) }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: sock))
        owner.stop()
        #expect(!FileManager.default.fileExists(atPath: sock))
    }

    @Test func withoutTheAppCaptureStaysLocal() async throws {
        let h = MCPHarness()
        h.server.enableCaptureForwarding(socketPath: "/tmp/glint-nobody-\(UUID().uuidString.prefix(6)).sock", launchApp: false)
        _ = try await h.call("initialize", .object(["clientInfo": .object(["name": .string("agent-y")])]))
        let r = try await h.tool("glint_record_start", ["max_duration": .number(2)])
        #expect(r["structuredContent"]?.str("status") == "approval_required")
        #expect(h.approvals.pending().count == 1)
    }
}
