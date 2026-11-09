import Foundation
import GlintCore
import GlintCapture
import GlintRender
import GlintAnalysis

/// What a tool returns: JSON for the agent, optional images (frames, contact sheets) it can look at.
public struct ToolOutput: Sendable {
    public var json: JSONValue
    public var images: [URL] = []
    public init(json: JSONValue, images: [URL] = []) { self.json = json; self.images = images }
    public static func encode<T: Encodable>(_ v: T, images: [URL] = []) throws -> ToolOutput { ToolOutput(json: try JSONValue.from(v), images: images) }
}

public struct ToolContext: Sendable {
    public var author: Author
    public var service: GlintService
    public var progress: (@Sendable (String) -> Void)?
    public init(author: Author, service: GlintService, progress: (@Sendable (String) -> Void)? = nil) {
        self.author = author; self.service = service; self.progress = progress
    }
}

public struct ToolSpec: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var risk: Risk
    public var schema: JSONValue
    public var readOnly: Bool { risk == .read }
    public var handler: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput
}

// MARK: - Schema helpers

enum S {
    static func obj(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    static func str(_ d: String, enumValues: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(d)]
        if let e = enumValues { o["enum"] = .array(e.map(JSONValue.string)) }
        return .object(o)
    }
    static func num(_ d: String) -> JSONValue { .object(["type": .string("number"), "description": .string(d)]) }
    static func int(_ d: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(d)]) }
    static func bool(_ d: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(d)]) }
    static func arr(_ d: String, _ items: JSONValue) -> JSONValue { .object(["type": .string("array"), "description": .string(d), "items": items]) }
    static let project = str("Project: path to a .glint bundle, a project name, or \"latest\" (default).")
    static let proposal = str("Optional proposal ID: preview the project as if this pending proposal were applied.")
    static let approval = str("Approval request ID, after the user approved it (only for gated actions).")
    static let variant = str("Render preset: landscape, landscape-4k, square, portrait, gif, preview.", enumValues: Array(RenderVariant.presets.keys).sorted())
    static let operation: JSONValue = .object([
        "type": .string("object"),
        "description": .string("An edit. Fields depend on op; times are source seconds unless time_base is \"output\". See glint://docs/operations."),
        "properties": .object([
            "op": str("Operation", enumValues: EditOperation.Kind.allCases.map(\.rawValue)),
            "id": str("Target item ID (update/remove) or desired ID (add)"),
            "start": num("Range start, seconds"), "end": num("Range end, seconds"), "time": num("Instant, seconds"),
            "scale": num("Zoom magnification 1–6"), "focus": .object(["description": .string("\"cursor\" or {\"x\":0..1,\"y\":0..1}")]),
            "rate": num("Playback rate 0.1–16"), "path": str("set_style path, e.g. background.preset, cursor.scale, zoom.stiffness, canvas.aspect"),
            "value": .object(["description": .string("set_style value (number, string, bool, \"#RRGGBB\", array)")]),
            "text": str("Text (rename, update_caption, add_marker note)"), "hidden": bool("Hide caption"),
            "reason": str("Why — shown to the user in history and on the timeline"),
            "origin": str("auto | manual | agent (clear_* filter, or origin of added item)"),
            "items": arr("Caption segments for set_captions", .object(["type": .string("object")])),
            "time_base": str("source (default) or output", enumValues: ["source", "output"]),
        ]),
        "required": .array([.string("op")]),
    ])
}

extension JSONValue {
    public func str(_ k: String) -> String? { self[k]?.stringValue }
    public func num(_ k: String) -> Double? { self[k]?.doubleValue }
    public func flag(_ k: String) -> Bool? { self[k]?.boolValue }
}

// MARK: - Registry

public enum ToolRegistry {
    public static func all() -> [ToolSpec] { tools }

    public static func find(_ name: String) -> ToolSpec? {
        let n = name.hasPrefix("glint_") ? name : "glint_" + name
        return tools.first { $0.name == n }
    }

    /// Run a tool with approval gating applied by risk class.
    public static func call(_ name: String, arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let spec = find(name) else { throw ServiceError.invalid("Unknown tool \(name). Run `glint tools` for the list.") }
        return try await spec.handler(arguments.objectValue == nil ? .object([:]) : arguments, context)
    }

    static func variants(_ args: JSONValue) throws -> [RenderVariant] {
        let names = args["variants"]?.arrayValue?.compactMap(\.stringValue) ?? args.str("variant").map { [$0] } ?? ["landscape"]
        return try names.map { n in
            guard let v = RenderVariant.preset(n) else { throw ServiceError.invalid("Unknown variant \(n). Presets: \(RenderVariant.presets.keys.sorted().joined(separator: ", "))") }
            return v
        }
    }

    static func ops(_ args: JSONValue) throws -> [EditOperation] {
        guard let raw = args["operations"] else { throw ServiceError.invalid("operations is required") }
        do { return try raw.decode([EditOperation].self) } catch { throw ServiceError.invalid("operations didn't parse: \(error)") }
    }

    static let tools: [ToolSpec] = [
        // MARK: Inspect
        ToolSpec(name: "glint_list_sources", title: "List capture sources", description: "Displays and windows that can be recorded, with IDs and sizes.", risk: .read,
                 schema: S.obj([:])) { _, _ in try .encode(try await Sources.list()) },
        ToolSpec(name: "glint_list_projects", title: "List projects", description: "Recent Glint projects (newest first) with duration and revision.", risk: .read,
                 schema: S.obj(["limit": S.int("Max results (default 20)")])) { a, c in
            let urls = c.service.listProjectURLs().prefix(Int(a.num("limit") ?? 20))
            return try .encode(urls.compactMap { try? c.service.summary(ProjectBundle(url: $0)) })
        },
        ToolSpec(name: "glint_project_info", title: "Project summary", description: "Revision, durations, media, item counts, pending proposals, undo state. Start here.", risk: .read,
                 schema: S.obj(["project": S.project])) { a, c in try .encode(try c.service.summary(try c.service.resolve(a.str("project")))) },
        ToolSpec(name: "glint_get_timeline", title: "Get timeline", description: "Full edit document (timeline + style) and the source→output time map. Use the revision as expected_revision when editing.", risk: .read,
                 schema: S.obj(["project": S.project, "proposal_id": S.proposal])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let doc = try c.service.document(b, proposal: a.str("proposal_id"))
            let map = TimeMap(document: doc)
            return ToolOutput(json: .object(["document": try JSONValue.from(doc), "output_duration": .number(map.outputDuration),
                                             "time_map": try JSONValue.from(map.pieces)]))
        },
        ToolSpec(name: "glint_get_events", title: "Get input activity", description: "What the user did while recording: clicks (with positions/targets), typing bursts, scrolls, idle stretches, app switches, markers. Source time.", risk: .read,
                 schema: S.obj(["project": S.project, "start": S.num("From (source s)"), "end": S.num("To (source s)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let doc = try b.readDocument()
            var s = Activity.summarize(b.readEvents(), duration: doc.media.duration)
            let r = TimeRange(a.num("start") ?? 0, a.num("end") ?? .infinity)
            s.clicks = s.clicks.filter { r.contains($0.t) }
            s.typing = s.typing.filter { r.contains($0.start) }
            s.idle = s.idle.filter { $0.overlaps(r) }
            return try .encode(s)
        },
        ToolSpec(name: "glint_get_transcript", title: "Get transcript", description: "Word-timed transcript (source time), if transcribed.", risk: .read,
                 schema: S.obj(["project": S.project, "words": S.bool("Include per-word timings (default false: text + sentences)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            guard let t = b.readTranscript() else { return ToolOutput(json: .object(["transcript": .null, "hint": .string("Run glint_transcribe first")])) }
            if a.flag("words") == true { return try .encode(t) }
            let caps = CaptionBuilder.segments(from: t.words, maxChars: 120, maxDuration: 12, pauseBreak: 0.9)
            return ToolOutput(json: .object(["engine": .string(t.engine), "text": .string(t.text),
                                             "sentences": .array(caps.map { .object(["start": .number($0.start), "end": .number($0.end), "text": .string($0.text)]) })]))
        },
        ToolSpec(name: "glint_history", title: "Edit history", description: "Transactions with author (user/agent), label and changed paths; plus undo/redo stacks.", risk: .read,
                 schema: S.obj(["project": S.project, "limit": S.int("Most recent N (default 30)")])) { a, c in
            let e = c.service.engine(try c.service.resolve(a.str("project")))
            let h = e.history().suffix(Int(a.num("limit") ?? 30))
            let st = e.stacks()
            return ToolOutput(json: .object([
                "transactions": .array(h.map { r in .object(["id": .string(r.id), "kind": .string(r.kind.rawValue), "label": .string(r.label), "author": .string(r.author.description),
                                                              "date": .string(ISO8601DateFormatter().string(from: r.date)), "revision": .number(Double(r.revision)),
                                                              "changes": .number(Double(r.forward.count)), "proposal_id": r.proposalID.map(JSONValue.string) ?? .null,
                                                              "target": r.target.map(JSONValue.string) ?? .null]) }),
                "undo_stack": .array(st.undo.map(JSONValue.string)), "redo_stack": .array(st.redo.map(JSONValue.string)),
            ]))
        },
        ToolSpec(name: "glint_quality_report", title: "Edit quality report", description: "Measurable checks on the edit without rendering: zoom coverage/pumping/duration, cursor-in-view while zoomed, camera speed, dead air, jump fragments, caption reading speed, duration vs target. Each failing check includes a fix.", risk: .read,
                 schema: S.obj(["project": S.project, "proposal_id": S.proposal, "target_duration": S.num("Desired output length in seconds")])) { a, c in
            try .encode(try c.service.quality(try c.service.resolve(a.str("project")), proposal: a.str("proposal_id"), targetDuration: a.num("target_duration")))
        },
        ToolSpec(name: "glint_render_frame", title: "Render a frame", description: "Render the edited output at an output time to PNG and return it as an image — see exactly what viewers will see (optionally with a proposal applied or as a variant).", risk: .reversible,
                 schema: S.obj(["project": S.project, "time": S.num("Output time in seconds"), "proposal_id": S.proposal, "variant": S.variant], required: ["time"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let v = try a.str("variant").map { _ in try variants(a)[0] }
            let url = try await c.service.renderFrame(b, time: a.num("time") ?? 0, proposal: a.str("proposal_id"), variant: v)
            return ToolOutput(json: .object(["path": .string(url.path), "time": .number(a.num("time") ?? 0)]), images: [url])
        },
        ToolSpec(name: "glint_contact_sheet", title: "Contact sheet", description: "Grid of N evenly spaced (or given) output frames as one image with timestamps — review pacing and framing at a glance.", risk: .reversible,
                 schema: S.obj(["project": S.project, "count": S.int("Frames (default 12, max 48)"), "times": S.arr("Specific output times", S.num("s")), "proposal_id": S.proposal, "variant": S.variant])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let v = try a.str("variant").map { _ in try variants(a)[0] }
            let (url, ts) = try await c.service.contactSheet(b, count: Int(a.num("count") ?? 12), proposal: a.str("proposal_id"), variant: v,
                                                              times: a["times"]?.arrayValue?.compactMap(\.doubleValue))
            return ToolOutput(json: .object(["path": .string(url.path), "times": .array(ts.map { .number(($0 * 100).rounded() / 100) })]), images: [url])
        },
        ToolSpec(name: "glint_inspect_render", title: "Inspect a rendered file", description: "Measure an output: duration, resolution, fps, codec, bitrate, black/frozen frames, sharpness, motion, loudness (LUFS), clipping — with pass/warn/fail verdicts.", risk: .read,
                 schema: S.obj(["path": S.str("Rendered file path"), "expected_duration": S.num("Compare against (s)")], required: ["path"])) { a, _ in
            guard let p = a.str("path") else { throw ServiceError.invalid("path is required") }
            return try .encode(try await RenderInspector.inspect(url: URL(fileURLWithPath: (p as NSString).expandingTildeInPath), expectedDuration: a.num("expected_duration")))
        },
        ToolSpec(name: "glint_list_renders", title: "List renders", description: "Previous renders of a project with their measured reports.", risk: .read,
                 schema: S.obj(["project": S.project])) { a, c in try .encode(c.service.renders(try c.service.resolve(a.str("project")))) },
        ToolSpec(name: "glint_list_proposals", title: "List proposals", description: "Edit proposals and their status (pending/applied/rejected).", risk: .read,
                 schema: S.obj(["project": S.project, "status": S.str("Filter", enumValues: ["pending", "applied", "rejected"])])) { a, c in
            var ps = c.service.engine(try c.service.resolve(a.str("project"))).proposals()
            if let s = a.str("status") { ps = ps.filter { $0.status.rawValue == s } }
            return try .encode(ps)
        },

        // MARK: Plan (proposals by default)
        ToolSpec(name: "glint_plan_zooms", title: "Plan automatic zooms", description: "Derive zooms from clicks/typing (anticipating actions, merging nearby ones, avoiding out-in pumping). Creates a proposal unless apply=true. Manual and agent zooms are kept; previous auto zooms are replaced.", risk: .reversible,
                 schema: S.obj(["project": S.project, "scale": S.num("Max magnification (default 2.0)"), "lead_in": S.num("Seconds before the action (0.7)"),
                                "hold": S.num("Seconds after (1.6)"), "include_typing": S.bool("Zoom on typing (true)"), "include_scrolls": S.bool("Zoom on scrolling (false)"),
                                "apply": S.bool("Apply immediately (undoable) instead of proposing")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            var o = ZoomPlanOptions()
            if let v = a.num("scale") { o.scale = v }
            if let v = a.num("lead_in") { o.leadIn = v }
            if let v = a.num("hold") { o.hold = v }
            if let v = a.flag("include_typing") { o.includeTyping = v }
            if let v = a.flag("include_scrolls") { o.includeScrolls = v }
            let (ops, zooms) = try c.service.planZooms(b, options: o)
            guard !zooms.isEmpty else { return ToolOutput(json: .object(["zooms": .array([]), "note": .string("No clicks or typing to zoom on in the kept range")])) }
            return try finish(b, ops: ops, title: "Auto zoom: \(zooms.count) zoom\(zooms.count == 1 ? "" : "s")",
                              rationale: zooms.map { "\(String(format: "%.1f–%.1fs", $0.start, $0.end)) \(String(format: "%.1f×", $0.scale)): \($0.reason ?? "")" }.joined(separator: "\n"),
                              apply: a.flag("apply") == true, c, extra: ["zooms": try JSONValue.from(zooms)])
        },
        ToolSpec(name: "glint_plan_cuts", title: "Plan cuts and speed-ups", description: "Shorten pauses (silence on the mic), drop filler words, speed up silent typing / idle waiting, trim dead ends. Creates a proposal unless apply=true.", risk: .reversible,
                 schema: S.obj(["project": S.project, "min_silence": S.num("Shortest pause to cut (1.0s)"), "padding": S.num("Kept on each side (0.3s)"),
                                "idle_rate": S.num("Speed for idle stretches (4×)"), "typing_rate": S.num("Speed for silent typing (2.5×)"),
                                "remove_fillers": S.bool("Cut um/uh (true)"), "trim_ends": S.bool("Trim start/end (true)"), "apply": S.bool("Apply immediately")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            var o = CutPlanOptions()
            if let v = a.num("min_silence") { o.minSilence = v }
            if let v = a.num("padding") { o.padding = v }
            if let v = a.num("idle_rate") { o.idleRate = v }
            if let v = a.num("typing_rate") { o.typingRate = v }
            if let v = a.flag("remove_fillers") { o.removeFillers = v }
            if let v = a.flag("trim_ends") { o.trimEnds = v }
            let (ops, plan) = try await c.service.planCuts(b, options: o)
            guard !ops.isEmpty else { return ToolOutput(json: .object(["note": .string("Nothing worth cutting")])) }
            return try finish(b, ops: ops, title: "Tighten: \(plan.cuts.count) cut\(plan.cuts.count == 1 ? "" : "s"), \(plan.speeds.count) speed-up\(plan.speeds.count == 1 ? "" : "s")",
                              rationale: (plan.cuts.map { "cut \(String(format: "%.1f–%.1fs", $0.start, $0.end)): \($0.reason ?? "")" }
                                          + plan.speeds.map { "\(String(format: "%.1f×", $0.rate)) \(String(format: "%.1f–%.1fs", $0.start, $0.end)): \($0.reason ?? "")" }
                                          + plan.notes).joined(separator: "\n"),
                              apply: a.flag("apply") == true, c, extra: ["plan": try JSONValue.from(plan)])
        },
        ToolSpec(name: "glint_transcribe", title: "Transcribe", description: "On-device speech-to-text with word timings (Apple SpeechTranscriber; whisper CLI fallback). Saves transcript.json.", risk: .reversible,
                 schema: S.obj(["project": S.project, "locale": S.str("e.g. en-US (default)"), "engine": S.str("auto | apple | whisper", enumValues: ["auto", "apple", "whisper"]),
                                "source": S.str("microphone | system", enumValues: ["microphone", "system"])])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let t = try await c.service.transcribe(b, locale: a.str("locale") ?? "en-US", engine: Transcriber.Engine(rawValue: a.str("engine") ?? "auto") ?? .auto, source: a.str("source"))
            return ToolOutput(json: .object(["engine": .string(t.engine), "words": .number(Double(t.words.count)), "text": .string(t.text)]))
        },
        ToolSpec(name: "glint_generate_captions", title: "Generate captions", description: "Turn the transcript into readable caption lines (≤ max chars, sentence/pause breaks). Creates a proposal unless apply=true.", risk: .reversible,
                 schema: S.obj(["project": S.project, "look": S.str("highlight | pill | plain", enumValues: ["highlight", "pill", "plain"]), "apply": S.bool("Apply immediately")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            var ops = try c.service.captionOps(b)
            if let look = a.str("look") { ops.append(.style("captions.look", .string(look))) }
            let n = ops.first?.items?.count ?? 0
            return try finish(b, ops: ops, title: "Captions: \(n) line\(n == 1 ? "" : "s")", rationale: ops.first?.items?.prefix(6).map(\.text).joined(separator: " / ") ?? "",
                              apply: a.flag("apply") == true, c, extra: [:])
        },

        // MARK: Edit (reversible)
        ToolSpec(name: "glint_propose_edits", title: "Propose edits", description: "Create a reviewable proposal from operations (validated now, applied only when accepted). Preferred for non-trivial changes: the user sees title + rationale in the app.", risk: .reversible,
                 schema: S.obj(["project": S.project, "title": S.str("Short title"), "rationale": S.str("Why — what it fixes / how you measured it"),
                                "operations": S.arr("Edits", S.operation)], required: ["title", "operations"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let p = try c.service.engine(b).propose(title: a.str("title") ?? "Edits", rationale: a.str("rationale") ?? "", operations: try ops(a), author: c.author)
            return try .encode(p)
        },
        ToolSpec(name: "glint_apply_proposal", title: "Apply proposal", description: "Apply a pending proposal as one undoable transaction.", risk: .reversible,
                 schema: S.obj(["project": S.project, "proposal_id": S.str("Proposal ID")], required: ["proposal_id"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try .encode(try c.service.engine(b).applyProposal(a.str("proposal_id") ?? "", author: c.author))
        },
        ToolSpec(name: "glint_reject_proposal", title: "Reject proposal", description: "Mark a pending proposal rejected.", risk: .reversible,
                 schema: S.obj(["project": S.project, "proposal_id": S.str("Proposal ID")], required: ["proposal_id"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try .encode(try c.service.engine(b).rejectProposal(a.str("proposal_id") ?? "", author: c.author))
        },
        ToolSpec(name: "glint_apply_operations", title: "Apply edits", description: "Apply operations now as one undoable transaction. Pass expected_revision (from get_timeline/project_info) to avoid overwriting concurrent edits.", risk: .reversible,
                 schema: S.obj(["project": S.project, "operations": S.arr("Edits", S.operation), "label": S.str("History label"),
                                "expected_revision": S.int("Fail if the project changed since this revision")], required: ["operations"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try .encode(try c.service.engine(b).apply(try ops(a), label: a.str("label"), author: c.author, expectedRevision: a.num("expected_revision").map { Int($0) }))
        },
        ToolSpec(name: "glint_undo", title: "Undo", description: "Undo the latest transaction (any author).", risk: .reversible, schema: S.obj(["project": S.project])) { a, c in
            try .encode(try c.service.engine(try c.service.resolve(a.str("project"))).undo(author: c.author))
        },
        ToolSpec(name: "glint_redo", title: "Redo", description: "Redo the last undone transaction.", risk: .reversible, schema: S.obj(["project": S.project])) { a, c in
            try .encode(try c.service.engine(try c.service.resolve(a.str("project"))).redo(author: c.author))
        },
        ToolSpec(name: "glint_revert", title: "Revert a transaction", description: "Selectively undo one earlier transaction if what it touched hasn't changed since (reports a conflict otherwise).", risk: .reversible,
                 schema: S.obj(["project": S.project, "transaction_id": S.str("Transaction ID from glint_history")], required: ["transaction_id"])) { a, c in
            try .encode(try c.service.engine(try c.service.resolve(a.str("project"))).revert(a.str("transaction_id") ?? "", author: c.author))
        },

        // MARK: Render (writes new files inside the project)
        ToolSpec(name: "glint_render", title: "Render variants", description: "Export one or more deliverables into the project's renders/ folder and measure each (duration, black/frozen frames, sharpness, loudness…). Optional proposal preview.", risk: .reversible,
                 schema: S.obj(["project": S.project, "variants": S.arr("Presets (default [landscape])", S.variant), "proposal_id": S.proposal,
                                "inspect": S.bool("Measure outputs (default true)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let m = try await c.service.render(b, variants: try variants(a), proposal: a.str("proposal_id"), author: c.author, inspect: a.flag("inspect") ?? true) { name, p in
                c.progress?("\(name) \(Int(p * 100))%")
            }
            return try .encode(m)
        },

        // MARK: Gated
        ToolSpec(name: "glint_export", title: "Export file", description: "Copy a rendered file to a destination outside the project. Overwriting an existing file requires user approval.", risk: .destructive,
                 schema: S.obj(["file": S.str("Rendered file path"), "destination": S.str("Destination file or folder"), "approval_id": S.approval], required: ["file", "destination"])) { a, c in
            let out = try c.service.export(file: URL(fileURLWithPath: ((a.str("file") ?? "") as NSString).expandingTildeInPath),
                                           to: URL(fileURLWithPath: ((a.str("destination") ?? "") as NSString).expandingTildeInPath), author: c.author, approvalID: a.str("approval_id"))
            return ToolOutput(json: .object(["exported": .string(out.path)]))
        },
        ToolSpec(name: "glint_delete_project", title: "Delete project", description: "Move a project to the Trash. Always requires user approval.", risk: .destructive,
                 schema: S.obj(["project": S.project, "approval_id": S.approval], required: ["project"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let r = try c.service.deleteProject(b, author: c.author, approvalID: a.str("approval_id"))
            return ToolOutput(json: .object(["trashed": .string(r?.path ?? b.url.path)]))
        },
        ToolSpec(name: "glint_record_start", title: "Start recording", description: "Record a display or window (screen + input events, optional mic/system audio) into a new project. Agents need user approval unless the user's policy allows capture.", risk: .capture,
                 schema: S.obj(["display_id": S.int("Display ID (default main)"), "window_id": S.int("Window ID (from list_sources)"), "microphone": S.bool("Record mic (false)"),
                                "system_audio": S.bool("Record system audio (true)"), "max_duration": S.num("Auto-stop after N seconds"), "name": S.str("Project name"),
                                "approval_id": S.approval])) { a, c in
            var o = RecordingOptions()
            o.displayID = a.num("display_id").map { UInt32($0) }
            o.windowID = a.num("window_id").map { UInt32($0) }
            o.microphone = a.flag("microphone") ?? false
            o.systemAudio = a.flag("system_audio") ?? true
            o.maxDuration = a.num("max_duration")
            o.projectName = a.str("name")
            let (id, s) = try await c.service.startRecording(options: o, author: c.author, approvalID: a.str("approval_id"))
            return ToolOutput(json: .object(["session_id": .string(id), "project": .string(s.bundle.url.path), "source": .string("\(s.source.kind.rawValue) \(s.source.id) \(s.source.name)")]))
        },
        ToolSpec(name: "glint_record_status", title: "Recording status", description: "Active recording: elapsed seconds and frames.", risk: .read, schema: S.obj(["session_id": S.str("Session ID")])) { a, c in
            guard let (id, s) = c.service.session(a.str("session_id")) else {
                return ToolOutput(json: .object(["recording": .bool(false), "other_sessions": try JSONValue.from(SessionRegistry.active())]))
            }
            return ToolOutput(json: .object(["recording": .bool(s.isRecording), "session_id": .string(id), "elapsed": .number(s.elapsed), "frames": .number(Double(s.frames)), "project": .string(s.bundle.url.path)]))
        },
        ToolSpec(name: "glint_record_mark", title: "Mark moment", description: "Drop a labelled marker into the active recording (e.g. 'opened settings') — planners and reviewers use it.", risk: .reversible,
                 schema: S.obj(["session_id": S.str("Session ID"), "note": S.str("What's happening")], required: ["note"])) { a, c in
            guard let (_, s) = c.service.session(a.str("session_id")) else { throw ServiceError.invalid("No active recording") }
            return try .encode(s.mark(a.str("note") ?? ""))
        },
        ToolSpec(name: "glint_record_stop", title: "Stop recording", description: "Stop and finalize the recording; returns the new project.", risk: .reversible, schema: S.obj(["session_id": S.str("Session ID")])) { a, c in
            let b = try await c.service.stopRecording(a.str("session_id"))
            return try .encode(try c.service.summary(b))
        },
        ToolSpec(name: "glint_approval_status", title: "Approval status", description: "Check whether the user approved a pending request (agents cannot approve).", risk: .read,
                 schema: S.obj(["approval_id": S.str("Request ID")], required: ["approval_id"])) { a, c in
            guard let r = c.service.approvals.get(a.str("approval_id") ?? "") else { throw ServiceError.invalid("No such approval request") }
            return try .encode(r)
        },

        // MARK: Workflow
        ToolSpec(name: "glint_autopilot", title: "Make a polished demo", description: "One call: transcribe (if there's a voice track), plan cuts, plan zooms, add captions, check quality, and (optionally) render variants. Edits are applied as separate undoable transactions labelled by step, or left as proposals with propose_only.", risk: .reversible,
                 schema: S.obj(["project": S.project, "variants": S.arr("Render presets (default none)", S.variant), "propose_only": S.bool("Leave edits as proposals"),
                                "target_duration": S.num("Desired length (s), for the quality check"), "captions": S.bool("Add captions when speech exists (true)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try await Autopilot.run(b, args: a, context: c)
        },
    ]

    /// Propose or apply, with a uniform result shape.
    static func finish(_ b: ProjectBundle, ops: [EditOperation], title: String, rationale: String, apply: Bool, _ c: ToolContext, extra: [String: JSONValue]) throws -> ToolOutput {
        let e = c.service.engine(b)
        var out = extra
        if apply {
            let r = try e.apply(ops, label: title, author: c.author)
            out["applied"] = try JSONValue.from(r)
        } else {
            let p = try e.propose(title: title, rationale: rationale, operations: ops, author: c.author)
            out["proposal_id"] = .string(p.id)
            out["status"] = .string("pending")
            out["next"] = .string("Preview with glint_render_frame/glint_contact_sheet (proposal_id), check glint_quality_report, then glint_apply_proposal.")
        }
        out["title"] = .string(title)
        return ToolOutput(json: .object(out))
    }
}

/// The end-to-end "turn a raw take into a polished demo" workflow, built only from public service calls.
public enum Autopilot {
    public static func run(_ b: ProjectBundle, args a: JSONValue, context c: ToolContext) async throws -> ToolOutput {
        var steps: [JSONValue] = []
        let proposeOnly = a.flag("propose_only") == true
        let s = c.service
        func step(_ name: String, _ detail: JSONValue) { steps.append(.object(["step": .string(name), "result": detail])); c.progress?(name) }
        func commit(_ ops: [EditOperation], _ title: String) throws -> JSONValue {
            guard !ops.isEmpty else { return .string("nothing to do") }
            let e = s.engine(b)
            if proposeOnly { return .string(try e.propose(title: title, rationale: "autopilot", operations: ops, author: c.author).id) }
            return try JSONValue.from(try e.apply(ops, label: title, author: c.author))
        }
        let doc = try b.readDocument()
        if doc.media.microphone != nil || doc.media.systemAudio != nil, b.readTranscript() == nil {
            do {
                let t = try await s.transcribe(b, locale: "en-US", engine: .auto, source: nil)
                step("transcribe", .string("\(t.words.count) words via \(t.engine)"))
            } catch { step("transcribe", .string("skipped: \(error)")) }
        }
        let (cutOps, plan) = try await s.planCuts(b, options: CutPlanOptions())
        step("plan_cuts", try commit(cutOps, "Autopilot: tighten (\(plan.cuts.count) cuts, \(plan.speeds.count) speed-ups)"))
        let (zoomOps, zooms) = try s.planZooms(b, options: ZoomPlanOptions())
        step("plan_zooms", try commit(zoomOps, "Autopilot: \(zooms.count) zooms"))
        if a.flag("captions") ?? true, let t = b.readTranscript(), t.words.count >= 3 {
            step("captions", try commit(try s.captionOps(b), "Autopilot: captions"))
        }
        let q = try s.quality(b, proposal: nil, targetDuration: a.num("target_duration"))
        step("quality", try JSONValue.from(q))
        var renders: JSONValue = .null
        if let vs = a["variants"]?.arrayValue, !vs.isEmpty, !proposeOnly {
            let m = try await s.render(b, variants: try ToolRegistry.variants(a), proposal: nil, author: c.author)
            renders = try JSONValue.from(m)
        }
        return ToolOutput(json: .object(["steps": .array(steps), "render": renders, "summary": try JSONValue.from(try s.summary(b))]))
    }
}
