import Foundation
import Testing
@testable import GlintCore

@Suite struct ClipRemapSafetyTests {
    private func document() -> ProjectDocument {
        ProjectDocument(name: "remap", media: MediaInfo(screen: "media/screen.mov", width: 1280, height: 800, scale: 2, duration: 10, frameRate: 30))
    }
    private var insertion: EditOperation {
        EditOperation(.insertClip, time: 5, shot: MediaClip(name: "insert", path: "media/clips/insert.mov", mediaEnd: 2, width: 1280, height: 800, fileDuration: 2))
    }
    private var rect: NormRect { NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2) }

    @Test func insertionPreservesEverySurvivingIntervalAndItsWords() throws {
        var d = document()
        d.timeline.redactions = [Redaction(id: "private", start: 1, end: 9, rect: rect)]
        d.timeline.annotations = [Annotation(id: "box", kind: .box, start: 1, end: 9, rect: rect)]
        d.timeline.zooms = [ZoomSegment(id: "zoom", start: 1, end: 9)]
        d.timeline.speeds = [SpeedSegment(id: "speed", start: 1, end: 9, rate: 2)]
        d.timeline.captions = [CaptionSegment(id: "caption", start: 1, end: 9, text: "before after", words: [CaptionWord(text: "before", start: 1, end: 5), CaptionWord(text: "after", start: 5, end: 9)])]
        let result = try OperationApplier.apply([insertion], to: d)
        let expected = [TimeRange(1, 5), TimeRange(7, 11)]
        #expect(result.timeline.redactions.map(\.range) == expected)
        #expect(result.timeline.annotations.map(\.range) == expected)
        #expect(result.timeline.zooms.map(\.range) == expected)
        #expect(result.timeline.speeds.map(\.range) == expected)
        #expect(result.timeline.captions.map(\.text) == ["before", "after"])
        #expect(Set(result.timeline.redactions.map(\.id)).count == 2)
        #expect(result.timeline.redactions.first?.id == "private")
        for c in result.timeline.captions {
            #expect(c.words.allSatisfy { $0.start >= c.start && $0.end <= c.end })
        }
    }

    @Test func clipEditsPreserveManuallyRewrittenCaptions() throws {
        var d = document()
        d.timeline.captions = [CaptionSegment(start: 1, end: 3, text: "Edited wording", words: [CaptionWord(text: "original", start: 1, end: 3)])]
        let result = try OperationApplier.apply([insertion], to: d)
        #expect(result.timeline.captions.first?.text == "Edited wording")
    }

    @Test func insertionBoundaryFollowsOriginalContent() throws {
        var d = document()
        d.timeline.markers = [Marker(time: 5, note: "scene:next", author: .app), Marker(time: 10, note: "end", author: .app)]
        let result = try OperationApplier.apply([insertion], to: d)
        #expect(result.timeline.markers.map(\.time) == [7, 12])
    }

    @Test func tinyMaskFragmentsRemainProtected() throws {
        var d = document()
        d.timeline.redactions = [Redaction(start: 4.99, end: 9, rect: rect)]
        let result = try OperationApplier.apply([insertion], to: d)
        #expect(result.timeline.redactions.count == 2)
        #expect(result.timeline.redactions.first?.start == 4.99)
        #expect(result.timeline.redactions.first?.end == 5)
    }

    @Test func partialOverlapDoesNotDiscardUncoveredSource() {
        let original = MediaClip(id: "a", name: "a", path: "a.mov", mediaEnd: 10, width: 1280, height: 800)
        var first = original; first.mediaEnd = 6
        var second = original; second.id = "b"; second.mediaStart = 4
        let remap = ClipRemap(old: ClipLayout(clips: [original]), new: ClipLayout(clips: [first, second]))
        #expect(remap.ranges(TimeRange(0, 10)) == [TimeRange(0, 6), TimeRange(8, 12)])
    }

    @Test func undoRedoPreservesSplitMaskIdentity() throws {
        var d = document()
        d.timeline.redactions = [Redaction(id: "mask", start: 1, end: 9, rect: rect)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID().uuidString).glint")
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try ProjectBundle.create(at: url, document: d, events: EventLog())
        let engine = Engine(bundle: bundle)
        _ = try engine.apply([insertion], author: .app)
        let edited = try bundle.readDocument().timeline.redactions
        try engine.undo(author: .app)
        #expect(try bundle.readDocument().timeline.redactions == d.timeline.redactions)
        try engine.redo(author: .app)
        #expect(try bundle.readDocument().timeline.redactions == edited)
    }
}
