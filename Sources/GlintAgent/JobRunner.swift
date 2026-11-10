import Foundation
import CryptoKit
import GlintCore
import GlintRender
import GlintAnalysis

/// Runs durable jobs (see `Job`/`JobStore`). A job renders from a snapshot of the document taken when it was
/// created (`jobs/<id>.document.json`), so later edits never change what a retry produces, and completed stages are
/// skipped on retry when their artifacts still hash the same.
public enum JobRunner {
    static func snapshotURL(_ store: JobStore, _ id: String) -> URL { store.snapshotURL(id) }

    // MARK: Start

    /// A render job for `variants`. `expectedRevision` fails fast if the project changed since the caller looked.
    public static func createRender(_ s: GlintService, _ b: ProjectBundle, variants: [String], proposal: String?, idempotencyKey: String?,
                                    expectedRevision: Int?, inspect: Bool, author: Author) throws -> (Job, Bool) {
        let doc = try s.document(b, proposal: proposal)
        if let e = expectedRevision, e != doc.revision { throw EditError.staleRevision(expected: e, actual: doc.revision) }
        guard !variants.isEmpty, Set(variants).count == variants.count else { throw ServiceError.invalid("Choose at least one unique render variant") }
        for v in variants where RenderVariant.preset(v) == nil { throw ServiceError.invalid("Unknown variant \(v)") }
        let params: JSONValue = .object(["variants": .array(variants.map(JSONValue.string)), "proposal_id": proposal.map(JSONValue.string) ?? .null,
                                         "inspect": .bool(inspect), "revision": .number(Double(doc.revision))])
        return try create(s, b, kind: .render, params: params, doc: doc, stages: variants.map { "render:\($0)" }, key: idempotencyKey, author: author)
    }

    /// A production pass: check the edit, apply bounded deterministic repairs, render a draft, inspect it and check the
    /// recipe's evidence. It ends `succeeded` only when every check passes; otherwise `needs_review` with the items.
    public static func createProduction(_ s: GlintService, _ b: ProjectBundle, variant: String, repair: Bool, maxAttempts: Int, targetDuration: Double?,
                                        idempotencyKey: String?, expectedRevision: Int?, author: Author) throws -> (Job, Bool) {
        let doc = try b.readDocument()
        if let e = expectedRevision, e != doc.revision { throw EditError.staleRevision(expected: e, actual: doc.revision) }
        guard RenderVariant.preset(variant) != nil else { throw ServiceError.invalid("Unknown variant \(variant)") }
        let params: JSONValue = .object(["variant": .string(variant), "repair": .bool(repair), "max_attempts": .number(Double(max(0, min(5, maxAttempts)))),
                                         "target_duration": targetDuration.map(JSONValue.number) ?? .null, "revision": .number(Double(doc.revision))])
        return try create(s, b, kind: .production, params: params, doc: doc, stages: ["quality", "repair", "render:\(variant)", "inspect", "evidence"],
                          key: idempotencyKey, author: author)
    }

    static func create(_ s: GlintService, _ b: ProjectBundle, kind: Job.Kind, params: JSONValue, doc: ProjectDocument, stages: [String], key: String?, author: Author) throws -> (Job, Bool) {
        let store = JobStore(bundle: b)
        return try store.create(Job(kind: kind, idempotencyKey: key, params: params, revision: doc.revision, stages: stages, author: author), document: doc)
    }

    /// Reset a stopped job so `run` resumes it after its last completed stage.
    public static func prepareRetry(_ b: ProjectBundle, _ id: String) throws -> Job {
        try JobStore(bundle: b).prepareRetry(id)
    }

    // MARK: Run

    /// Run (or resume) a job to a terminal state in this process.
    @discardableResult
    public static func run(_ s: GlintService, _ b: ProjectBundle, _ id: String, progress: (@Sendable (String) -> Void)? = nil) async -> Job {
        let store = JobStore(bundle: b)
        do {
            let claim = try store.claim(id)
            guard claim.claimed else { return claim.job }
            var job = claim.job
            guard let doc = try? JSONCoding.decoder.decode(ProjectDocument.self, from: Data(contentsOf: snapshotURL(store, id))) else {
                return (try? store.update(id) { $0.status = .failed; $0.error = "The job's document snapshot is missing" }) ?? job
            }
            switch job.kind {
            case .render: job = try await runRender(s, b, store, job, doc, progress)
            case .production: job = try await runProduction(s, b, store, job, doc, progress)
            }
            return job
        } catch {
            let cancelled = (error as? RenderError).map { if case .cancelled = $0 { return true }; return false } ?? false
            if let job = try? store.update(id, { j in
                let stopped = cancelled || store.isCancelRequested(id)
                j.status = stopped ? .cancelled : .failed
                j.error = stopped ? nil : "\(error)"
                j.message = stopped ? "Cancelled" : "Failed: \(error)"
                for i in j.stages.indices where j.stages[i].status == .running {
                    j.stages[i].status = stopped ? .cancelled : .failed; j.stages[i].error = stopped ? nil : "\(error)"
                }
            }) { return job }
            var missing = Job(id: id, kind: .render, idempotencyKey: nil, params: .null, revision: 0, stages: [], author: .system)
            missing.status = .failed; missing.error = "\(error)"
            return missing
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: url.path)
        guard let h else { throw ServiceError.invalid("Can't read \(url.path)") }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func rel(_ b: ProjectBundle, _ u: URL) -> String { String(u.standardizedFileURL.path.dropFirst(b.url.path.count + 1)) }

    /// A completed stage whose artifacts are all still present and unchanged.
    static func reusable(_ b: ProjectBundle, _ st: JobStage) -> Bool {
        guard st.status == .done, !st.artifacts.isEmpty else { return false }
        for a in st.artifacts {
            guard let want = st.hashes[a], let got = try? sha256(b.resolve(a)), got == want else { return false }
        }
        return true
    }

    /// Render one variant as a checkpointed stage. Returns its output entry.
    static func renderStage(_ s: GlintService, _ b: ProjectBundle, _ store: JobStore, _ job: inout Job, stage name: String, variant v: RenderVariant,
                            doc: ProjectDocument, inspect: Bool, base: Double, share: Double, _ progress: (@Sendable (String) -> Void)?) async throws -> RenderOutput {
        let id = job.id
        if store.isCancelRequested(id) { throw RenderError.cancelled }
        let dir = b.rendersURL.appendingPathComponent(id, isDirectory: true)
        let url = dir.appendingPathComponent("\(v.name).\(v.format.rawValue)")
        let vdoc = try s.variantDocument(doc, v)
        let (w, h) = RenderPlan.outputSize(document: vdoc, height: v.size)
        let expected = TimeMap(document: vdoc).outputDuration
        let reportURL = dir.appendingPathComponent("\(v.name).report.json")
        if let st = job.stage(name), reusable(b, st), !inspect || st.hashes[rel(b, reportURL)] != nil {
            let report = inspect ? try? JSONCoding.decoder.decode(RenderReport.self, from: Data(contentsOf: reportURL)) : nil
            if inspect && report == nil { throw ServiceError.invalid("The saved render inspection is unreadable; retry after removing the corrupt checkpoint") }
            return RenderOutput(variant: v.name, path: url.path, width: w, height: h, duration: report?.duration ?? expected, seconds: 0, report: report)
        }
        job = try store.update(id) { j in
            if let i = j.stages.firstIndex(where: { $0.name == name }) { j.stages[i].status = .running; j.stages[i].startedAt = Date(); j.stages[i].attempts += 1 }
            j.message = "Rendering \(v.name)"
        }
        let start = Date()
        final class Throttle: @unchecked Sendable { var last = -1.0; let lock = NSLock() }
        let th = Throttle()
        _ = try await Exporter.export(bundle: b, document: doc, variant: v, to: url, progress: { p in
            progress?("\(v.name) \(Int(p * 100))%")
            let write: Bool = th.lock.withLock { if p - th.last >= 0.02 || p >= 1 { th.last = p; return true }; return false }
            if write { _ = try? store.update(id) { $0.progress = min(1, base + share * p) } }
        }, shouldCancel: { store.isCancelRequested(id) })
        if store.isCancelRequested(id) { throw RenderError.cancelled }
        var report: RenderReport?
        if inspect {
            report = try await RenderInspector.inspect(url: url, expectedDuration: expected, expectedSize: (w, h))
            try JSONCoding.encoder.encode(report).write(to: reportURL, options: .atomic)
        }
        let r = rel(b, url)
        var hashes = [r: try sha256(url)]
        if inspect { hashes[rel(b, reportURL)] = try sha256(reportURL) }
        job = try store.update(id) { j in
            if store.isCancelRequested(id) { throw RenderError.cancelled }
            guard let i = j.stages.firstIndex(where: { $0.name == name }) else { return }
            j.stages[i].status = .done; j.stages[i].finishedAt = Date()
            j.stages[i].artifacts = hashes.keys.sorted(); j.stages[i].hashes = hashes
            j.stages[i].detail = report.map { "\($0.quality.score)/100, \($0.quality.failures.count) failing check(s)" } ?? "rendered"
            j.progress = base + share
        }
        return RenderOutput(variant: v.name, path: url.path, width: w, height: h, duration: report?.duration ?? expected, seconds: Date().timeIntervalSince(start), report: report)
    }

    static func runRender(_ s: GlintService, _ b: ProjectBundle, _ store: JobStore, _ initial: Job, _ doc: ProjectDocument, _ progress: (@Sendable (String) -> Void)?) async throws -> Job {
        var job = initial
        let inspect = job.params["inspect"]?.boolValue ?? true
        let names = job.stages.map { String($0.name.dropFirst("render:".count)) }
        var outputs: [RenderOutput] = []
        for (i, n) in names.enumerated() {
            guard let v = RenderVariant.preset(n) else { throw ServiceError.invalid("Unknown variant \(n)") }
            outputs.append(try await renderStage(s, b, store, &job, stage: "render:\(n)", variant: v, doc: doc, inspect: inspect,
                                                 base: Double(i) / Double(names.count), share: 1 / Double(names.count), progress))
        }
        let m = RenderManifest(id: job.id, createdAt: Date(), author: job.author, revision: doc.revision, proposalID: job.params["proposal_id"]?.stringValue, outputs: outputs)
        try JSONCoding.encoder.encode(m).write(to: b.rendersURL.appendingPathComponent(job.id).appendingPathComponent("manifest.json"), options: .atomic)
        let failing = outputs.flatMap { o in (o.report?.quality.failures ?? []).map { "\(o.variant): \($0.message)" } }
        return try store.update(job.id) { j in
            if store.isCancelRequested(job.id) { throw RenderError.cancelled }
            j.progress = 1
            j.result = try? JSONValue.from(m)
            j.review = failing
            j.status = failing.isEmpty ? .succeeded : .needsReview
            j.message = failing.isEmpty ? "Rendered \(outputs.count) file\(outputs.count == 1 ? "" : "s")" : "Rendered, but \(failing.count) check(s) failed"
        }
    }

    static func runProduction(_ s: GlintService, _ b: ProjectBundle, _ store: JobStore, _ initial: Job, _ snapshot: ProjectDocument, _ progress: (@Sendable (String) -> Void)?) async throws -> Job {
        var job = initial
        let id = job.id
        let target = job.params["target_duration"]?.doubleValue
        let attempts = Int(job.params["max_attempts"]?.doubleValue ?? 2)
        func mark(_ name: String, _ status: JobStage.Status, _ detail: String? = nil) throws {
            job = try store.update(id) { j in
                guard let i = j.stages.firstIndex(where: { $0.name == name }) else { return }
                j.stages[i].status = status
                if status == .running { j.stages[i].startedAt = Date(); j.stages[i].attempts += 1 } else { j.stages[i].finishedAt = Date() }
                if let detail { j.stages[i].detail = detail }
                j.message = status == .running ? name : j.message
            }
        }
        func cancelled() -> Bool { store.isCancelRequested(id) }
        var review: [String] = []
        var doc = snapshot

        // Repair only the captured revision. Concurrent live edits must never silently replace the job's snapshot.
        func quality(_ document: ProjectDocument) -> QualityReport {
            let (w, h) = RenderPlan.outputSize(document: document)
            return EditQuality.report(document: document, events: b.programEvents(for: document), transcript: b.programTranscript(for: document),
                                      targetDuration: target, outputWidth: Double(w), outputHeight: Double(h))
        }
        if cancelled() { throw RenderError.cancelled }
        if job.stage("repair")?.status != .done {
            try mark("repair", .running)
            var notes: [String] = []
            if (job.params["repair"]?.boolValue ?? true), try b.readDocument().revision == doc.revision {
                for attempt in 0..<attempts {
                    if cancelled() { throw RenderError.cancelled }
                    let plan = QualityRepair.plan(report: quality(doc), document: doc, transcript: b.programTranscript(for: doc))
                    guard !plan.operations.isEmpty else { break }
                    let result = try s.engine(b).apply(plan.operations, label: "Repair \(attempt + 1): " + plan.fixed.joined(separator: ", "),
                                                       author: job.author, expectedRevision: doc.revision)
                    doc = try OperationApplier.apply(plan.operations, to: doc)
                    doc.revision = result.revision
                    notes += plan.fixed
                }
            }
            // Publish the repaired snapshot before checkpointing repair as complete.
            job = try store.update(id) { j in
                if cancelled() { throw RenderError.cancelled }
                try JSONCoding.encoder.encode(doc).write(to: snapshotURL(store, id), options: .atomic)
                if let i = j.stages.firstIndex(where: { $0.name == "repair" }) {
                    j.stages[i].status = .done; j.stages[i].finishedAt = Date()
                    j.stages[i].detail = notes.isEmpty ? "no automatic repair applied" : notes.joined(separator: "; ")
                }
                j.revision = doc.revision; j.progress = 0.15
            }
        }
        // Always recheck the actual snapshot, including retries which reuse repair/render checkpoints.
        try mark("quality", .running)
        let q = quality(doc)
        review += q.failures.map { "Edit: \($0.message)\($0.fix.map { " (suggested: \($0))" } ?? "")" }
        try mark("quality", .done, "\(q.score)/100, \(q.failures.count) failing")
        // 3. Render a draft from the (repaired) snapshot.
        let vname = job.params["variant"]?.stringValue ?? "preview"
        guard let v = RenderVariant.preset(vname) else { throw ServiceError.invalid("Unknown variant \(vname)") }
        let out = try await renderStage(s, b, store, &job, stage: "render:\(vname)", variant: v, doc: doc, inspect: true, base: 0.15, share: 0.7, progress)
        // 4. Inspect the actual file.
        try mark("inspect", .running)
        let rf = out.report?.quality.failures ?? []
        review += rf.map { "Render: \($0.message)" }
        if out.report == nil { review.append("Render: the file couldn't be measured") }
        try mark("inspect", .done, out.report.map { "\($0.quality.score)/100" } ?? "not measured")
        // 5. What the video demonstrates.
        try mark("evidence", .running)
        var evidence: JSONValue = .null
        if cancelled() { throw RenderError.cancelled }
        let recipeData = try? Data(contentsOf: store.recipeSnapshotURL(id))
        let recipe = recipeData.flatMap { try? JSONCoding.decoder.decode(DemoRecipe.self, from: $0) }
        if let recipe {
            let checkedDocument = try s.variantDocument(doc, v)
            let rep = try await s.verifyRecipe(b, author: job.author, document: checkedDocument, recipe: recipe, renderedURL: URL(fileURLWithPath: out.path))
            evidence = try JSONValue.from(rep)
            if rep.status != .verified {
                review += rep.items.filter { $0.required && $0.status != .verified }.map { "Evidence \($0.scene)/\($0.expectation): \($0.status.rawValue) — \($0.reason)" }
                review += rep.scenes.filter { !$0.inEdit }.map { "Evidence \($0.scene): scene is not in the rendered edit" }
                if review.isEmpty { review.append("Evidence: \(rep.summary)") }
            }
            try mark("evidence", .done, rep.summary)
        } else {
            review.append("No recipe: nothing checks what this video demonstrates. Save a recipe and record evidence to verify outcomes.")
            try mark("evidence", .skipped, "no recipe")
        }
        let m = RenderManifest(id: id, createdAt: Date(), author: job.author, revision: doc.revision, proposalID: nil, outputs: [out])
        try JSONCoding.encoder.encode(m).write(to: b.rendersURL.appendingPathComponent(id).appendingPathComponent("manifest.json"), options: .atomic)
        let final = review
        return try store.update(id) { j in
            if cancelled() { throw RenderError.cancelled }
            j.progress = 1
            j.review = final
            j.result = .object(["render": (try? JSONValue.from(out)) ?? .null, "evidence": evidence])
            j.status = final.isEmpty ? .succeeded : .needsReview
            j.message = final.isEmpty ? "Draft passed every check" : "Draft ready for review: \(final.count) item\(final.count == 1 ? "" : "s")"
        }
    }
}
