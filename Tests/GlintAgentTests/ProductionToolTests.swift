import Foundation
import Testing
@testable import GlintCore
@testable import GlintAgent

@Suite(.serialized) struct ProductionToolTests {
    func project(_ name: String) async throws -> ProjectBundle {
        try await SyntheticProject.make(at: FileManager.default.temporaryDirectory.appendingPathComponent("glint-pt-\(name)-\(UUID().uuidString.prefix(6)).glint"), duration: 5)
    }

    @Test func registryNamesAreUniqueAndSchemasAreObjects() {
        let names = ToolRegistry.all().map(\.name)
        #expect(Set(names).count == names.count, "duplicate tool names")
        for t in ToolRegistry.all() { #expect(t.schema["type"]?.stringValue == "object", "\(t.name)") }
        for n in ["glint_import_clip", "glint_import_audio", "glint_list_clips", "glint_export_subtitles", "glint_import_subtitles", "glint_edit_transcript",
                  "glint_list_presets", "glint_apply_preset", "glint_save_preset", "glint_recipe_save", "glint_recipe_get", "glint_recipe_build",
                  "glint_recipe_evidence", "glint_recipe_verify", "glint_recipe_refresh_scene", "glint_job_start", "glint_job_status", "glint_job_list",
                  "glint_job_cancel", "glint_job_retry"] {
            #expect(ToolRegistry.find(n) != nil, "\(n) missing")
        }
        // The operation schema lists every op kind.
        let ops = S.operation["properties"]?["op"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(ops) == Set(EditOperation.Kind.allCases.map(\.rawValue)))
    }

    @Test func callsOverMCPWithAgentAuthorAndRevisionGuard() async throws {
        let b = try await project("mcp")
        let h = MCPHarness()
        _ = try await h.call("initialize", .object(["protocolVersion": .string("2025-06-18"), "clientInfo": .object(["name": .string("prod-agent"), "version": .string("1")]), "capabilities": .object([:])]))
        let redact = try await h.tool("glint_apply_operations", ["project": .string(b.url.path), "expected_revision": .number(0), "operations": .array([
            .object(["op": .string("add_redaction"), "item": .object(["start": .number(0.5), "end": .number(2), "mode": .string("solid"),
                                                                      "rect": .object(["x": .number(0.6), "y": .number(0), "width": .number(0.4), "height": .number(0.1)])])]),
        ])])
        #expect(redact["isError"]?.boolValue != true, "\(redact)")
        // Stale revision: refused, nothing written.
        let stale = try await h.tool("glint_apply_operations", ["project": .string(b.url.path), "expected_revision": .number(0), "operations": .array([
            .object(["op": .string("add_transition"), "time": .number(1)])])])
        #expect(stale["isError"]?.boolValue == true)
        #expect(try b.readDocument().timeline.transitions.isEmpty)
        #expect(Engine(bundle: b).history().last?.author == Author(.agent, "prod-agent"))

        let clips = try await h.tool("glint_list_clips", ["project": .string(b.url.path)])
        #expect(clips["structuredContent"]?["clips"]?.arrayValue?.count == 1)
        let presets = try await h.tool("glint_apply_preset", ["project": .string(b.url.path), "name": .string("minimal")])
        #expect(presets["isError"]?.boolValue != true, "\(presets)")
        #expect(try b.readDocument().style.background.kind == .solid)
        let bad = try await h.tool("glint_recipe_save", ["project": .string(b.url.path), "recipe": .object(["title": .string("x"), "scenes": .array([])])])
        #expect(bad["isError"]?.boolValue == true)
    }

    @Test func autopilotReportsNeedsReviewWithoutARecipeAndFailsRequiredSteps() async throws {
        let b = try await project("auto")
        let s = GlintService()
        let ctx = ToolContext(author: Author(.agent, "t"), service: s)
        let out = try await ToolRegistry.call("glint_autopilot", arguments: .object(["project": .string(b.url.path)]), context: ctx)
        #expect(out.json["status"]?.stringValue == "needs_review", "\(out.json["status"] ?? .null)")
        #expect(out.json["review"]?.arrayValue?.contains { $0.stringValue?.contains("No recipe") == true } == true)
        // Asking for captions on a take with no speech is a failed required step, not a silent skip.
        let failed = try await ToolRegistry.call("glint_autopilot", arguments: .object(["project": .string(b.url.path), "captions": .bool(true)]), context: ctx)
        #expect(failed.json["status"]?.stringValue == "failed")
        #expect(failed.json["failed_steps"]?.arrayValue?.contains(.string("captions")) == true)
        // A stale expected_revision stops it before any change.
        await #expect(throws: EditError.self) {
            _ = try await ToolRegistry.call("glint_autopilot", arguments: .object(["project": .string(b.url.path), "expected_revision": .number(0)]), context: ctx)
        }
    }

    @Test func transcriptEditAndSubtitleToolsRoundTrip() async throws {
        let b = try await project("subs")
        try b.writeTranscript(Transcript(engine: "test", locale: "en-US", source: "microphone", words: [
            CaptionWord(text: "Here", start: 0.2, end: 0.5), CaptionWord(text: "um", start: 0.7, end: 0.9), CaptionWord(text: "we", start: 1.2, end: 1.4), CaptionWord(text: "go", start: 1.5, end: 1.8)]))
        let ctx = ToolContext(author: .cli, service: GlintService())
        let cut = try await ToolRegistry.call("glint_edit_transcript", arguments: .object(["project": .string(b.url.path), "phrase": .string("um"), "apply": .bool(true)]), context: ctx)
        #expect(cut.json["removed"]?.arrayValue == [.string("um")])
        let c = try #require(try b.readDocument().timeline.cuts.first)
        #expect(c.start >= 0.5 && c.end <= 1.2)
        try Engine(bundle: b).apply(try GlintService().captionOps(b), author: .cli)
        let exp = try await ToolRegistry.call("glint_export_subtitles", arguments: .object(["project": .string(b.url.path), "format": .string("srt")]), context: ctx)
        let path = try #require(exp.json["path"]?.stringValue)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("-->"))
        let imp = try await ToolRegistry.call("glint_import_subtitles", arguments: .object(["project": .string(b.url.path), "file": .string(path)]), context: ctx)
        #expect(imp.json["applied"] != nil)
    }
}
