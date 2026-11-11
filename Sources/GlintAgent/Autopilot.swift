import Foundation
import GlintCore
import GlintRender
import GlintAnalysis

/// The end-to-end "turn a raw take into a polished demo" workflow, built only from public service calls, run as a
/// persisted, resumable job (`Job.Kind.autopilot`, `jobs/<run>.json`).
///
/// Stages, in order: transcribe → plan_cuts → plan_zooms → analyze_scenes → write_narration → voiceover → captions →
/// quality → render → evidence. Each stage records its outcome (the step report), the inputs it worked from, its
/// artifacts and any approval it waits on. Calling again with the run's id (or the same arguments, or
/// `glint_job_retry`) continues from the first unfinished stage: finished edits, scripts and voice clips are never
/// redone. Measurements (quality, evidence) are always taken again; a render is reused while the edit it was made
/// from is unchanged; a voiceover is redone only when its script changed, and then only for the changed lines
/// (`voiceover()` never re-sends a line that already has a clip in the same voice).
///
/// Approvals: script writing and voice synthesis are separate external actions with separate, single-use approvals
/// bound to their exact parameters. A run hands each gated stage only the approval issued for that action, so
/// approving the script never "uses up" the voice: the voiceover stage asks for its own approval and the run pauses as
/// `approval_required` (job status `waiting_approval`) with the new id. Waiting on a person is never a failure.
///
/// Outcomes per stage: `ok`, `skipped`, `failed`, `needs_review` or `approval_required`. A stage the caller asked
/// for explicitly is required: if it fails, the run's status is `failed`. Otherwise the run is `needs_review` unless
/// the edit passes its quality checks, requested renders measure clean, and a recipe's required outcomes are
/// verified — only then `ready`. An unchecked draft is never reported as a success.
///
/// `target_duration` is a production constraint, not just a measurement: cuts tighten (bounded) until the edit fits,
/// the script is budgeted from the target, and when the content can't fit a review item says by how much.
public enum Autopilot {
    public static let stages = ["transcribe", "plan_cuts", "plan_zooms", "analyze_scenes", "write_narration", "voiceover", "captions", "quality", "render", "evidence"]

    /// How long a stopped (failed/interrupted) run stays eligible to be resumed by an identical call without run_id.
    static let resumeWindow: TimeInterval = 6 * 3600

    // MARK: Arguments

    /// What a run makes. Approval ids, run_id, expected_revision and wait are per call and not part of it, so the same
    /// request made again (with an approval id) finds its run.
    public static func params(_ a: JSONValue) -> JSONValue {
        func opt(_ v: JSONValue?) -> JSONValue { v ?? .null }
        let variants = a["variants"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return .object([
            "variants": .array(variants.map(JSONValue.string)),
            "propose_only": .bool(a.flag("propose_only") == true),
            "target_duration": a.num("target_duration").map(JSONValue.number) ?? .null,
            "captions": a.flag("captions").map(JSONValue.bool) ?? .null,
            "narrate": .bool(a.flag("narrate") == true),
            "voice": opt(a.str("voice").map(JSONValue.string)),
            "brief": opt(a.str("brief").map(JSONValue.string)),
            "locale": opt(a.str("locale").map(JSONValue.string)),
            "writer": opt(a.str("writer").map(JSONValue.string)),
        ])
    }

    /// `approval_ids` (array) plus the older single `approval_id`.
    public static func approvalIDs(_ a: JSONValue) -> [String] {
        var ids = a["approval_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let one = a.str("approval_id"), !one.isEmpty { ids.append(one) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: Tool entry

    /// `glint_autopilot`: start a run, or continue one (`run_id`, or an identical earlier request that is waiting on an
    /// approval or stopped recently), and drive it as far as it can go in this call.
    public static func run(_ b: ProjectBundle, args a: JSONValue, context c: ToolContext) async throws -> ToolOutput {
        let s = c.service
        let store = JobStore(bundle: b)
        let ids = approvalIDs(a)
        let expected = a.num("expected_revision").map { Int($0) }
        var job: Job
        if let rid = a.str("run_id"), !rid.isEmpty {
            job = try store.get(rid)
            guard job.kind == .autopilot else { throw ServiceError.invalid("\(rid) is a \(job.kind.rawValue) job, not an autopilot run") }
            if let e = expected { let rev = try b.readDocument().revision; if e != rev { throw EditError.staleRevision(expected: e, actual: rev) } }
        } else {
            let p = params(a)
            if let e = expected { let rev = try b.readDocument().revision; if e != rev { throw EditError.staleRevision(expected: e, actual: rev) } }
            if let existing = resumable(store, params: p, approvalIDs: ids) {
                job = existing
            } else {
                job = try JobRunner.createAutopilot(s, b, params: p, idempotencyKey: nil, expectedRevision: nil, author: c.author).0
            }
        }
        if job.status.isResumable { job = try store.prepareRetry(job.id) }
        // Running elsewhere, or already finished: report where it is.
        guard job.status == .queued, ProductionTools.Running.shared.claim(job.id) else {
            return ToolOutput(json: report(try store.get(job.id), bundle: b, service: s))
        }
        defer { ProductionTools.Running.shared.release(job.id) }
        let done = await JobRunner.run(s, b, job.id, progress: c.progress, approvalIDs: ids)
        return ToolOutput(json: report(done, bundle: b, service: s))
    }

    /// The run an identical request continues: one waiting on an approval the caller now holds, else the newest run
    /// waiting on any approval, else one that stopped (failed, interrupted) within `resumeWindow`.
    static func resumable(_ store: JobStore, params: JSONValue, approvalIDs ids: [String]) -> Job? {
        let runs = store.list().filter { $0.kind == .autopilot && $0.params == params }
        if let r = runs.first(where: { j in j.status == .waitingApproval && j.stages.contains { $0.approvalID.map(ids.contains) ?? false } }) { return r }
        if let r = runs.first(where: { $0.status == .waitingApproval }) { return r }
        return runs.first { [.interrupted, .failed].contains($0.status) && Date().timeIntervalSince($0.updatedAt) < resumeWindow }
    }

    // MARK: Execution

    /// One stage's report, stored in `JobStage.result` and returned in `steps`.
    static func step(_ name: String, _ outcome: String, _ detail: JSONValue, required: Bool, review: [String] = []) -> JSONValue {
        .object(["step": .string(name), "status": .string(outcome), "required": .bool(required), "result": detail,
                 "review": .array(review.map(JSONValue.string))])
    }

    /// Hash of the narration a voiceover speaks (and the voice asked for): a finished voiceover stage is redone when
    /// this changes — and `voiceover()` then synthesizes only the lines that changed.
    public static func scriptHash(_ b: ProjectBundle, voice: String?) -> String {
        let lines = (b.readStoryboard()?.narratedScenes ?? []).map { "\($0.id)=\($0.narration ?? "")" }
        return StableHash.hex(lines.joined(separator: "\n") + "|voice=\(voice ?? "")")
    }

    /// Drive a claimed autopilot job from its first unfinished stage until it finishes or waits on an approval.
    static func execute(_ s: GlintService, _ b: ProjectBundle, _ store: JobStore, _ initial: Job, approvalIDs: [String],
                        progress: (@Sendable (String) -> Void)?) async throws -> Job {
        var job = initial
        let id = job.id, author = job.author, p = job.params
        let proposeOnly = p["propose_only"]?.boolValue == true
        let target = p["target_duration"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        let captionsFlag = p["captions"]?.boolValue
        let captionsRequested = captionsFlag == true
        let narrate = p["narrate"]?.boolValue == true
        let voice = p["voice"]?.stringValue
        // Every approval this run knows about: the caller's and the ones its stages asked for earlier. Each gated
        // stage picks only the one issued for its own action.
        let ids = approvalIDs + job.stages.compactMap(\.approvalID)

        func cancelled() throws { if store.isCancelRequested(id) { throw RenderError.cancelled } }
        func index(_ name: String) -> Int? { job.stages.firstIndex { $0.name == name } }
        func finished(_ name: String) -> Bool { index(name).map { [.done, .skipped].contains(job.stages[$0].status) } ?? true }
        func outcome(_ name: String) -> String? { index(name).flatMap { job.stages[$0].result?["status"]?.stringValue } }
        func begin(_ name: String) throws {
            try cancelled()
            job = try store.update(id) { j in
                guard let i = j.stages.firstIndex(where: { $0.name == name }) else { return }
                j.stages[i].status = .running; j.stages[i].startedAt = Date(); j.stages[i].attempts += 1; j.stages[i].error = nil
                j.message = StageText.running(name)
            }
        }
        /// Record a stage's outcome. `done` for ok/needs_review/failed-but-optional work that should not be redone;
        /// `failed` only when the stage should run again on resume.
        func finish(_ name: String, _ out: String, _ detail: JSONValue, required: Bool = false, review: [String] = [], inputs: JSONValue? = nil,
                    hashes: [String: String] = [:]) throws {
            let status: JobStage.Status = out == "skipped" ? .skipped : out == "failed" ? .failed : .done
            job = try store.update(id) { j in
                guard let i = j.stages.firstIndex(where: { $0.name == name }) else { return }
                j.stages[i].status = status; j.stages[i].finishedAt = Date()
                j.stages[i].result = step(name, out, detail, required: required, review: review)
                j.stages[i].detail = detail.stringValue ?? out
                j.stages[i].error = out == "failed" ? (detail.stringValue ?? "failed") : nil
                if let inputs { j.stages[i].inputs = inputs }
                j.stages[i].artifacts = hashes.keys.sorted(); j.stages[i].hashes = hashes
                j.progress = Double(j.stages.filter { [.done, .skipped].contains($0.status) }.count) / Double(max(1, j.stages.count))
            }
            progress?("\(name): \(out)")
        }
        /// Pause the run on a gated action: the stage waits on `req`, no process owns the job.
        func wait(_ name: String, _ req: ApprovalRequest) throws -> Job {
            job = try store.update(id) { j in
                guard let i = j.stages.firstIndex(where: { $0.name == name }) else { return }
                j.stages[i].status = .waitingApproval; j.stages[i].approvalID = req.id
                j.stages[i].detail = "Waiting for approval \(req.id)"
                j.stages[i].result = step(name, "approval_required", (try? JSONValue.from(req)) ?? .string(req.id), required: true)
                j.status = .waitingApproval; j.pid = nil
                j.message = statusLine(j)
            }
            progress?("\(name): approval_required (\(req.id))")
            return job
        }
        func commit(_ ops: [EditOperation], _ title: String) throws -> JSONValue {
            guard !ops.isEmpty else { return .string("nothing to do") }
            let e = s.engine(b)
            if proposeOnly { return .object(["proposal_id": .string(try e.propose(title: title, rationale: "autopilot", operations: ops, author: author).id)]) }
            return try JSONValue.from(try e.apply(ops, label: title, author: author))
        }

        // A finished voiceover whose script (or voice) changed since is redone, with everything that depends on it.
        if let i = index("voiceover"), job.stages[i].status == .done, outcome("voiceover") == "ok",
           job.stages[i].inputs?["script"]?.stringValue != scriptHash(b, voice: voice) {
            job = try store.update(id) { j in
                for n in ["voiceover", "captions", "render"] { if let k = j.stages.firstIndex(where: { $0.name == n }) { j.stages[k].status = .pending } }
            }
        }

        // 1. Transcribe when there is a voice track and no transcript.
        if !finished("transcribe") {
            try begin("transcribe")
            let doc = try b.readDocument()
            if doc.media.microphone != nil || doc.media.systemAudio != nil {
                if b.readTranscript() == nil {
                    do {
                        let t = try await s.transcribe(b, locale: p["locale"]?.stringValue ?? "en-US", engine: .auto, source: nil)
                        try finish("transcribe", "ok", .string("\(t.words.count) words via \(t.engine)"))
                    } catch {
                        try cancelled()
                        try finish("transcribe", "failed", .string("\(error)"), required: captionsRequested,
                                   review: captionsRequested ? [] : ["Transcription failed (\(error)); captions and filler-word cuts were skipped."])
                    }
                } else { try finish("transcribe", "skipped", .string("already transcribed")) }
            } else { try finish("transcribe", "skipped", .string("no audio track")) }
        }

        // 2. Tighten, aimed at the target length when there is one.
        if !finished("plan_cuts") {
            try begin("plan_cuts")
            do {
                let f = try await s.planCuts(b, target: target)
                var detail: [String: JSONValue] = ["edit": try commit(f.ops, "Autopilot: tighten (\(f.plan.cuts.count) cuts, \(f.plan.speeds.count) speed-ups)"),
                                                   "projected_duration": .number(round(f.projectedDuration * 10) / 10), "tightness": .number(Double(f.level))]
                var review: [String] = []
                if let target {
                    detail["target_duration"] = .number(target)
                    detail["default_duration"] = .number(round(f.defaultDuration * 10) / 10)
                    if !f.fits {
                        review.append(String(format: "Needs ~%.0f s even with the tightest safe cuts; target is %.0f s — allow a longer version or narrow the scope.", f.projectedDuration, target))
                    }
                }
                try finish("plan_cuts", "ok", .object(detail), required: true, review: review, inputs: .object(["target": target.map(JSONValue.number) ?? .null]))
            } catch { try cancelled(); try finish("plan_cuts", "failed", .string("\(error)"), required: true) }
        }

        // 3. Zoom.
        if !finished("plan_zooms") {
            try begin("plan_zooms")
            do {
                let (zoomOps, zooms) = try s.planZooms(b, options: ZoomPlanOptions())
                try finish("plan_zooms", "ok", try commit(zoomOps, "Autopilot: \(zooms.count) zooms"), required: true)
            } catch { try cancelled(); try finish("plan_zooms", "failed", .string("\(error)"), required: true) }
        }

        // 4–6. Narration: scenes (on device) → script (external, gated) → voice (external, gated, its own approval).
        if !finished("analyze_scenes") {
            try begin("analyze_scenes")
            if !narrate { try finish("analyze_scenes", "skipped", .string("narrate is off")) } else {
                do {
                    let sb = try await s.analyzeScenes(b, progress: progress)
                    var review: [String] = []
                    if let target {
                        // The shortest script that still says something: a minimal line per scene.
                        let floor = Double(sb.scenes.count) * Narrator.spokenSeconds(words: Narrator.minimumWords, wordsPerSecond: NarrationOptions().wordsPerSecond)
                        if floor > target * 1.1 {
                            review.append(String(format: "Needs ~%.0f s to stay understandable (%d scenes with at least a short line each); target is %.0f s — allow a longer version or narrow the scope.", floor, sb.scenes.count, target))
                        }
                    }
                    try finish("analyze_scenes", "ok", .string("\(sb.scenes.count) scenes"), required: true, review: review)
                } catch { try cancelled(); try finish("analyze_scenes", "failed", .string("\(error)"), required: true) }
            }
        }
        if !finished("write_narration") {
            try begin("write_narration")
            if !narrate { try finish("write_narration", "skipped", .string("narrate is off")) }
            else if outcome("analyze_scenes") != "ok" { try finish("write_narration", "failed", .string("no scenes to write for"), required: true) }
            else {
                var o = NarrationOptions(); o.brief = p["brief"]?.stringValue; o.targetDuration = target
                if let w = p["writer"]?.stringValue.flatMap(NarrationWriter.init(rawValue:)) { o.writer = w }
                do {
                    let written = try await s.writeNarration(b, options: o, author: author, approvalID: nil, approvalIDs: ids)
                    var review: [String] = []
                    if let target {
                        let needed = written.narratedScenes.reduce(0.0) { t, sc in
                            t + Narrator.spokenSeconds(words: (sc.narration ?? "").split(whereSeparator: \.isWhitespace).count, wordsPerSecond: o.wordsPerSecond)
                        }
                        if needed > target * 1.15 {
                            review.append(String(format: "Narration needs ~%.0f s to stay understandable; target is %.0f s — allow a longer version or narrow the scope.", needed, target))
                        }
                    }
                    try finish("write_narration", "ok", .string("\(written.narratedScenes.count) lines by \(written.writer ?? o.model)"), required: true, review: review,
                               inputs: .object(["script": .string(scriptHash(b, voice: voice))]))
                } catch ApprovalError.required(let req) {
                    return try wait("write_narration", req)
                } catch {
                    try cancelled()
                    try finish("write_narration", "failed", .string("\(error)"), required: true)
                }
            }
        }
        if !finished("voiceover") {
            try begin("voiceover")
            if !narrate { try finish("voiceover", "skipped", .string("narrate is off")) }
            else if outcome("write_narration") != "ok" { try finish("voiceover", "failed", .string("no script to speak"), required: true) }
            else {
                do {
                    let r = try await s.voiceover(b, voice: voice, fit: true, captions: captionsFlag ?? true, author: author, approvalID: nil, approvalIDs: ids, progress: progress)
                    let detail: JSONValue = r.operations.isEmpty ? .string(r.fitNotes.first ?? "nothing to synthesize")
                        : try commit(r.operations, "Autopilot: voiceover (\(r.clips.count) clips, \(r.voiceName))")
                    var review: [String] = []
                    if let target, r.outputDuration > target * 1.15 {
                        review.append(String(format: "The narrated video runs %.0f s; target is %.0f s — allow a longer version, shorten lines, or narrow the scope.", r.outputDuration, target))
                    }
                    try finish("voiceover", "ok", detail, required: true, review: review, inputs: .object(["script": .string(scriptHash(b, voice: voice))]))
                } catch ApprovalError.required(let req) {
                    return try wait("voiceover", req)
                } catch {
                    try cancelled()
                    try finish("voiceover", "failed", .string("\(error)"), required: true)
                }
            }
        }

        // 7. Captions from the transcript, unless the voice already brought exact ones.
        if !finished("captions") {
            try begin("captions")
            if outcome("voiceover") == "ok" {
                try finish("captions", "skipped", .string("captions come from the voiceover"))
            } else if captionsFlag ?? true, let t = b.programTranscript(for: try b.readDocument()), t.words.count >= 3 {
                do { try finish("captions", "ok", try commit(try s.captionOps(b), "Autopilot: captions"), required: captionsRequested) }
                catch { try cancelled(); try finish("captions", "failed", .string("\(error)"), required: captionsRequested) }
            } else if captionsRequested {
                try finish("captions", "failed", .string("no transcript with speech to caption"), required: true)
            } else { try finish("captions", "skipped", .string(captionsFlag == false ? "captions are off" : "no speech")) }
        }

        // 8. Measure the edit (always, on the current state).
        if !finished("quality") {
            try begin("quality")
            let q = try s.quality(b, proposal: nil, targetDuration: target)
            try finish("quality", q.failures.isEmpty ? "ok" : "needs_review", try JSONValue.from(q),
                       review: q.failures.map { "Edit: \($0.message)\($0.fix.map { " (suggested: \($0))" } ?? "")" })
        }

        // 9. Render, reusing an earlier render of the same edit whose files still hash the same.
        let variants = p["variants"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let i = index("render"), job.stages[i].status == .done, outcome("render") != "skipped",
           job.stages[i].inputs?["revision"]?.intValue != (try b.readDocument().revision) || !JobRunner.reusable(b, job.stages[i]) {
            job = try store.update(id) { j in if let k = j.stages.firstIndex(where: { $0.name == "render" }) { j.stages[k].status = .pending } }
        }
        if !finished("render") {
            try begin("render")
            if variants.isEmpty { try finish("render", "skipped", .string("no variants requested")) }
            else if proposeOnly {
                try finish("render", "skipped", .string("propose_only: apply the proposals first"), review: ["Edits are pending proposals; nothing was rendered."])
            } else {
                do {
                    let vs = try variants.map { n in
                        guard let v = RenderVariant.preset(n) else { throw ServiceError.invalid("Unknown variant \(n)") }
                        return v
                    }
                    let rev = try b.readDocument().revision
                    let m = try await s.render(b, variants: vs, proposal: nil, author: author)
                    let bad = m.outputs.flatMap { o in (o.report?.quality.failures ?? []).map { "Render \(o.variant): \($0.message)" } }
                    var hashes: [String: String] = [:]
                    for o in m.outputs { let u = URL(fileURLWithPath: o.path); hashes[JobRunner.rel(b, u)] = try JobRunner.sha256(u) }
                    try finish("render", bad.isEmpty ? "ok" : "needs_review", .object(["files": .string("\(m.outputs.count) file(s) in \(m.id)"), "manifest": try JSONValue.from(m)]),
                               required: true, review: bad, inputs: .object(["revision": .number(Double(rev))]), hashes: hashes)
                } catch { try cancelled(); try finish("render", "failed", .string("\(error)"), required: true) }
            }
        }

        // 10. What the video shows.
        if !finished("evidence") {
            try begin("evidence")
            if b.readRecipe() != nil {
                do {
                    let rep = try await s.verifyRecipe(b, author: author)
                    let review = rep.status == .verified ? [] : rep.items.filter { $0.required && $0.status != .verified }.map { "Evidence \($0.scene)/\($0.expectation): \($0.status.rawValue)" }
                    try finish("evidence", rep.status == .verified ? "ok" : rep.status == .failed ? "failed" : "needs_review", try JSONValue.from(rep),
                               required: rep.status == .failed, review: review)
                } catch { try cancelled(); try finish("evidence", "failed", .string("\(error)"), required: true) }
            } else {
                try finish("evidence", "skipped", .string("no recipe"), review: ["No recipe: what this demo shows hasn't been checked."])
            }
        }

        // Settle the run.
        try cancelled()
        let failed = failedSteps(job)
        let review = reviewItems(job)
        let status = !failed.isEmpty ? "failed" : (proposeOnly ? "draft" : (review.isEmpty ? "ready" : "needs_review"))
        return try store.update(id) { j in
            j.progress = 1
            j.review = review
            j.result = .object(["status": .string(status), "failed_steps": .array(failed.map(JSONValue.string))])
            j.status = status == "failed" ? .failed : status == "ready" ? .succeeded : .needsReview
            j.error = failed.isEmpty ? nil : "Required step\(failed.count == 1 ? "" : "s") failed: \(failed.joined(separator: ", "))"
            j.pid = nil
            j.message = statusLine(j)
        }
    }

    // MARK: Reporting

    static func failedSteps(_ j: Job) -> [String] {
        j.stages.compactMap { st in
            guard let r = st.result, r["required"]?.boolValue == true else { return nil }
            return r["status"]?.stringValue == "failed" ? st.name : nil
        }
    }
    static func reviewItems(_ j: Job) -> [String] {
        j.stages.flatMap { st -> [String] in
            // Only stages that count now: a stage reset for a redo has no say until it runs again.
            guard [.done, .skipped, .failed].contains(st.status) else { return [] }
            return st.result?["review"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
    }

    static func number(_ n: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n < words.count ? words[n] : "\(n)"
    }

    /// One plain sentence for people: "Three stages done. Voiceover is waiting for approval apr_x. Your edit is saved."
    public static func statusLine(_ j: Job) -> String {
        let done = j.stages.filter { $0.status == .done }.count
        var parts = ["\(number(done)) stage\(done == 1 ? "" : "s") done."]
        if let w = j.stages.first(where: { $0.status == .waitingApproval }) {
            parts.append("\(StageText.title(w.name)) is waiting for approval\(w.approvalID.map { " \($0)" } ?? "").")
            parts.append("Your edit is saved.")
        } else {
            switch j.status {
            case .queued, .running: parts.append(j.stages.first { $0.status == .running }.map { StageText.running($0.name) + "." } ?? "Working.")
            case .succeeded: parts.append("Every check passed.")
            case .needsReview: parts.append("\(j.review.count) item\(j.review.count == 1 ? "" : "s") to look at.")
            case .failed:
                let f = failedSteps(j).map(StageText.title)
                parts.append(f.isEmpty ? "It stopped on an error." : "\(f.joined(separator: ", ")) failed.")
                parts.append("Finished stages are kept.")
            case .cancelled, .interrupted: parts.append("Stopped; finished stages are kept.")
            case .waitingApproval: parts.append("Waiting for approval. Your edit is saved.")
            }
        }
        return parts.joined(separator: " ")
    }

    /// The tool result for a run, in the shape `glint_autopilot` has always returned (status, steps, review, render,
    /// summary) plus the run id, a status line, and the approval to ask for when it is waiting.
    public static func report(_ j: Job, bundle b: ProjectBundle, service s: GlintService) -> JSONValue {
        let steps = j.stages.compactMap(\.result)
        let waiting = j.stages.first { $0.status == .waitingApproval }
        let status: String
        switch j.status {
        case .waitingApproval: status = "approval_required"
        case .queued, .running: status = "running"
        case .cancelled: status = "cancelled"
        case .interrupted: status = "interrupted"
        default: status = j.result?["status"]?.stringValue ?? (j.status == .failed ? "failed" : "needs_review")
        }
        var out: [String: JSONValue] = [
            "status": .string(status), "run_id": .string(j.id), "message": .string(statusLine(j)),
            "failed_steps": .array(failedSteps(j).map(JSONValue.string)), "review": .array(reviewItems(j).map(JSONValue.string)),
            "steps": .array(steps),
            "stages": .array(j.stages.map { .object(["stage": .string($0.name), "status": .string($0.status.rawValue)]) }),
            "render": j.stage("render")?.result?["result"]?["manifest"] ?? .null,
            "summary": (try? JSONValue.from(try s.summary(b))) ?? .null,
        ]
        if let e = j.error, j.status == .failed { out["error"] = .string(e) }
        if let w = waiting, let aid = w.approvalID {
            out["approval_id"] = .string(aid)
            if let r = s.approvals.get(aid) { out["approval"] = .object(["action": .string(r.action), "summary": .string(r.summary), "risk": .string(r.risk.rawValue)]) }
            out["next"] = .string("Ask the user to approve \(aid) (\(StageText.title(w.name).lowercased())) in the Glint app or with `glint approve \(aid)` in their terminal, then call glint_autopilot again with run_id \"\(j.id)\". Finished stages are kept; the approval is picked up automatically.")
        } else if [.failed, .cancelled, .interrupted].contains(j.status) {
            out["next"] = .string("Fix what failed, then call glint_autopilot with run_id \"\(j.id)\" (or glint_job_retry) to continue from the first unfinished stage.")
        }
        return .object(out)
    }
}

/// Human names for autopilot stages, shared by reports and the app.
public enum StageText {
    public static func title(_ name: String) -> String {
        switch name {
        case "transcribe": "Transcription"
        case "plan_cuts": "Tightening"
        case "plan_zooms": "Zooms"
        case "analyze_scenes": "Scene analysis"
        case "write_narration": "Script writing"
        case "voiceover": "Voiceover"
        case "captions": "Captions"
        case "quality": "Quality check"
        case "render": "Render"
        case "evidence": "Evidence check"
        default: name
        }
    }
    public static func running(_ name: String) -> String {
        switch name {
        case "transcribe": "Transcribing"
        case "plan_cuts": "Tightening the edit"
        case "plan_zooms": "Planning zooms"
        case "analyze_scenes": "Reading the scenes"
        case "write_narration": "Writing the script"
        case "voiceover": "Recording the voiceover"
        case "captions": "Adding captions"
        case "quality": "Checking the edit"
        case "render": "Rendering"
        case "evidence": "Checking the evidence"
        default: name
        }
    }
}
