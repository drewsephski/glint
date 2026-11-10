import Foundation
import Testing
@testable import GlintCore

@Suite struct MediaSafetyTests {
    @Test func recordingPrerollDoesNotDiscardTheCursorPath() {
        var log = EventLog()
        log.pointer = [PointerSample(t: 0.1, x: 0.1, y: 0.5), PointerSample(t: 0.3, x: 0.3, y: 0.5), PointerSample(t: 1, x: 0.8, y: 0.5)]
        let recorded = log.rebased(start: 100, origin: 100.2, pauses: PauseTimeline())
        #expect(recorded.pointer[0].t < 0)
        var style = CursorStyle(); style.smoothing = 0; style.hideAfterIdle = 0
        let cursor = CursorPath(log: recorded, duration: 2, style: style)
        #expect(!cursor.isEmpty)
        #expect(abs(cursor.position(at: 0).x - 0.2) < 0.001)
        #expect(cursor.opacity(at: 1) == 1)
        for invalid in [-1.0, Double.nan, Double.infinity, 1e308] {
            var bad = recorded; bad.pointer[0].t = invalid
            #expect(CursorPath(log: bad, duration: 2, style: style).isEmpty)
        }
    }

    private func document() -> ProjectDocument {
        ProjectDocument(name: "Safety", media: MediaInfo(screen: "screen.mov", width: 1280, height: 800, scale: 2, duration: 2, frameRate: 30))
    }

    @Test func malformedAndExcessiveClipDurationsAreRejected() throws {
        for end in [1e308, Double.infinity, Double.nan, TimelineLimits.maximumDuration + 1] {
            let clip = MediaClip(name: "Bad", path: "screen.mov", mediaEnd: end, width: 1280, height: 800)
            #expect(throws: EditError.self) {
                try OperationApplier.apply([EditOperation(.insertClip, shot: clip)], to: document())
            }
        }
        let clip = MediaClip(name: "Too long together", path: "screen.mov", mediaEnd: TimelineLimits.maximumDuration, width: 1280, height: 800)
        #expect(throws: EditError.self) {
            try OperationApplier.apply([EditOperation(.insertClip, shot: clip)], to: document())
        }
        var slow = document()
        slow.media.duration = TimelineLimits.maximumDuration
        slow.timeline.speeds = [SpeedSegment(start: 0, end: slow.media.duration, rate: 0.1)]
        #expect(throws: EditError.self) { try OperationApplier.validate(slow) }
    }

    @Test func pathsRemainSafeForUnvalidatedDurationsAndQueries() {
        var doc = document()
        doc.media.duration = 1e308
        var events = EventLog()
        events.pointer = [PointerSample(t: 0, x: 0.5, y: 0.5)]
        let cursor = CursorPath(log: events, duration: doc.duration, style: doc.style.cursor)
        #expect(cursor.isEmpty)
        let camera = CameraPath(document: doc, map: TimeMap(document: doc), cursor: cursor,
                                layout: CanvasLayout(document: doc, outputWidth: 640, outputHeight: 400))
        #expect(camera.samples.count == 1)
        #expect(camera.state(at: 1e308) == .identity)
        #expect(camera.state(at: .infinity) == .identity)
    }

    @Test func fixedAndCursorFocusUseTheCurrentShotsAspectRatio() throws {
        let portrait = MediaClip(name: "Portrait", path: "portrait.mov", mediaEnd: 8, events: "portrait-events.json", width: 400, height: 1000, fileDuration: 8)
        var doc = try OperationApplier.apply([EditOperation(.insertClip, shot: portrait)], to: document())
        let layout = CanvasLayout(document: doc, outputWidth: 1920, outputHeight: 1080)
        let expected = CanvasLayout.point(NormPoint(0.9, 0.5), in: layout.fitted(pixelWidth: 400, pixelHeight: 1000))
        for focus in [ZoomSegment.Focus.point(NormPoint(0.9, 0.5)), .followCursor] {
            doc.timeline.zooms = [ZoomSegment(start: 2, end: 10, scale: 3, focus: focus)]
            var events = EventLog()
            events.pointer = [PointerSample(t: 0, x: 0.9, y: 0.5), PointerSample(t: 10, x: 0.9, y: 0.5)]
            let cursor = CursorPath(log: events, duration: doc.duration, style: doc.style.cursor)
            let camera = CameraPath(document: doc, map: TimeMap(document: doc), cursor: cursor, layout: layout)
            let state = camera.state(at: 6)
            #expect(abs(state.cx - expected.x) < 0.001)
            #expect(abs(state.cy - expected.y) < 0.001)
            #expect(abs((expected.x - state.cx) * state.scale + 0.5 - 0.5) < 0.005)
        }
    }
}
