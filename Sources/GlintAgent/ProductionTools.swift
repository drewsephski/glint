import Foundation
import GlintCore
import GlintRender

/// Tools for multi-shot editing, audio, captions, presets, recipes/evidence and durable jobs.
enum ProductionTools {
    static func file(_ a: JSONValue, _ k: String = "file") throws -> URL {
        guard let p = a.str(k), !p.isEmpty else { throw ServiceError.invalid("\(k) is required") }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    static func rev(_ a: JSONValue) -> Int? { a.num("expected_revision").map { Int($0) } }

    /// Apply now (default) or propose, with the uniform result shape.
    static func commit(_ b: ProjectBundle, _ ops: [EditOperation], title: String, apply: Bool, _ c: ToolContext, expectedRevision: Int?, extra: [String: JSONValue] = [:]) throws -> ToolOutput {
        var out = extra
        let e = c.service.engine(b)
        if apply {
            out["applied"] = try JSONValue.from(try e.apply(ops, label: title, author: c.author, expectedRevision: expectedRevision))
        } else {
            let p = try e.propose(title: title, rationale: extra["rationale"]?.stringValue ?? "", operations: ops, author: c.author)
            out["proposal_id"] = .string(p.id); out["status"] = .string("pending")
        }
        out["title"] = .string(title)
        return ToolOutput(json: .object(out))
    }

    /// In-process registry so one server never runs the same job twice at once.
    final class Running: @unchecked Sendable {
        static let shared = Running()
        private var ids = Set<String>()
        private let lock = NSLock()
        func claim(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
        func release(_ id: String) { _ = lock.withLock { ids.remove(id) } }
    }

    static func launch(_ s: GlintService, _ b: ProjectBundle, _ job: Job, wait: Bool, _ c: ToolContext) async throws -> ToolOutput {
        let id = job.id
        // An existing job (same idempotency key) that already ran or is running elsewhere is just reported.
        guard job.status == .queued else { return try .encode(job) }
        guard Running.shared.claim(id) else { return try .encode(try JobStore(bundle: b).get(id)) }
        if wait {
            defer { Running.shared.release(id) }
            return try .encode(await JobRunner.run(s, b, id, progress: c.progress))
        }
        Task.detached {
            await JobRunner.run(s, b, id)
            Running.shared.release(id)
        }
        var j = try JSONValue.from(try JobStore(bundle: b).get(id))
        if case .object(var o) = j { o["next"] = .string("Poll glint_job_status with job_id \(id); glint_job_cancel to stop it."); j = .object(o) }
        return ToolOutput(json: j)
    }

    static let specs: [ToolSpec] = [
        // MARK: Shots
        ToolSpec(name: "glint_list_clips", title: "List shots", description: "The program's shots in order with their program start/end (source seconds), file ranges, recipe scenes and takes. A project that is one recording has one shot.", risk: .read,
                 schema: S.obj(["project": S.project, "proposal_id": S.proposal])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let doc = try c.service.document(b, proposal: a.str("proposal_id"))
            return ToolOutput(json: .object(["revision": .number(Double(doc.revision)), "duration": .number(doc.duration),
                                             "clips": .array(try ClipLayout(document: doc).segments.map { s in
                                                 var o = try JSONValue.from(s.clip).objectValue ?? [:]
                                                 o["program_start"] = .number(s.start); o["program_end"] = .number(s.end)
                                                 return .object(o)
                                             })]))
        },
        ToolSpec(name: "glint_import_clip", title: "Import a shot", description: "Add a movie file as a shot: copied into the project (the original is untouched) and inserted at a program time (default: the end). Existing edits keep their content. Use start/end to use part of the file. Applied as an undoable transaction unless apply=false.", risk: .reversible,
                 schema: S.obj(["project": S.project, "file": S.str("Movie file (mov, mp4, m4v)"), "at": S.num("Program time to insert at (source seconds; default end)"),
                                "name": S.str("Shot name"), "scene": S.str("Recipe scene ID this shot shows"), "start": S.num("Use the file from (s)"), "end": S.num("…to (s)"),
                                "apply": S.bool("Apply now (true) or propose"), "expected_revision": S.int("Fail if the project changed")], required: ["file"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let (op, clip) = try await c.service.importClip(b, file: try file(a), at: a.num("at"), name: a.str("name"), scene: a.str("scene"), start: a.num("start"), end: a.num("end"))
            return try commit(b, [op], title: "Import “\(clip.name)”", apply: a.flag("apply") ?? true, c, expectedRevision: rev(a), extra: ["clip": try JSONValue.from(clip)])
        },
        ToolSpec(name: "glint_import_audio", title: "Import audio", description: "Add a music bed (loops, fades, ducks under narration by default), a recorded voiceover (ducks the recording like generated narration) or a sound effect at a program time. The file is copied into the project.", risk: .reversible,
                 schema: S.obj(["project": S.project, "file": S.str("Audio file (m4a, mp3, wav, aiff)"), "kind": S.str("music | voice | effect", enumValues: ["music", "voice", "effect"]),
                                "at": S.num("Program time to start at (0)"), "name": S.str("Name"), "gain": S.num("Level 0–3 (music 0.35, others 1)"), "loop": S.bool("Repeat to fill the video (music: true)"),
                                "apply": S.bool("Apply now (true) or propose"), "expected_revision": S.int("Fail if the project changed")], required: ["file", "kind"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            guard let k = AudioClip.Kind(rawValue: a.str("kind") ?? "") else { throw ServiceError.invalid("kind must be music, voice or effect") }
            let (op, clip) = try await c.service.importAudio(b, file: try file(a), kind: k, at: a.num("at") ?? 0, name: a.str("name"), gain: a.num("gain"), loop: a.flag("loop"))
            return try commit(b, [op], title: "Add \(k.rawValue) “\(clip.name)”", apply: a.flag("apply") ?? true, c, expectedRevision: rev(a), extra: ["audio": try JSONValue.from(clip)])
        },

        // MARK: Captions
        ToolSpec(name: "glint_export_subtitles", title: "Export subtitles", description: "Write the captions as SRT or WebVTT timed to the EDITED output (cuts and speed changes applied), into renders/subtitles/. Copy it out with glint_export.", risk: .reversible,
                 schema: S.obj(["project": S.project, "format": S.str("srt | vtt", enumValues: ["srt", "vtt"]), "proposal_id": S.proposal])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let (url, n) = try c.service.exportSubtitles(b, format: Subtitles.Format(rawValue: a.str("format") ?? "srt") ?? .srt, proposal: a.str("proposal_id"))
            return ToolOutput(json: .object(["path": .string(url.path), "cues": .number(Double(n))]))
        },
        ToolSpec(name: "glint_import_subtitles", title: "Import subtitles", description: "Replace the captions with an SRT or WebVTT file. Times are read as the edited output timeline (what an exported file uses) unless time_base is \"source\".", risk: .reversible,
                 schema: S.obj(["project": S.project, "file": S.str("SRT or VTT file"), "time_base": S.str("output (default) | source", enumValues: ["output", "source"]),
                                "apply": S.bool("Apply now (true) or propose"), "expected_revision": S.int("Fail if the project changed")], required: ["file"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let ops = try c.service.importSubtitles(b, file: try file(a), timeBase: a.str("time_base") ?? "output")
            return try commit(b, ops, title: "Import captions (\(ops.first?.items?.count ?? 0) lines)", apply: a.flag("apply") ?? true, c, expectedRevision: rev(a))
        },
        ToolSpec(name: "glint_edit_transcript", title: "Cut by transcript", description: "Remove spoken words from the video by editing the transcript: pass word index ranges (from glint_get_transcript words:true) and/or a phrase to delete everywhere it occurs. Creates cuts that don't eat neighbouring words. Proposal unless apply=true.", risk: .reversible,
                 schema: S.obj(["project": S.project, "remove": S.arr("Word index ranges [from, to] (inclusive)", .object(["type": .string("array"), "items": .object(["type": .string("integer")])])),
                                "phrase": S.str("Delete every occurrence of this phrase"), "apply": S.bool("Apply now (false: propose)"), "expected_revision": S.int("Fail if the project changed")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let ranges: [(Int, Int)] = try (a["remove"]?.arrayValue ?? []).map { v in
                guard let r = v.arrayValue, r.count == 2, let x = r[0].intValue, let y = r[1].intValue else { throw ServiceError.invalid("each remove entry is [from, to]") }
                return (x, y)
            }
            let (ops, removed) = try c.service.transcriptCuts(b, ranges: ranges, phrase: a.str("phrase"))
            return try commit(b, ops, title: "Cut “\(removed.joined(separator: "”, “").prefix(60))”", apply: a.flag("apply") == true, c, expectedRevision: rev(a),
                              extra: ["removed": .array(removed.map(JSONValue.string)), "rationale": .string("Transcript edit: " + removed.joined(separator: " / "))])
        },

        // MARK: Presets
        ToolSpec(name: "glint_list_presets", title: "List style presets", description: "Built-in and saved looks (background, frame, cursor, zoom, captions, canvas, facecam) that can be applied to any project.", risk: .read, schema: S.obj([:])) { _, c in
            try .encode(c.service.presets())
        },
        ToolSpec(name: "glint_apply_preset", title: "Apply a style preset", description: "Apply a saved or built-in look to a project as one undoable change.", risk: .reversible,
                 schema: S.obj(["project": S.project, "name": S.str("Preset name"), "expected_revision": S.int("Fail if the project changed")], required: ["name"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let p = try c.service.preset(a.str("name") ?? "")
            return try commit(b, [EditOperation(.mergeStyle, value: p.style)], title: "Apply preset “\(p.name)”", apply: true, c, expectedRevision: rev(a))
        },
        ToolSpec(name: "glint_save_preset", title: "Save a style preset", description: "Save this project's look as a reusable preset (Application Support/Glint/presets). Voice and audio levels are left out unless listed in sections.", risk: .reversible,
                 schema: S.obj(["project": S.project, "name": S.str("Preset name"), "summary": S.str("One-line description"),
                                "sections": S.arr("Style sections (default background, frame, cursor, zoom, captions, canvas, facecam)", S.str("section"))], required: ["name"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try .encode(try c.service.savePreset(name: a.str("name") ?? "", summary: a.str("summary"), from: b, sections: a["sections"]?.arrayValue?.compactMap(\.stringValue)))
        },

        // MARK: Recipes and evidence
        ToolSpec(name: "glint_recipe_save", title: "Save demo recipe", description: "Save the reusable recipe for this demo: audience, intent, ordered scenes with STABLE ids, steps, preconditions, expected outcomes (visible_text | state | manual) and narration intent. Versioned: changing content bumps version. Never put credentials in fixtures.", risk: .reversible,
                 schema: S.obj(["project": S.project, "recipe": .object(["type": .string("object"), "description": .string("{title, audience?, intent?, app?, fixtures?, outputs?, scenes:[{id, title, intent?, preconditions?, steps?, narration?, expectations:[{id, description, kind, text?, required?}]}]}")])], required: ["recipe"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            guard let raw = a["recipe"] else { throw ServiceError.invalid("recipe is required") }
            let r: DemoRecipe
            do { r = try raw.decode(DemoRecipe.self) } catch { throw ServiceError.invalid("recipe didn't parse: \(OperationApplier.decodingMessage(error))") }
            return try .encode(try c.service.saveRecipe(b, r))
        },
        ToolSpec(name: "glint_recipe_get", title: "Get recipe and status", description: "The project's recipe, and the current evidence report: per scene and expectation verified / failed / needs_review, from evidence for the takes in the edit.", risk: .read,
                 schema: S.obj(["project": S.project])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let r = try c.service.recipe(b)
            let rep = RecipeReport.evaluate(recipe: r, document: try b.readDocument(), evidence: b.readEvidence())
            return ToolOutput(json: .object(["recipe": try JSONValue.from(r), "report": try JSONValue.from(rep), "evidence": try JSONValue.from(b.readEvidence().records)]))
        },
        ToolSpec(name: "glint_recipe_build", title: "Bind recipe scenes to shots", description: "Split a recording into one shot per recipe scene, from the scene:<id> markers dropped while recording (glint_record_mark note \"scene:<id>\"). Shots carry the scene ID so a scene can later be refreshed from a new take. Applied unless apply=false.", risk: .reversible,
                 schema: S.obj(["project": S.project, "apply": S.bool("Apply now (true) or propose"), "expected_revision": S.int("Fail if the project changed")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let (ops, ranges) = try c.service.recipeBindOps(b)
            return try commit(b, ops, title: "Bind \(ranges.count) recipe scene\(ranges.count == 1 ? "" : "s")", apply: a.flag("apply") ?? true, c, expectedRevision: rev(a),
                              extra: ["scenes": .array(ranges.map { .object(["scene": .string($0.scene), "start": .number($0.range.start), "end": .number($0.range.end)]) })])
        },
        ToolSpec(name: "glint_recipe_evidence", title: "Report evidence", description: "Record what you observed for an expected outcome. status verified needs source assertion|ocr|human and the observed value; a reported action (a click) or a vision model's opinion is stored as needs_review — a click doesn't prove a result. failed overrides verified.", risk: .reversible,
                 schema: S.obj(["project": S.project, "scene_id": S.str("Recipe scene ID"), "expectation_id": S.str("Expectation ID"),
                                "status": S.str("verified | failed | needs_review", enumValues: EvidenceStatus.allCases.map(\.rawValue)),
                                "source": S.str("assertion | ocr | human | action | vision", enumValues: EvidenceRecord.Source.allCases.map(\.rawValue)),
                                "detail": S.str("What was checked and how, e.g. \"GET /api/invites → 1 pending for bo@example.com\""), "observed": S.str("The observed value"),
                                "time": S.num("Program time that shows it"), "take": S.str("Take ID (default: the take now in the edit)")],
                 required: ["scene_id", "expectation_id", "status", "source", "detail"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            guard let st = EvidenceStatus(rawValue: a.str("status") ?? ""), let src = EvidenceRecord.Source(rawValue: a.str("source") ?? "") else {
                throw ServiceError.invalid("status must be verified|failed|needs_review and source assertion|ocr|human|action|vision")
            }
            let r = try c.service.recordEvidence(b, EvidenceRecord(scene: a.str("scene_id") ?? "", expectation: a.str("expectation_id") ?? "", status: st, source: src,
                                                                   detail: a.str("detail") ?? "", observed: a.str("observed"), time: a.num("time"), take: a.str("take"), author: c.author))
            return try .encode(r)
        },
        ToolSpec(name: "glint_recipe_verify", title: "Verify recipe outcomes", description: "Check visible_text expectations on the last frame of each scene with on-device OCR (found → verified, not found → needs_review), then report the demo's status. Only `verified` means every required outcome has current evidence.", risk: .reversible,
                 schema: S.obj(["project": S.project, "ocr": S.bool("Run OCR checks (true)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            return try .encode(try await c.service.verifyRecipe(b, author: c.author, ocr: a.flag("ocr") ?? true))
        },
        ToolSpec(name: "glint_recipe_refresh_scene", title: "Refresh a scene from a new take", description: "Replace one recipe scene's shot with the same scene from another recording (record it with scene:<id> markers, or pass start/end). Manual edits elsewhere stay on their content; manual items inside the scene are placed proportionally; automatic ones are dropped. The take's evidence comes along; evidence from the old take stops counting.", risk: .reversible,
                 schema: S.obj(["project": S.project, "scene_id": S.str("Recipe scene ID"), "take": S.str("The new recording: project path or name"),
                                "start": S.num("Scene start in the take (default: its scene marker)"), "end": S.num("Scene end in the take"),
                                "apply": S.bool("Apply now (true) or propose"), "expected_revision": S.int("Fail if the project changed")], required: ["scene_id", "take"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let tb = try c.service.resolve(a.str("take"))
            var range: TimeRange?
            if let s = a.num("start"), let e = a.num("end") { range = TimeRange(s, e) }
            return try .encode(try c.service.refreshScene(b, scene: a.str("scene_id") ?? "", take: tb, range: range, author: c.author,
                                                         expectedRevision: rev(a), apply: a.flag("apply") ?? true))
        },

        // MARK: Jobs
        ToolSpec(name: "glint_job_start", title: "Start a durable job", description: "Start a render job (variants) or a production job (quality check → bounded automatic repair → draft render → inspection → recipe evidence). Jobs persist in the project with per-stage checkpoints; the same idempotency_key returns the same job. wait:false returns at once and keeps running in this server; poll glint_job_status. A production job ends succeeded only if every check passes, otherwise needs_review with the items.", risk: .reversible,
                 schema: S.obj(["project": S.project, "kind": S.str("render | production", enumValues: ["render", "production"]),
                                "variants": S.arr("render: presets (default [landscape])", S.variant), "variant": S.str("production: draft preset (preview)"),
                                "proposal_id": S.proposal, "idempotency_key": S.str("Reuse to get the same job instead of a duplicate"),
                                "expected_revision": S.int("Fail if the project changed"), "repair": S.bool("production: apply deterministic repairs (true)"),
                                "max_attempts": S.int("production: repair rounds 0–5 (2)"), "target_duration": S.num("production: desired length (s)"),
                                "inspect": S.bool("render: measure outputs (true)"), "wait": S.bool("Wait for the result (true)")])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let kind = Job.Kind(rawValue: a.str("kind") ?? "render") ?? .render
            let (job, _): (Job, Bool)
            switch kind {
            case .render:
                (job, _) = try JobRunner.createRender(c.service, b, variants: a["variants"]?.arrayValue?.compactMap(\.stringValue) ?? ["landscape"], proposal: a.str("proposal_id"),
                                                      idempotencyKey: a.str("idempotency_key"), expectedRevision: rev(a), inspect: a.flag("inspect") ?? true, author: c.author)
            case .production:
                (job, _) = try JobRunner.createProduction(c.service, b, variant: a.str("variant") ?? "preview", repair: a.flag("repair") ?? true,
                                                          maxAttempts: Int(a.num("max_attempts") ?? 2), targetDuration: a.num("target_duration"),
                                                          idempotencyKey: a.str("idempotency_key"), expectedRevision: rev(a), author: c.author)
            }
            return try await launch(c.service, b, job, wait: a.flag("wait") ?? true, c)
        },
        ToolSpec(name: "glint_job_status", title: "Job status", description: "A job's status, progress, stages (with artifacts and hashes), result and review items. A job whose process died shows interrupted.", risk: .read,
                 schema: S.obj(["project": S.project, "job_id": S.str("Job ID")], required: ["job_id"])) { a, c in
            try .encode(try JobStore(bundle: try c.service.resolve(a.str("project"))).get(a.str("job_id") ?? ""))
        },
        ToolSpec(name: "glint_job_list", title: "List jobs", description: "Jobs of a project, newest first.", risk: .read, schema: S.obj(["project": S.project])) { a, c in
            try .encode(JobStore(bundle: try c.service.resolve(a.str("project"))).list())
        },
        ToolSpec(name: "glint_job_cancel", title: "Cancel a job", description: "Ask a running job to stop (it stops at the next frame and removes the partial file). Completed stages are kept for a retry.", risk: .reversible,
                 schema: S.obj(["project": S.project, "job_id": S.str("Job ID")], required: ["job_id"])) { a, c in
            try .encode(try JobStore(bundle: try c.service.resolve(a.str("project"))).requestCancel(a.str("job_id") ?? ""))
        },
        ToolSpec(name: "glint_job_retry", title: "Retry a job", description: "Resume a failed, cancelled, interrupted or needs-review job after its last completed stage (completed renders whose files still hash the same are not redone).", risk: .reversible,
                 schema: S.obj(["project": S.project, "job_id": S.str("Job ID"), "wait": S.bool("Wait for the result (true)")], required: ["job_id"])) { a, c in
            let b = try c.service.resolve(a.str("project"))
            let j = try JobRunner.prepareRetry(b, a.str("job_id") ?? "")
            return try await launch(c.service, b, j, wait: a.flag("wait") ?? true, c)
        },
    ]
}
