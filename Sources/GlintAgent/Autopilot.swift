import Foundation
import GlintCore
import GlintRender
import GlintAnalysis

/// The end-to-end "turn a raw take into a polished demo" workflow, built only from public service calls.
///
/// Every step reports `ok`, `skipped` (not applicable) or `failed`. A step the caller asked for explicitly is
/// required: if it fails, the run's status is `failed`. Otherwise the run is `needs_review` unless the edit passes its
/// quality checks, requested renders measure clean, and a recipe's required outcomes are verified — only then
/// `ready`. An unchecked draft is never reported as a success.
public enum Autopilot {
    public static func run(_ b: ProjectBundle, args a: JSONValue, context c: ToolContext) async throws -> ToolOutput {
        var steps: [JSONValue] = []
        var failedRequired: [String] = []
        var review: [String] = []
        let proposeOnly = a.flag("propose_only") == true
        let s = c.service
        func step(_ name: String, _ status: String, _ detail: JSONValue, required: Bool = false) {
            steps.append(.object(["step": .string(name), "status": .string(status), "required": .bool(required), "result": detail]))
            if status == "failed", required { failedRequired.append(name) }
            c.progress?("\(name): \(status)")
        }
        func commit(_ ops: [EditOperation], _ title: String) throws -> JSONValue {
            guard !ops.isEmpty else { return .string("nothing to do") }
            let e = s.engine(b)
            if proposeOnly { return .object(["proposal_id": .string(try e.propose(title: title, rationale: "autopilot", operations: ops, author: c.author).id)]) }
            return try JSONValue.from(try e.apply(ops, label: title, author: c.author))
        }
        let doc = try b.readDocument()
        if let e = a.num("expected_revision").map({ Int($0) }), e != doc.revision { throw EditError.staleRevision(expected: e, actual: doc.revision) }
        let captionsRequested = a.flag("captions") == true
        let narrate = a.flag("narrate") == true

        // 1. Transcribe when there is a voice track and no transcript.
        if doc.media.microphone != nil || doc.media.systemAudio != nil {
            if b.readTranscript() == nil {
                do {
                    let t = try await s.transcribe(b, locale: a.str("locale") ?? "en-US", engine: .auto, source: nil)
                    step("transcribe", "ok", .string("\(t.words.count) words via \(t.engine)"))
                } catch {
                    step("transcribe", "failed", .string("\(error)"), required: captionsRequested)
                    if !captionsRequested { review.append("Transcription failed (\(error)); captions and filler-word cuts were skipped.") }
                }
            } else { step("transcribe", "skipped", .string("already transcribed")) }
        } else { step("transcribe", "skipped", .string("no audio track")) }

        // 2–3. Tighten and zoom.
        do {
            let (cutOps, plan) = try await s.planCuts(b, options: CutPlanOptions())
            step("plan_cuts", "ok", try commit(cutOps, "Autopilot: tighten (\(plan.cuts.count) cuts, \(plan.speeds.count) speed-ups)"))
        } catch { step("plan_cuts", "failed", .string("\(error)"), required: true) }
        do {
            let (zoomOps, zooms) = try s.planZooms(b, options: ZoomPlanOptions())
            step("plan_zooms", "ok", try commit(zoomOps, "Autopilot: \(zooms.count) zooms"))
        } catch { step("plan_zooms", "failed", .string("\(error)"), required: true) }

        // 4. Narration (external, gated) or captions from the transcript.
        var narrated = false
        if narrate {
            do {
                let sb = try await s.analyzeScenes(b, progress: c.progress)
                step("analyze_scenes", "ok", .string("\(sb.scenes.count) scenes"), required: true)
                var o = NarrationOptions(); o.brief = a.str("brief")
                let written = try await s.writeNarration(b, options: o, author: c.author, approvalID: a.str("approval_id"))
                step("write_narration", "ok", .string("\(written.narratedScenes.count) lines by \(written.writer ?? o.model)"), required: true)
                let r = try await s.voiceover(b, voice: a.str("voice"), fit: true, captions: a.flag("captions") ?? true, author: c.author,
                                              approvalID: a.str("approval_id"), progress: c.progress)
                step("voiceover", "ok", r.operations.isEmpty ? .string(r.fitNotes.first ?? "nothing to synthesize")
                                                              : try commit(r.operations, "Autopilot: voiceover (\(r.clips.count) clips, \(r.voiceName))"), required: true)
                narrated = true
            } catch ApprovalError.required(let req) {
                // Waiting on the person is not a failure: report what to approve and stop here.
                step("narration", "approval_required", try JSONValue.from(req), required: true)
                return ToolOutput(json: .object(["status": .string("approval_required"), "steps": .array(steps),
                                                 "approval_id": .string(req.id),
                                                 "next": .string("Ask the user to approve \(req.id), then call glint_autopilot again with approval_id.")]))
            } catch {
                step("narration", "failed", .string("\(error)"), required: true)
            }
        }
        if !narrated {
            if (a.flag("captions") ?? true), let t = b.programTranscript(for: try b.readDocument()), t.words.count >= 3 {
                do { step("captions", "ok", try commit(try s.captionOps(b), "Autopilot: captions"), required: captionsRequested) }
                catch { step("captions", "failed", .string("\(error)"), required: captionsRequested) }
            } else if captionsRequested {
                step("captions", "failed", .string("no transcript with speech to caption"), required: true)
            } else { step("captions", "skipped", .string("no speech")) }
        }

        // 5. Measure.
        let q = try s.quality(b, proposal: nil, targetDuration: a.num("target_duration"))
        step("quality", q.failures.isEmpty ? "ok" : "needs_review", try JSONValue.from(q))
        review += q.failures.map { "Edit: \($0.message)\($0.fix.map { " (suggested: \($0))" } ?? "")" }

        var renders: JSONValue = .null
        if let vs = a["variants"]?.arrayValue, !vs.isEmpty {
            if proposeOnly {
                step("render", "skipped", .string("propose_only: apply the proposals first"))
                review.append("Edits are pending proposals; nothing was rendered.")
            } else {
                do {
                    let m = try await s.render(b, variants: try ToolRegistry.variants(a), proposal: nil, author: c.author)
                    renders = try JSONValue.from(m)
                    let bad = m.outputs.flatMap { o in (o.report?.quality.failures ?? []).map { "Render \(o.variant): \($0.message)" } }
                    step("render", bad.isEmpty ? "ok" : "needs_review", .string("\(m.outputs.count) file(s) in \(m.id)"), required: true)
                    review += bad
                } catch { step("render", "failed", .string("\(error)"), required: true) }
            }
        }

        // 6. What the video shows.
        if b.readRecipe() != nil {
            do {
                let rep = try await s.verifyRecipe(b, author: c.author)
                step("evidence", rep.status == .verified ? "ok" : rep.status == .failed ? "failed" : "needs_review", try JSONValue.from(rep), required: rep.status == .failed)
                if rep.status != .verified { review += rep.items.filter { $0.required && $0.status != .verified }.map { "Evidence \($0.scene)/\($0.expectation): \($0.status.rawValue)" } }
            } catch { step("evidence", "failed", .string("\(error)"), required: true) }
        } else {
            review.append("No recipe: what this demo shows hasn't been checked.")
        }

        let status = !failedRequired.isEmpty ? "failed" : (proposeOnly ? "draft" : (review.isEmpty ? "ready" : "needs_review"))
        return ToolOutput(json: .object(["status": .string(status), "failed_steps": .array(failedRequired.map(JSONValue.string)),
                                         "review": .array(review.map(JSONValue.string)), "steps": .array(steps), "render": renders,
                                         "summary": try JSONValue.from(try s.summary(b))]))
    }
}
