import Foundation
import Testing
@testable import GlintCore
@testable import GlintAgent

/// Drives the MCP server exactly as a client would (JSON-RPC lines), capturing its stdout through a pipe.
final class MCPHarness: @unchecked Sendable {
    let pipe = Pipe()
    let server: MCPServer
    let approvals: ApprovalStore
    init() {
        approvals = ApprovalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("glint-mcp-approvals-\(UUID().uuidString.prefix(6))"))
        server = MCPServer(service: GlintService(approvals: approvals), output: pipe.fileHandleForWriting)
    }
    var nextID = 0
    func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        nextID += 1
        await server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(Double(nextID)), "method": .string(method), "params": params]))
        // Read one line back.
        var data = Data()
        while true {
            let b = pipe.fileHandleForReading.readData(ofLength: 1)
            if b.isEmpty || b == Data([0x0A]) { break }
            data.append(b)
        }
        return try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }
    func tool(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        let r = try await call("tools/call", .object(["name": .string(name), "arguments": .object(args)]))
        return r["result"] ?? r
    }
}

@Suite(.serialized) struct MCPTests {
    @Test func handshakeAndToolList() async throws {
        let h = MCPHarness()
        let ini = try await h.call("initialize", .object(["protocolVersion": .string("2025-06-18"), "clientInfo": .object(["name": .string("test-agent"), "version": .string("1")]), "capabilities": .object([:])]))
        #expect(ini["result"]?["serverInfo"]?.str("name") == "glint")
        #expect(ini["result"]?["capabilities"]?["tools"] != nil)
        let list = try await h.call("tools/list")
        let tools = list["result"]?["tools"]?.arrayValue ?? []
        let names = Set(tools.compactMap { $0.str("name") })
        for required in ["glint_record_start", "glint_plan_zooms", "glint_apply_operations", "glint_render", "glint_inspect_render", "glint_undo", "glint_quality_report", "glint_render_frame",
                         "glint_analyze_scenes", "glint_write_narration", "glint_voiceover", "glint_fit_narration", "glint_list_voices"] {
            #expect(names.contains(required), "missing \(required)")
        }
        // Every tool has a JSON schema object and correct hints.
        for t in tools { #expect(t["inputSchema"]?.str("type") == "object") }
        // Cloud calls are external: an agent gets approval_required, never a silent upload.
        #expect(tools.first { $0.str("name") == "glint_voiceover" }?["annotations"] != nil)
        let del = tools.first { $0.str("name") == "glint_delete_project" }
        #expect(del?["annotations"]?["destructiveHint"]?.boolValue == true)
        let res = try await h.call("resources/read", .object(["uri": .string("glint://docs/operations")]))
        #expect(res["result"]?["contents"]?.arrayValue?.first?.str("text")?.contains("add_zoom") == true)
    }

    @Test func agentEditLoopThroughMCP() async throws {
        let h = MCPHarness()
        _ = try await h.call("initialize", .object(["clientInfo": .object(["name": .string("claude-test")])]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-mcp-\(UUID().uuidString.prefix(6)).glint")
        let b = try await SyntheticProject.make(at: url, duration: 5)
        let p = JSONValue.string(b.url.path)

        let info = try await h.tool("glint_project_info", ["project": p])
        #expect(info["structuredContent"]?.num("revision") == 0)

        // Plan → proposal (nothing applied yet).
        let plan = try await h.tool("glint_plan_zooms", ["project": p])
        let pid = try #require(plan["structuredContent"]?.str("proposal_id"))
        #expect(try b.readDocument().timeline.zooms.isEmpty)

        // Look at the proposal before applying: render_frame returns an image content block.
        let frame = try await h.tool("glint_render_frame", ["project": p, "time": .number(1.5), "proposal_id": .string(pid)])
        let content = frame["content"]?.arrayValue ?? []
        #expect(content.contains { $0.str("type") == "image" && ($0.str("data")?.count ?? 0) > 1000 })

        let q = try await h.tool("glint_quality_report", ["project": p, "proposal_id": .string(pid)])
        #expect(q["structuredContent"]?.num("score") != nil)

        _ = try await h.tool("glint_apply_proposal", ["project": p, "proposal_id": .string(pid)])
        #expect(!(try b.readDocument().timeline.zooms.isEmpty))

        // Stale revision is rejected as a tool error, not a crash.
        let stale = try await h.tool("glint_apply_operations", ["project": p, "expected_revision": .number(0),
                                                                "operations": .array([.object(["op": .string("add_cut"), "start": .number(4), "end": .number(4.5)])])])
        #expect(stale["isError"]?.boolValue == true)

        // Undo by the agent; history shows who did what.
        _ = try await h.tool("glint_undo", ["project": p])
        let hist = try await h.tool("glint_history", ["project": p])
        let authors = hist["structuredContent"]?["transactions"]?.arrayValue?.compactMap { $0.str("author") } ?? []
        #expect(authors.allSatisfy { $0 == "agent:claude-test" })
        #expect(authors.count == 2)
    }

    @Test func gatedActionsRequireHumanApproval() async throws {
        let h = MCPHarness()
        _ = try await h.call("initialize", .object(["clientInfo": .object(["name": .string("agent-x")])]))
        // Recording as an agent → approval_required with an id; nothing is captured.
        let r = try await h.tool("glint_record_start", ["max_duration": .number(2)])
        #expect(r["isError"]?.boolValue == true)
        #expect(r["structuredContent"]?.str("status") == "approval_required")
        let id = try #require(r["structuredContent"]?.str("approval_id"))
        #expect(h.approvals.pending().map(\.id) == [id])
        // Agents can only read the status; there is no approve tool.
        let tools = try await h.call("tools/list")
        #expect(!(tools["result"]?["tools"]?.arrayValue ?? []).contains { ($0.str("name") ?? "").contains("approve") && $0.str("name") != "glint_approval_status" })
        // Deleting a project is destructive → approval as well.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-mcp-del-\(UUID().uuidString.prefix(6)).glint")
        let b = try await SyntheticProject.make(at: url, duration: 2)
        let d = try await h.tool("glint_delete_project", ["project": .string(b.url.path)])
        #expect(d["structuredContent"]?.str("status") == "approval_required")
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        // After the human approves, the exact same call goes through once.
        let did = try #require(d["structuredContent"]?.str("approval_id"))
        _ = try h.approvals.decide(did, approve: true, by: "tester")
        let d2 = try await h.tool("glint_delete_project", ["project": .string(b.url.path), "approval_id": .string(did)])
        #expect(d2["isError"]?.boolValue == false)
        #expect(!FileManager.default.fileExists(atPath: b.url.path))
    }
}
