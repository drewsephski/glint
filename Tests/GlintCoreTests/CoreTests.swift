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

    @Test func facecamLayoutStaysInsideTheCanvas() {
        var st = FacecamStyle()
        // Default: bottom-right circle, a quarter of the shorter side, inside the margin.
        let r = FacecamLayout.rect(st, canvasWidth: 1920, canvasHeight: 1080)
        #expect(abs(r.height * 1080 - 0.24 * 1080) < 0.01 && abs(r.width * 1920 - r.height * 1080) < 0.01)
        #expect(abs((1 - r.x - r.width) * 1920 - 0.04 * 1080) < 0.01 && abs((1 - r.y - r.height) * 1080 - 0.04 * 1080) < 0.01)
        // Zoomed in, it shrinks but stays pinned to its corner.
        let z = FacecamLayout.rect(st, canvasWidth: 1920, canvasHeight: 1080, zoomed: 1)
        #expect(abs(z.height - r.height * 0.75) < 1e-9 && abs((z.x + z.width) - (r.x + r.width)) < 1e-9 && abs((z.y + z.height) - (r.y + r.height)) < 1e-9)
        #expect(FacecamLayout.zoomed(cameraScale: 1, restScale: 1) == 0 && FacecamLayout.zoomed(cameraScale: 2, restScale: 1) == 1)
        #expect(FacecamLayout.zoomed(cameraScale: 1.75, restScale: 1.75) == 0)      // a reframed variant at rest isn't "zoomed"
        // Every corner and shape fits, including an oversized wide bubble on a portrait canvas.
        st.size = 0.6
        for shape in FacecamStyle.Shape.allCases {
            for corner in FacecamStyle.Corner.allCases {
                st.shape = shape; st.position = corner
                for (w, h) in [(1920.0, 1080.0), (1080.0, 1920.0), (1080.0, 1080.0)] {
                    let q = FacecamLayout.rect(st, canvasWidth: w, canvasHeight: h)
                    #expect(q.x >= 0 && q.y >= 0 && q.x + q.width <= 1 + 1e-9 && q.y + q.height <= 1 + 1e-9, "\(shape) \(corner) \(w)x\(h)")
                    #expect(abs(q.width * w / (q.height * h) - st.aspect) < 1e-6)
                    #expect(corner.isLeft ? q.x < 0.5 : q.x + q.width > 0.5)
                    #expect(corner.isTop ? q.y < 0.5 : q.y + q.height > 0.5)
                }
            }
        }
    }

    @Test func facecamStyleIsEditableAndOldProjectsGetDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-facecam-\(UUID().uuidString.prefix(6)).glint")
        let b = try ProjectBundle.create(at: url, document: ProjectDocument(name: "t", media: MediaInfo(screen: "media/screen.mov", width: 100, height: 100, scale: 2, duration: 5, frameRate: 30)), events: EventLog())
        let e = Engine(bundle: b)
        try e.apply([.style("facecam.shape", .string("square")), .style("facecam.position", .string("top-left")), .style("facecam.borderColor", .string("#3399FF"))], author: .cli)
        var doc = try b.readDocument()
        #expect(doc.style.facecam.shape == .square && doc.style.facecam.position == .topLeft && doc.style.facecam.borderColor.hex == "#3399FF")
        #expect(throws: EditError.self) { try e.apply([.style("facecam.position", .string("middle"))], author: .cli) }
        try e.undo(author: .cli)
        #expect(try b.readDocument().style.facecam == FacecamStyle())
        // A project written before the facecam existed has no `style.facecam`: it loads with the defaults.
        var raw = try JSONCoding.decoder.decode(JSONValue.self, from: Data(contentsOf: b.documentURL))
        if case .object(var o) = raw, case .object(var style)? = o["style"] { style.removeValue(forKey: "facecam"); o["style"] = .object(style); raw = .object(o) }
        try JSONCoding.encoder.encode(raw).write(to: b.documentURL)
        doc = try b.readDocument()
        #expect(doc.style.facecam == FacecamStyle())
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

@Suite struct NarrationTests {
    func log() -> EventLog {
        var l = EventLog()
        var t = 0.0
        while t < 30 { l.pointer.append(PointerSample(t: t, x: 0.5, y: 0.5)); t += 0.1 }
        // Two bursts of work far apart, then a marker-led section.
        l.clicks = [ClickEvent(t: 2, x: 0.2, y: 0.2, target: "New Note"), ClickEvent(t: 3, x: 0.25, y: 0.2),
                    ClickEvent(t: 12, x: 0.8, y: 0.8, target: "Publish")]
        for i in 0..<12 { l.keys.append(KeyEvent(t: 4 + Double(i) * 0.15)) }
        l.markers = [Marker(time: 20, note: "Settings", author: .app)]
        l.clicks.append(ClickEvent(t: 22, x: 0.5, y: 0.5))
        return l
    }

    @Test func scenesFollowInputAndMarkers() {
        let scenes = SceneSegmenter.scenes(document: makeDoc(), events: log(), transcript: nil)
        #expect(scenes.count == 3)
        #expect(scenes[0].start == 0 && scenes.last!.end == 30)
        #expect(scenes[0].title == "“New Note”")
        #expect(scenes[0].actions.contains { $0.hasPrefix("typing") })
        #expect(scenes[1].title == "“Publish”")
        #expect(abs(scenes[2].start - 20) < 1e-6, "marker starts a scene")
        #expect(scenes[2].title == "Settings")
        // Scenes tile the kept range.
        for (a, b) in zip(scenes, scenes.dropFirst()) { #expect(abs(a.end - b.start) < 1e-6) }
    }

    @Test func scenesSkipCutsAndRespectTrim() {
        var doc = makeDoc()
        doc.timeline.cuts = [Cut(start: 11, end: 13)]
        doc.timeline.outPoint = 25
        let scenes = SceneSegmenter.scenes(document: doc, events: log(), transcript: nil)
        #expect(!scenes.contains { $0.title == "“Publish”" }, "a cut click isn't a scene anchor")
        #expect(scenes.last!.end == 25)
    }

    @Test func fitStretchesShortScenesAndCompressesLongOnes() throws {
        let doc = makeDoc()
        let scenes = SceneSegmenter.scenes(document: doc, events: log(), transcript: nil)
        // First scene (0–~11.4 s) has a 7 s idle stretch after typing; narrate it longer than it is, and the second shorter.
        let clips = [VoiceoverClip(start: scenes[0].start, path: "media/voiceover/a.mp3", text: "a", duration: 16, scene: scenes[0].id),
                     VoiceoverClip(start: scenes[1].start, path: "media/voiceover/b.mp3", text: "b", duration: 2, scene: scenes[1].id)]
        let r = NarrationFit.plan(document: doc, events: log(), scenes: scenes, clips: clips)
        let after = try OperationApplier.apply(r.operations, to: doc)
        let map = TimeMap(document: after)
        let s0 = map.outputSpan(forSource: scenes[0].range)!.duration
        let s1 = map.outputSpan(forSource: scenes[1].range)!.duration
        #expect(s0 >= 16.4 && s0 < 17.5, "scene 0 stretched to its 16 s line (+tail): \(s0)")
        #expect(s1 < scenes[1].duration, "scene 1 compressed: \(s1) < \(scenes[1].duration)")
        #expect(after.timeline.speeds.allSatisfy { $0.reason?.hasPrefix(NarrationFit.tag) == true })
        // Slowing happens on idle stretches, not over the typing.
        #expect(!after.timeline.speeds.contains { $0.rate < 1 && $0.range.contains(4.5) })
        // Re-planning on a fitted document is a no-op; with a changed line it replaces the earlier fit instead of stacking.
        let again = NarrationFit.plan(document: after, events: log(), scenes: scenes, clips: clips)
        #expect(again.operations.isEmpty)
        var longer = clips; longer[0].duration = 18
        let replan = NarrationFit.plan(document: after, events: log(), scenes: scenes, clips: longer)
        #expect(replan.operations.filter { $0.op == .removeSpeed }.count == after.timeline.speeds.count)
        let twice = try OperationApplier.apply(replan.operations, to: after)
        #expect(twice.timeline.speeds.count == after.timeline.speeds.count)
        #expect(TimeMap(document: twice).outputSpan(forSource: scenes[0].range)!.duration > s0 + 1)
    }

    @Test func captionsFromClipWordsFollowSpeedChanges() {
        var doc = makeDoc()
        doc.timeline.speeds = [SpeedSegment(start: 0, end: 10, rate: 0.5)]   // first 10 s play at half speed → 20 s output
        let clip = VoiceoverClip(start: 0, path: "x.mp3", text: "hello world", duration: 4,
                                 words: [CaptionWord(text: "hello", start: 0, end: 1), CaptionWord(text: "world", start: 1, end: 4)])
        let caps = NarrationFit.captions(document: doc, clips: [clip], maxChars: 40)
        #expect(caps.count == 1)
        #expect(caps[0].text == "hello world")
        // 4 s of output under a 0.5× speed is 2 s of source.
        #expect(abs(caps[0].end - 2) < 0.02)
        #expect(abs(caps[0].words[1].start - 0.5) < 0.02)
    }

    @Test func optionalStylePathsCanBeSet() throws {
        var doc = makeDoc()
        doc = try OperationApplier.apply([.style("voice.voiceID", .string("abc")), .style("voice.voiceName", .string("Bella"))], to: doc)
        #expect(doc.style.voice.voiceID == "abc" && doc.style.voice.voiceName == "Bella")
        doc = try OperationApplier.apply([.style("voice.voiceID", .null)], to: doc)
        #expect(doc.style.voice.voiceID == nil)
        #expect(throws: EditError.self) { _ = try OperationApplier.apply([.style("voice.nope", .string("x"))], to: doc) }
    }

    @Test func voiceoverOperations() throws {
        var doc = makeDoc()
        let clip = VoiceoverClip(id: "vo1", start: 2, path: "media/voiceover/vo1.mp3", text: "hi", duration: 3)
        doc = try OperationApplier.apply([.addVoiceover(clip)], to: doc)
        #expect(doc.timeline.voiceover.count == 1)
        #expect(throws: EditError.self) { _ = try OperationApplier.apply([.addVoiceover(clip)], to: doc) }                                   // duplicate id
        #expect(throws: EditError.self) { _ = try OperationApplier.apply([EditOperation(.updateVoiceover, id: "vo1", gain: 5)], to: doc) }   // gain range
        var late = clip; late.id = "vo2"; late.start = 99
        #expect(throws: EditError.self) { _ = try OperationApplier.apply([.addVoiceover(late)], to: doc) }                                   // outside recording
        doc = try OperationApplier.apply([EditOperation(.updateVoiceover, id: "vo1", start: 5, gain: 0.5)], to: doc)
        #expect(doc.timeline.voiceover[0].start == 5 && doc.timeline.voiceover[0].gain == 0.5)
        // Undo through the engine restores the clip exactly.
        let b = try tempBundle(makeDoc())
        let e = Engine(bundle: b)
        try e.apply([.addVoiceover(clip)], label: "vo", author: .app)
        try e.apply([EditOperation(.removeVoiceover, id: "vo1")], author: .app)
        #expect(try b.readDocument().timeline.voiceover.isEmpty)
        try e.undo(author: .app)
        #expect(try b.readDocument().timeline.voiceover == [clip])
        // Voiceover counts as speech for the dead-air check.
        var quiet = makeDoc(duration: 12)
        var ev = EventLog(); for i in 0..<120 { ev.pointer.append(PointerSample(t: Double(i) * 0.1, x: 0.5, y: 0.5)) }
        let silent = EditQuality.report(document: quiet, events: ev, transcript: nil)
        #expect(silent.checks.first { $0.id == "dead_air" }?.verdict != .pass)
        quiet.timeline.voiceover = [VoiceoverClip(start: 0, path: "v.mp3", text: "narration", duration: 11.5)]
        let narrated = EditQuality.report(document: quiet, events: ev, transcript: nil)
        #expect(narrated.checks.first { $0.id == "dead_air" }?.verdict == .pass)
    }
}
