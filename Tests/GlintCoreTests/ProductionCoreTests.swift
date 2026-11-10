import Foundation
import Testing
@testable import GlintCore

private func doc(_ d: Double = 20) -> ProjectDocument {
    ProjectDocument(name: "t", media: MediaInfo(screen: "media/screen.mov", microphone: "media/mic.m4a", width: 1280, height: 800, scale: 2, duration: d, frameRate: 30))
}
private func shot(_ name: String, _ d: Double, scene: String? = nil) -> MediaClip {
    MediaClip(name: name, path: "media/clips/\(name).mov", mediaStart: 0, mediaEnd: d, audio: ["media/clips/\(name).mov"], scene: scene, width: 1280, height: 720, fileDuration: d)
}
private func tempBundle(_ d: ProjectDocument) throws -> ProjectBundle {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-prod-\(UUID().uuidString.prefix(8)).glint")
    return try ProjectBundle.create(at: url, document: d, events: EventLog())
}

@Suite struct ClipModelTests {
    @Test func legacyDocumentsLoadWithDefaultsAndUnchangedTiming() throws {
        // A project.json written before clips/annotations/redactions existed.
        let b = try tempBundle(doc())
        var raw = try JSONCoding.decoder.decode(JSONValue.self, from: Data(contentsOf: b.documentURL))
        if case .object(var o) = raw, case .object(var tl)? = o["timeline"] {
            for k in ["clips", "annotations", "redactions", "transitions", "audio"] { tl.removeValue(forKey: k) }
            o["timeline"] = .object(tl)
            if case .object(var st)? = o["style"], case .object(var cap)? = st["captions"] { cap.removeValue(forKey: "font"); st["captions"] = .object(cap); o["style"] = .object(st) }
            raw = .object(o)
        }
        try JSONCoding.encoder.encode(raw).write(to: b.documentURL)
        let d = try b.readDocument()
        #expect(d.timeline.clips.isEmpty && d.timeline.annotations.isEmpty && d.style.captions.font == "system")
        #expect(d.isSingleRecording && d.duration == 20 && d.effectiveClips.count == 1)
        // Events are passed through untouched for a single recording.
        var ev = EventLog(); ev.clicks = [ClickEvent(t: 3, x: 0.5, y: 0.5, button: .left)]
        #expect(EventLog.program(document: d, logs: ["events.json": ev]) == ev)
    }

    @Test func insertingAShotKeepsEditsOnTheirContent() throws {
        var d = doc()
        d.timeline.zooms = [ZoomSegment(id: "z1", start: 12, end: 15)]
        d.timeline.cuts = [Cut(id: "c1", start: 2, end: 3)]
        d.timeline.captions = [CaptionSegment(id: "k1", start: 13, end: 14, text: "hi", words: [CaptionWord(text: "hi", start: 13, end: 14)])]
        let after = try OperationApplier.apply([EditOperation(.insertClip, time: 10, shot: shot("b", 5))], to: d)
        #expect(after.duration == 25)
        #expect(after.effectiveClips.map(\.name).count == 3)   // recording split around the new shot
        let z = after.timeline.zooms[0]
        #expect(abs(z.start - 17) < 1e-6 && abs(z.end - 20) < 1e-6)
        #expect(after.timeline.cuts[0].start == 2)
        #expect(abs(after.timeline.captions[0].words[0].start - 18) < 1e-6)
        // Output time maps through: source 17 (the zoom's content) is 1 s of cut earlier on the output.
        let map = TimeMap(document: after)
        #expect(abs((map.output(forSource: 17) ?? -1) - 16) < 1e-6)
        #expect(abs(map.outputDuration - 24) < 1e-6)
    }

    @Test func appendingKeepsATrimmedTailTrimmed() throws {
        var d = doc()
        d.timeline.inPoint = 1
        d.timeline.outPoint = 18
        let after = try OperationApplier.apply([EditOperation(.insertClip, shot: shot("end", 4))], to: d)
        // The trimmed 18–20 of the recording becomes a cut; the new shot plays after it.
        #expect(after.timeline.inPoint == 1 && after.timeline.outPoint == nil)
        #expect(after.timeline.cuts.contains { abs($0.start - 18) < 1e-6 && abs($0.end - 20) < 1e-6 })
        #expect(abs(TimeMap(document: after).outputDuration - (17 + 4)) < 1e-6)
    }

    @Test func moveRemoveAndSplitRemapItems() throws {
        var d = try OperationApplier.apply([EditOperation(.insertClip, id: "b", shot: shot("b", 5))], to: doc(10))
        d.timeline.zooms = [ZoomSegment(id: "zr", start: 2, end: 4), ZoomSegment(id: "zb", start: 11, end: 13)]
        // Move the new shot first: its zoom moves with it, the recording's zoom shifts by 5 s.
        let moved = try OperationApplier.apply([EditOperation(.moveClip, id: "b", index: 0)], to: d)
        #expect(moved.timeline.zooms.first { $0.id == "zb" }.map { abs($0.start - 1) < 1e-6 } == true)
        #expect(moved.timeline.zooms.first { $0.id == "zr" }.map { abs($0.start - 7) < 1e-6 } == true)
        // Removing it drops the zoom that showed only its content.
        let removed = try OperationApplier.apply([EditOperation(.removeClip, id: "b")], to: moved)
        #expect(removed.timeline.zooms.map(\.id) == ["zr"] && abs(removed.timeline.zooms[0].start - 2) < 1e-6)
        // Splitting changes nothing in time.
        let split = try OperationApplier.apply([EditOperation(.splitClip, id: "s2", time: 3)], to: d)
        #expect(split.timeline.zooms == d.timeline.zooms && split.effectiveClips.count == 3)
    }

    @Test func replacingASceneKeepsManualIntentAndDropsAuto() throws {
        var d = try OperationApplier.apply([EditOperation(.insertClip, shot: shot("a", 6, scene: "intro")), EditOperation(.insertClip, shot: shot("b", 6, scene: "invite"))], to: doc(4))
        // Program: recording 0–4, intro 4–10, invite 10–16.
        d.timeline.zooms = [ZoomSegment(id: "m", start: 11, end: 13, origin: .manual), ZoomSegment(id: "a", start: 12, end: 14, origin: .auto),
                            ZoomSegment(id: "keep", start: 5, end: 7, origin: .manual)]
        d.timeline.redactions = [Redaction(id: "r", start: 10.5, end: 11, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))]
        let (after, report) = try ClipEditor.preview(EditOperation(.replaceClip, shot: shot("b2", 12), scene: "invite"), on: d)
        #expect(after.duration == 22)
        let m = try #require(after.timeline.zooms.first { $0.id == "m" })
        #expect(abs(m.start - (10 + 12 * (1.0 / 6))) < 1e-6)               // proportional inside the new shot
        #expect(!after.timeline.zooms.contains { $0.id == "a" })            // auto zoom dropped
        #expect(after.timeline.zooms.first { $0.id == "keep" }?.start == 5) // elsewhere untouched
        #expect(after.timeline.redactions.isEmpty)                          // a mask never moves onto other content
        #expect(report.retimedProportionally.contains("m") && report.dropped.contains("a") && report.dropped.contains("r"))
        #expect(after.effectiveClips.last?.scene == "invite")
    }

    @Test func clipValidation() throws {
        #expect(throws: EditError.self) { try OperationApplier.apply([EditOperation(.insertClip, shot: shot("x", 0.05))], to: doc()) }
        var bad = shot("y", 5); bad.mediaEnd = 9
        #expect(throws: EditError.self) { try OperationApplier.apply([EditOperation(.insertClip, shot: bad)], to: doc()) }
        var fakePrimary = shot("z", 5); fakePrimary.primary = true
        #expect(throws: EditError.self) { try OperationApplier.apply([EditOperation(.insertClip, shot: fakePrimary)], to: doc()) }
        #expect(throws: EditError.self) { try OperationApplier.apply([EditOperation(.removeClip, id: MediaClip.primaryID)], to: doc()) }
    }

    @Test func programEventsComeFromEachShotsTake() throws {
        var d = doc(10)
        var take = MediaClip(name: "take", path: "media/takes/t/screen.mov", mediaStart: 2, mediaEnd: 6, events: "media/takes/t/events.json", take: "t", width: 1280, height: 800)
        take.id = "tk"
        d = try OperationApplier.apply([EditOperation(.insertClip, time: 0, shot: take)], to: d)
        var primary = EventLog(); primary.clicks = [ClickEvent(t: 1, x: 0.1, y: 0.1, button: .left)]
        var tl = EventLog(); tl.clicks = [ClickEvent(t: 1, x: 0.9, y: 0.9, button: .left), ClickEvent(t: 3, x: 0.5, y: 0.5, button: .left)]
        let ev = EventLog.program(document: d, logs: ["events.json": primary, "media/takes/t/events.json": tl])
        // Take click at file 3 s → program 1 s; its click at 1 s is outside the shot; the recording's at 1 → 5.
        #expect(ev.clicks.map(\.t) == [1, 5])
        #expect(ev.clicks[0].x == 0.5)
    }
}

@Suite struct OverlayOperationTests {
    @Test func annotationsAndRedactionsValidate() throws {
        let d = doc()
        let ok = try OperationApplier.apply([
            EditOperation(.addAnnotation, id: "a1", item: .object(["kind": .string("arrow"), "start": .number(1), "end": .number(3),
                                                                   "from": .object(["x": .number(0.2), "y": .number(0.2)]), "to": .object(["x": .number(0.5), "y": .number(0.5)]),
                                                                   "color": .string("#FF0000")])),
            EditOperation(.addRedaction, id: "r1", item: .object(["start": .number(0), "end": .number(5), "rect": .object(["x": .number(0.6), "y": .number(0), "width": .number(0.4), "height": .number(0.1)]),
                                                                 "mode": .string("solid")])),
        ], to: d)
        #expect(ok.timeline.annotations[0].color.r == 1 && ok.timeline.redactions[0].mode == .solid)
        // Out-of-range geometry and time are rejected with a message, not clamped silently.
        func rejects(_ op: EditOperation) { #expect(throws: EditError.self) { _ = try OperationApplier.apply([op], to: d) } }
        rejects(EditOperation(.addRedaction, item: .object(["start": .number(0), "end": .number(5), "rect": .object(["x": .number(0.8), "y": .number(0), "width": .number(0.4), "height": .number(0.1)])])))
        rejects(EditOperation(.addRedaction, item: .object(["start": .number(19), "end": .number(25), "rect": .object(["x": .number(0), "y": .number(0), "width": .number(0.4), "height": .number(0.1)])])))
        rejects(EditOperation(.addRedaction, item: .object(["start": .number(1), "end": .number(2), "strength": .number(0.02), "rect": .object(["x": .number(0), "y": .number(0), "width": .number(0.4), "height": .number(0.1)])])))
        rejects(EditOperation(.addAnnotation, item: .object(["kind": .string("text"), "start": .number(1), "end": .number(2), "rect": .object(["x": .number(0.1), "y": .number(0.1), "width": .number(0.3), "height": .number(0.1)])])))
        rejects(EditOperation(.addAnnotation, item: .object(["kind": .string("arrow"), "start": .number(1), "end": .number(2)])))
        rejects(EditOperation(.addAnnotation, item: .object(["kind": .string("star"), "start": .number(1), "end": .number(2)])))
        // Update merges only the given fields.
        let moved = try OperationApplier.apply([EditOperation(.updateRedaction, id: "r1", item: .object(["end": .number(8)]))], to: ok)
        #expect(moved.timeline.redactions[0].end == 8 && moved.timeline.redactions[0].mode == .solid)
    }

    @Test func outputTimeBaseConvertsItemTimes() throws {
        var d = doc()
        d.timeline.cuts = [Cut(start: 0, end: 4)]
        let after = try OperationApplier.apply([EditOperation(.addAnnotation, timeBase: "output",
                                                              item: .object(["kind": .string("box"), "start": .number(1), "end": .number(2),
                                                                             "rect": .object(["x": .number(0.1), "y": .number(0.1), "width": .number(0.2), "height": .number(0.2)])]))], to: d)
        #expect(abs(after.timeline.annotations[0].start - 5) < 1e-6)
    }

    @Test func mergeStylePresetAndUnknownSections() throws {
        let p = StylePreset.builtIns.first { $0.name == "full-bleed" }!
        let d = try OperationApplier.apply([EditOperation(.mergeStyle, value: p.style)], to: doc())
        #expect(d.style.background.kind == .none && d.style.frame.padding == 0 && d.style.cursor.scale == 1.6)
        #expect(throws: EditError.self) { _ = try OperationApplier.apply([EditOperation(.mergeStyle, value: .object(["nope": .object([:])]))], to: doc()) }
        for preset in StylePreset.builtIns { _ = try OperationApplier.apply([EditOperation(.mergeStyle, value: preset.style)], to: doc()) }
    }

    @Test func undoRedoAndStaleRevisionCoverNewItems() throws {
        let b = try tempBundle(doc())
        let e = Engine(bundle: b)
        let r = try e.apply([EditOperation(.addRedaction, id: "r1", item: .object(["start": .number(1), "end": .number(2), "rect": .object(["x": .number(0), "y": .number(0), "width": .number(0.5), "height": .number(0.5)])])),
                             EditOperation(.insertClip, id: "c2", shot: shot("c2", 3))], author: .app)
        #expect(r.created.contains("r1") && r.created.contains("c2"))
        #expect(throws: EditError.staleRevision(expected: 0, actual: 1)) { try e.apply([.style("cursor.scale", .number(2))], author: .app, expectedRevision: 0) }
        try e.undo(author: .app)
        let undone = try b.readDocument()
        #expect(undone.timeline.redactions.isEmpty && undone.timeline.clips.isEmpty && undone.duration == 20)
        try e.redo(author: .app)
        #expect(try b.readDocument().duration == 23)
    }
}

@Suite struct SubtitleTests {
    @Test func exportedCuesFollowTheEditedOutput() throws {
        var d = doc(30)
        d.timeline.captions = [CaptionSegment(start: 1, end: 3, text: "Hello there"), CaptionSegment(start: 5, end: 9, text: "Across a cut"),
                               CaptionSegment(start: 12, end: 13, text: "hidden", hidden: true), CaptionSegment(start: 20, end: 22, text: "Fast part")]
        d.timeline.cuts = [Cut(start: 6, end: 8)]
        d.timeline.speeds = [SpeedSegment(start: 18, end: 24, rate: 2)]
        let cues = Subtitles.cues(document: d)
        // 1–3 unchanged; 5–9 loses 6–8 → 5–6 and 8–9 meet on the output at 5…7; 20–22 at 2× → 17…18.
        #expect(cues.count == 3)
        #expect(cues[0].start == 1 && cues[0].end == 3)
        #expect(abs(cues[1].start - 5) < 1e-6 && abs(cues[1].end - 7) < 1e-6)
        #expect(abs(cues[2].start - 17) < 1e-6 && abs(cues[2].end - 18) < 1e-6)
        let srt = Subtitles.format(cues, as: .srt)
        #expect(srt.contains("00:00:17,000 --> 00:00:18,000\nFast part"))
        let vtt = Subtitles.format(cues, as: .vtt)
        #expect(vtt.hasPrefix("WEBVTT") && vtt.contains("00:00:05.000 --> 00:00:07.000"))
        // Round trip: importing the exported file gives captions at the same source times.
        let back = Subtitles.captions(from: try Subtitles.parse(srt), document: d)
        #expect(abs(back[2].start - 20) < 0.01 && abs(back[2].end - 22) < 0.01)
        #expect(Subtitles.cues(document: { var x = d; x.timeline.captions = back; return x }()).map(\.text) == cues.map(\.text))
    }

    @Test func parseRejectsGarbage() {
        #expect(throws: EditError.self) { try Subtitles.parse("not subtitles") }
        #expect(throws: EditError.self) { try Subtitles.parse("1\n00:00:05,000 --> 00:00:02,000\nbackwards\n") }
        let vtt = try? Subtitles.parse("WEBVTT\n\nintro\n00:01.500 --> 00:03.000 align:start\n<b>Hi</b> there\n")
        #expect(vtt?.first == Subtitles.Cue(start: 1.5, end: 3, text: "Hi there"))
    }

    @Test func transcriptCutsSpareNeighbours() throws {
        let w = [CaptionWord(text: "So", start: 0, end: 0.3), CaptionWord(text: "um,", start: 0.5, end: 0.8), CaptionWord(text: "like", start: 0.82, end: 1.0),
                 CaptionWord(text: "this", start: 1.4, end: 1.7)]
        let found = TranscriptEdit.find("Um like", in: w)
        #expect(found.count == 1 && found[0] == (1, 2))
        let cuts = try TranscriptEdit.cuts(words: w, ranges: found)
        #expect(cuts.count == 1 && cuts[0].start >= 0.3 && cuts[0].end <= 1.4 && cuts[0].start < 0.5 && cuts[0].end > 1.0)
        #expect(throws: EditError.self) { try TranscriptEdit.cuts(words: w, ranges: [(2, 9)]) }
    }
}

@Suite struct AudioEnvelopeTests {
    @Test func musicFadesAndDucks() {
        let keys = AudioEnvelope.keys(span: TimeRange(0, 20), base: 0.5, fadeIn: 1, fadeOut: 2, duck: [TimeRange(5, 8)], duckLevel: 0.3)
        func g(_ t: Double) -> Double {
            for (a, b) in zip(keys, keys.dropFirst()) where t >= a.t && t <= b.t { return a.gain + (b.gain - a.gain) * (t - a.t) / max(1e-9, b.t - a.t) }
            return keys.last!.gain
        }
        #expect(g(0) == 0 && abs(g(1) - 0.5) < 1e-9)
        #expect(abs(g(6) - 0.15) < 1e-9)       // ducked to 30 %
        #expect(abs(g(10) - 0.5) < 1e-9)
        #expect(g(20) == 0 && abs(g(18) - 0.5) < 1e-9)
    }

    @Test func loopingFillsTheVideo() {
        let a = AudioClip(kind: .music, name: "bed", path: "m.m4a", fileDuration: 4)
        let spans = a.playSpans(outputStart: 1, videoEnd: 10)
        #expect(spans.count == 3 && abs(spans.last!.output.end - 10) < 1e-9)
        var once = a; once.loop = false
        #expect(once.playSpans(outputStart: 1, videoEnd: 10).count == 1)
    }
}

@Suite struct RecipeEvidenceTests {
    func recipe() -> DemoRecipe {
        DemoRecipe(title: "Invite a teammate", scenes: [
            RecipeScene(id: "open-settings", title: "Open settings", expectations: [RecipeExpectation(id: "visible", description: "Settings page", kind: .visibleText, text: "Settings")]),
            RecipeScene(id: "invite", title: "Send invite", expectations: [RecipeExpectation(id: "sent", description: "Invitation pending"),
                                                                          RecipeExpectation(id: "toast", description: "Toast", kind: .manual, required: false)]),
        ])
    }

    @Test func validationAndVersioning() throws {
        try recipe().validate()
        var dup = recipe(); dup.scenes.append(dup.scenes[0])
        #expect(throws: EditError.self) { try dup.validate() }
        var badID = recipe(); badID.scenes[0].id = "has space"
        #expect(throws: EditError.self) { try badID.validate() }
        var creds = recipe(); creds.fixtures = ["password: hunter2"]
        #expect(throws: EditError.self) { try creds.validate() }
        let v1 = recipe()
        #expect(v1.revised(from: v1).version == 1)
        var changed = v1; changed.scenes[0].steps = ["click Settings"]
        let v2 = changed.revised(from: v1)
        #expect(v2.version == 2 && v2.id == v1.id)
    }

    @Test func aClickNeverVerifiesAndUnknownNeverPasses() throws {
        let r = recipe()
        var d = doc(10)
        d = try OperationApplier.apply([EditOperation(.splitClip, id: "s2", time: 4), EditOperation(.updateClip, id: MediaClip.primaryID, scene: "open-settings"),
                                        EditOperation(.updateClip, id: "s2", scene: "invite")], to: d)
        let click = EvidenceRecord(scene: "invite", expectation: "sent", status: .verified, source: .action, detail: "clicked Send", take: "primary", author: Author(.agent, "t")).normalized()
        #expect(click.status == .needsReview && !click.notes.isEmpty)
        let vision = EvidenceRecord(scene: "invite", expectation: "sent", status: .verified, source: .vision, detail: "looks sent", observed: "toast", take: "primary", author: Author(.agent, "t")).normalized()
        #expect(vision.status == .needsReview)
        let noObs = EvidenceRecord(scene: "invite", expectation: "sent", status: .verified, source: .assertion, detail: "api", take: "primary", author: Author(.agent, "t")).normalized()
        #expect(noObs.status == .needsReview)

        var log = EvidenceLog(records: [click])
        var rep = RecipeReport.evaluate(recipe: r, document: d, evidence: log)
        #expect(rep.status == .needsReview)
        #expect(rep.items.first { $0.expectation == "visible" }?.reason == "no evidence for the current take")

        log.records.append(EvidenceRecord(scene: "open-settings", expectation: "visible", status: .verified, source: .ocr, detail: "ocr", observed: "Settings", take: "primary", author: .system))
        log.records.append(EvidenceRecord(scene: "invite", expectation: "sent", status: .verified, source: .assertion, detail: "GET /invites", observed: "1 pending", take: "primary", author: Author(.agent, "t")))
        rep = RecipeReport.evaluate(recipe: r, document: d, evidence: log)
        #expect(rep.status == .verified, "\(rep.summary)")   // the optional manual item doesn't gate

        // A later failure wins over an earlier verification.
        log.records.append(EvidenceRecord(scene: "invite", expectation: "sent", status: .failed, source: .assertion, detail: "invite missing after reload", take: "primary", author: Author(.agent, "t")))
        #expect(RecipeReport.evaluate(recipe: r, document: d, evidence: log).status == .failed)

        // Evidence from a take that no longer supplies the scene is stale.
        let refreshed = try OperationApplier.apply([EditOperation(.replaceClip, shot: MediaClip(name: "new", path: "media/takes/t2/screen.mov", mediaEnd: 5, scene: "invite", take: "t2", width: 1280, height: 800), scene: "invite")], to: d)
        let stale = RecipeReport.evaluate(recipe: r, document: refreshed, evidence: log)
        #expect(stale.items.first { $0.expectation == "sent" }?.status == .needsReview)
        #expect(stale.scenes.first { $0.scene == "invite" }?.take == "t2")
    }

    @Test func markersBindScenes() {
        let ranges = RecipeBinding.ranges(recipe: recipe(), markers: [Marker(time: 1, note: "scene:open-settings", author: .system),
                                                                      Marker(time: 4, note: "Send invite", author: .system),
                                                                      Marker(time: 6, note: "scene:unknown", author: .system)], end: 10)
        #expect(ranges.map(\.scene) == ["open-settings", "invite"])
        #expect(ranges[0].range == TimeRange(1, 4) && ranges[1].range == TimeRange(4, 10))
    }
}

@Suite struct JobStoreTests {
    @Test func idempotencyAndInterruption() throws {
        let b = try tempBundle(doc())
        let store = JobStore(bundle: b)
        let p: JSONValue = .object(["variants": .array([.string("preview")])])
        let (a, existed) = try store.create(Job(kind: .render, idempotencyKey: "k1", params: p, revision: 0, stages: ["render:preview"], author: .cli))
        #expect(!existed)
        let (again, existed2) = try store.create(Job(kind: .render, idempotencyKey: "k1", params: p, revision: 0, stages: ["render:preview"], author: .cli))
        #expect(existed2 && again.id == a.id)
        #expect(throws: JobError.self) { try store.create(Job(kind: .render, idempotencyKey: "k1", params: .object([:]), revision: 0, stages: [], author: .cli)) }
        // A running job whose process is gone reads back as interrupted.
        _ = try store.update(a.id) { $0.status = .running; $0.pid = 999_999; $0.stages[0].status = .running }
        let j = try store.get(a.id)
        #expect(j.status == .interrupted && j.stages[0].status == .pending)
        // Cancelling a job nobody is running cancels it outright.
        #expect(try store.requestCancel(a.id).status == .cancelled)
    }

    @Test func repairPlansAreBoundedAndLocal() {
        var d = doc()
        d.timeline.zooms = [ZoomSegment(id: "s", start: 2, end: 2.6), ZoomSegment(id: "n", start: 2.9, end: 6)]
        let report = QualityReport(checks: [QualityCheck("zoom_min_duration", .warn, "1 zoom shorter than 1.2s"), QualityCheck("zoom_pumping", .warn, "pumps"),
                                            QualityCheck("dead_air", .fail, "8s of nothing", fix: "plan_cuts")], metrics: [:])
        let plan = QualityRepair.plan(report: report, document: d, transcript: nil)
        #expect(plan.operations.allSatisfy { $0.op == .updateZoom })
        #expect(plan.fixed.count == 2)
        #expect(plan.unresolved.count == 1 && plan.unresolved[0].contains("plan_cuts"))   // never cuts content by itself
        _ = try? OperationApplier.apply(plan.operations, to: d)
    }

    @Test func stableHashIsStable() { #expect(StableHash.hex("glint") == "\(StableHash.hex("glint"))" && StableHash.fnv1a("a") == 0xaf63dc4c8601ec8c) }
}

@Suite struct ImportedShotPlanningTests {
    @Test func importedMoviesAreNeverTreatedAsIdle() throws {
        // A recording with input, then a 10 s imported movie with no events.
        var d = ProjectDocument(name: "t", media: MediaInfo(screen: "media/screen.mov", width: 1280, height: 800, scale: 2, duration: 6, frameRate: 30))
        d = try OperationApplier.apply([EditOperation(.insertClip, shot: MediaClip(name: "broll", path: "media/clips/b.mov", mediaEnd: 10, width: 1280, height: 720))], to: d)
        var ev = EventLog()
        ev.pointer = stride(from: 0.0, through: 6, by: 0.1).map { PointerSample(t: $0, x: 0.5, y: 0.5) }   // idle in the recording
        let plan = CutPlanner.plan(document: d, events: ev, transcript: nil, silences: nil)
        #expect(!plan.speeds.isEmpty)
        #expect(plan.speeds.allSatisfy { $0.end <= 6 + 1e-6 }, "\(plan.speeds)")
    }
}
