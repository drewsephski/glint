import Foundation
import Testing
@testable import GlintCore

func makeDoc(duration: Double = 30) -> ProjectDocument {
    ProjectDocument(name: "Test", media: MediaInfo(screen: "media/screen.mov", width: 3024, height: 1964, scale: 2, duration: duration, frameRate: 60))
}

func tempBundle(_ doc: ProjectDocument = makeDoc(), events: EventLog = EventLog()) throws -> ProjectBundle {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-test-\(UUID().uuidString).glint")
    return try ProjectBundle.create(at: url, document: doc, events: events)
}

@Suite struct JSONPatchTests {
    @Test func diffAndApplyRoundTrip() throws {
        let a: JSONValue = .object(["a": .number(1), "b": .array([.number(1), .number(2)]), "c": .object(["d": .string("x")])])
        let b: JSONValue = .object(["a": .number(2), "b": .array([.number(1)]), "c": .object(["e": .bool(true)])])
        let ops = JSONPatch.diff(a, b)
        #expect(try JSONPatch.apply(ops, to: a) == b)
        #expect(try JSONPatch.apply(ops.reversed().map(\.inverse), to: b) == a)
    }

    @Test func identityArrayDiffIsMinimal() throws {
        let x: JSONValue = .object(["id": .string("x"), "v": .number(1)])
        let y: JSONValue = .object(["id": .string("y"), "v": .number(2)])
        let z: JSONValue = .object(["id": .string("z"), "v": .number(3)])
        let a: JSONValue = .array([x, y]), b: JSONValue = .array([x, z, .object(["id": .string("y"), "v": .number(9)])])
        let ops = JSONPatch.diff(a, b)
        #expect(ops.count == 2)       // add z at 1, replace y.v
        #expect(try JSONPatch.apply(ops, to: a) == b)
        #expect(try JSONPatch.apply(ops.reversed().map(\.inverse), to: b) == a)
    }

    @Test func verifyDetectsConflict() throws {
        let a: JSONValue = .object(["k": .number(1)])
        let op = PatchOp(op: .replace, path: "/k", value: .number(2), old: .number(5))
        #expect(throws: PatchError.self) { try JSONPatch.apply([op], to: a, verify: true) }
    }
}

@Suite struct TimeMapTests {
    @Test func cutsAndSpeed() {
        var doc = makeDoc(duration: 20)
        doc.timeline.cuts = [Cut(start: 5, end: 7)]
        doc.timeline.speeds = [SpeedSegment(start: 10, end: 14, rate: 2)]
        let m = TimeMap(document: doc)
        // 0-5 (5) + 7-10 (3) + 10-14 @2x (2) + 14-20 (6) = 16
        #expect(abs(m.outputDuration - 16) < 1e-9)
        #expect(m.output(forSource: 6) == nil)
        #expect(abs(m.output(forSource: 8)! - 6) < 1e-9)
        #expect(abs(m.output(forSource: 12)! - 9) < 1e-9)
        #expect(abs(m.source(forOutput: 9) - 12) < 1e-9)
        #expect(abs(m.source(forOutput: 15) - 19) < 1e-9)
        #expect(abs(m.outputClamped(forSource: 6) - 5) < 1e-9)
    }

    @Test func trimPoints() {
        var doc = makeDoc(duration: 20)
        doc.timeline.inPoint = 2; doc.timeline.outPoint = 12
        let m = TimeMap(document: doc)
        #expect(abs(m.outputDuration - 10) < 1e-9)
        #expect(abs(m.source(forOutput: 0) - 2) < 1e-9)
    }
}

@Suite struct EngineTests {
    @Test func applyUndoRedo() throws {
        let b = try tempBundle()
        let e = Engine(bundle: b)
        let r = try e.apply([EditOperation(.addZoom, start: 2, end: 5, scale: 2.2)], author: Author(.agent, "test"))
        #expect(r.revision == 1)
        #expect(r.created.count == 1)
        #expect(try e.document().timeline.zooms.count == 1)
        try e.undo(author: .cli)
        #expect(try e.document().timeline.zooms.isEmpty)
        #expect(try e.document().revision == 2)
        try e.redo(author: .cli)
        #expect(try e.document().timeline.zooms.first?.scale == 2.2)
        #expect(throws: EditError.self) { try e.redo(author: .cli) }
    }

    @Test func staleRevisionRejected() throws {
        let e = Engine(bundle: try tempBundle())
        try e.apply([EditOperation(.addCut, start: 1, end: 2)], author: .cli)
        #expect(throws: EditError.staleRevision(expected: 0, actual: 1)) {
            try e.apply([EditOperation(.addCut, start: 3, end: 4)], author: .cli, expectedRevision: 0)
        }
    }

    @Test func selectiveRevert() throws {
        let e = Engine(bundle: try tempBundle())
        let a = try e.apply([EditOperation(.addZoom, id: "z_a", start: 1, end: 3)], author: .cli)
        try e.apply([.style("background.preset", .string("ocean"))], author: .cli)
        try e.apply([EditOperation(.addZoom, id: "z_b", start: 5, end: 8)], author: .cli)
        try e.revert(a.transaction, author: .cli)
        let d = try e.document()
        #expect(d.timeline.zooms.map(\.id) == ["z_b"])
        #expect(d.style.background.preset == "ocean")
        // Revert is itself undoable.
        try e.undo(author: .cli)
        #expect(try e.document().timeline.zooms.map(\.id) == ["z_a", "z_b"])
    }

    @Test func revertConflictIsReported() throws {
        let e = Engine(bundle: try tempBundle())
        let a = try e.apply([EditOperation(.addZoom, id: "z_a", start: 1, end: 3, scale: 2)], author: .cli)
        try e.apply([EditOperation(.updateZoom, id: "z_a", scale: 3)], author: .cli)
        #expect(throws: EditError.self) { try e.revert(a.transaction, author: .cli) }
    }

    @Test func outputTimeBase() throws {
        var doc = makeDoc(duration: 20)
        doc.timeline.cuts = [Cut(start: 0, end: 4)]
        let e = Engine(bundle: try tempBundle(doc))
        try e.apply([EditOperation(.addZoom, start: 1, end: 3, timeBase: "output")], author: .cli)
        let z = try #require(try e.document().timeline.zooms.first)
        #expect(abs(z.start - 5) < 1e-9 && abs(z.end - 7) < 1e-9)
    }

    @Test func styleValidation() throws {
        let e = Engine(bundle: try tempBundle())
        try e.apply([.style("cursor.scale", .number(2)), .style("background.colors", .array([.string("#112233"), .string("#445566")]))], author: .cli)
        let d = try e.document()
        #expect(d.style.cursor.scale == 2)
        #expect(d.style.background.colors.first?.hex == "#112233")
        #expect(throws: EditError.self) { try e.apply([.style("cursor.nope", .number(1))], author: .cli) }
        #expect(throws: EditError.self) { try e.apply([.style("cursor.scale", .string("big"))], author: .cli) }
    }

    @Test func proposals() throws {
        let e = Engine(bundle: try tempBundle())
        let p = try e.propose(title: "Zooms", rationale: "clicks", operations: [EditOperation(.addZoom, start: 1, end: 4)], author: Author(.agent, "t"))
        #expect(try e.document().timeline.zooms.isEmpty)
        #expect(e.proposals().count == 1)
        let r = try e.applyProposal(p.id, author: .app)
        #expect(try e.document().timeline.zooms.count == 1)
        #expect(try e.proposal(p.id).status == .applied)
        #expect(try e.proposal(p.id).appliedTransaction == r.transaction)
        #expect(throws: EditError.self) { try e.applyProposal(p.id, author: .app) }
        #expect(throws: EditError.self) { try e.propose(title: "bad", rationale: "", operations: [EditOperation(.removeZoom, id: "nope")], author: .cli) }
    }

    @Test func historyRecordsAuthors() throws {
        let e = Engine(bundle: try tempBundle())
        try e.apply([EditOperation(.addCut, start: 1, end: 2)], author: Author(.agent, "claude"))
        let h = e.history()
        #expect(h.count == 1)
        #expect(h[0].author == Author(.agent, "claude"))
        #expect(!h[0].forward.isEmpty)
    }
}

@Suite struct PlannerTests {
    func clicks(_ specs: [(Double, Double, Double)]) -> EventLog {
        var log = EventLog()
        log.clicks = specs.map { ClickEvent(t: $0.0, x: $0.1, y: $0.2) }
        var t = 0.0
        while t < 30 { log.pointer.append(PointerSample(t: t, x: 0.5, y: 0.5)); t += 0.1 }
        return log
    }

    @Test func clustersNearbyClicks() {
        let log = clicks([(3, 0.2, 0.2), (4, 0.22, 0.25), (12, 0.8, 0.8)])
        let z = ZoomPlanner.plan(document: makeDoc(), events: log)
        #expect(z.count == 2)
        #expect(z[0].start < 3 && z[0].end > 4)
        #expect(z[0].reason?.contains("2× click") == true)
    }

    @Test func farApartClicksSplitAndNeighboursDoNotPump() {
        let log = clicks([(3, 0.1, 0.1), (4.2, 0.9, 0.9)])
        let z = ZoomPlanner.plan(document: makeDoc(), events: log)
        #expect(z.count == 2)
        // Butted together: no gap → camera pans instead of zooming out and in.
        #expect(abs(z[0].end - z[1].start) < 1e-6)
    }

    @Test func ignoresCutClicks() {
        var doc = makeDoc()
        doc.timeline.cuts = [Cut(start: 2, end: 5)]
        let z = ZoomPlanner.plan(document: doc, events: clicks([(3, 0.2, 0.2)]))
        #expect(z.isEmpty)
    }

    @Test func cutPlannerSilenceVsActivity() {
        var log = EventLog()
        for i in 0..<300 { log.pointer.append(PointerSample(t: Double(i) * 0.1, x: 0.5, y: 0.5)) }
        // Moving pointer between 14 and 18.
        for i in 140..<180 { log.pointer[i] = PointerSample(t: Double(i) * 0.1, x: 0.3 + Double(i - 140) * 0.01, y: 0.5) }
        log.clicks = [ClickEvent(t: 1, x: 0.5, y: 0.5), ClickEvent(t: 28, x: 0.5, y: 0.5)]
        let tr = Transcript(engine: "t", locale: "en", source: "mic", words: [CaptionWord(text: "hello", start: 1, end: 2), CaptionWord(text: "um", start: 4, end: 4.3), CaptionWord(text: "world", start: 25, end: 26)])
        let plan = CutPlanner.plan(document: makeDoc(), events: log, transcript: tr, silences: [TimeRange(5, 10), TimeRange(13.5, 19)])
        #expect(plan.cuts.contains { abs($0.start - 5.3) < 1e-6 })
        #expect(plan.cuts.contains { $0.reason?.contains("filler") == true })
        #expect(plan.speeds.contains { $0.start >= 13.5 && $0.end <= 19 })
    }

    @Test func fillerCutsNeverClipNeighbouringWords() {
        // A recogniser stretched "Um," over the pause before it (5.64–7.08); "now" starts at 7.08.
        let tr = Transcript(engine: "t", locale: "en", source: "mic", words: [
            CaptionWord(text: "report.", start: 3.9, end: 4.32), CaptionWord(text: "Um,", start: 5.64, end: 7.08),
            CaptionWord(text: "now", start: 7.08, end: 7.38)])
        var o = CutPlanOptions(); o.trimEnds = false
        let plan = CutPlanner.plan(document: makeDoc(), events: EventLog(), transcript: tr, silences: [], options: o)
        let cut = plan.cuts.first { $0.reason?.contains("filler") == true }
        #expect(cut != nil)
        #expect(cut!.end <= 7.08 - 0.03 + 1e-9)            // doesn't touch "now"
        #expect(cut!.end - cut!.start <= 0.65)              // just the filler, not the pause
    }

    @Test func captionSegmentation() {
        let words = "This is a short demo of the export flow. Now we click save and watch it render".split(separator: " ").enumerated().map {
            CaptionWord(text: String($1), start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25)
        }
        let segs = CaptionBuilder.segments(from: words)
        #expect(segs.count >= 2)
        #expect(segs[0].text.hasSuffix("flow."))
        #expect(segs.allSatisfy { $0.text.count <= 42 })
        for (a, b) in zip(segs, segs.dropFirst()) { #expect(a.end <= b.start) }
    }
}

@Suite struct MotionTests {
    @Test func cursorPinnedAtClicks() {
        var log = EventLog()
        var g = SystemRandomNumberGenerator()
        for i in 0..<600 {
            let t = Double(i) / 120
            let jitter = Double(g.next() % 100) / 100_000
            log.pointer.append(PointerSample(t: t, x: 0.2 + t * 0.1 + jitter, y: 0.5 + jitter))
        }
        log.clicks = [ClickEvent(t: 2.5, x: 0.45, y: 0.5)]
        log.pointer[300] = PointerSample(t: 2.5, x: 0.45, y: 0.5)
        var style = CursorStyle(); style.smoothing = 1
        let path = CursorPath(log: log, duration: 5, style: style)
        let p = path.position(at: 2.5)
        #expect(abs(p.x - 0.45) < 0.002)
    }

    @Test func cameraDeterministicAndSettles() {
        var doc = makeDoc(duration: 10)
        doc.timeline.zooms = [ZoomSegment(start: 2, end: 6, scale: 2, focus: .point(NormPoint(0.3, 0.3)))]
        let layout = CanvasLayout(document: doc, outputWidth: 1920, outputHeight: 1080)
        let map = TimeMap(document: doc)
        let cur = CursorPath(log: EventLog(), duration: 10, style: CursorStyle())
        let a = CameraPath(document: doc, map: map, cursor: cur, layout: layout)
        let b = CameraPath(document: doc, map: map, cursor: cur, layout: layout)
        #expect(a.samples == b.samples)
        #expect(abs(a.state(at: 1).scale - 1) < 1e-6)
        #expect(abs(a.state(at: 5).scale - 2) < 0.02)
        #expect(abs(a.state(at: 9.5).scale - 1) < 0.02)
        // Zoomed viewport stays over the screen.
        let s = a.state(at: 5)
        #expect(s.cx - 0.25 >= layout.screenRect.x - 1e-6)
    }
}

@Suite struct ApprovalTests {
    @Test func agentCaptureNeedsApproval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-approvals-\(UUID().uuidString)")
        let store = ApprovalStore(directory: dir)
        let params: JSONValue = .object(["display": .number(1)])
        let agent = Author(.agent, "claude")
        var requestID = ""
        do {
            try store.authorize(action: "record_start", risk: .capture, summary: "Record display 1", parameters: params, author: agent, approvalID: nil)
            Issue.record("expected approval to be required")
        } catch ApprovalError.required(let r) { requestID = r.id }
        // Same request is reused, not duplicated.
        #expect(throws: ApprovalError.self) { try store.authorize(action: "record_start", risk: .capture, summary: "x", parameters: params, author: agent, approvalID: nil) }
        #expect(store.pending().count == 1)
        _ = try store.decide(requestID, approve: true, by: "test-user")
        // Different parameters can't use it.
        #expect(throws: ApprovalError.self) { try store.authorize(action: "record_start", risk: .capture, summary: "x", parameters: .object(["display": .number(2)]), author: agent, approvalID: requestID) }
        try store.authorize(action: "record_start", risk: .capture, summary: "x", parameters: params, author: agent, approvalID: requestID)
        // Single use.
        #expect(throws: ApprovalError.self) { try store.authorize(action: "record_start", risk: .capture, summary: "x", parameters: params, author: agent, approvalID: requestID) }
        // Reversible edits by agents and capture by users pass without approval.
        try store.authorize(action: "apply_operations", risk: .reversible, summary: "", parameters: .null, author: agent, approvalID: nil)
        try store.authorize(action: "record_start", risk: .capture, summary: "", parameters: .null, author: .cli, approvalID: nil)
    }
}

@Suite struct QualityTests {
    @Test func detectsPumpingAndDeadAir() {
        var doc = makeDoc(duration: 30)
        doc.timeline.zooms = [ZoomSegment(start: 2, end: 4), ZoomSegment(start: 4.3, end: 6)]
        var log = EventLog()
        for i in 0..<300 { log.pointer.append(PointerSample(t: Double(i) * 0.1, x: 0.5, y: 0.5)) }
        log.clicks = [ClickEvent(t: 3, x: 0.5, y: 0.5)]
        let r = EditQuality.report(document: doc, events: log, transcript: nil)
        #expect(r.checks.first { $0.id == "zoom_pumping" }?.verdict == .warn)
        #expect(r.checks.first { $0.id == "dead_air" }?.verdict == .fail)
        #expect(r.score < 100)
    }
}
