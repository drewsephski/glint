import Foundation
import Testing

@testable import GlintCore

@Suite struct RecordedContentGeometryTests {
    private func document() -> ProjectDocument {
        ProjectDocument(
            name: "Resized window",
            media: MediaInfo(screen: "media/screen.mov", width: 960, height: 1048, scale: 1, duration: 30, frameRate: 60))
    }

    @Test func legacyWindowResizeRemovesOnlyCapturePadding() throws {
        let doc = document()
        var events = EventLog()
        events.windowFrames = [
            WindowFrameSample(t: 0, x: 2879, y: -82, width: 961, height: 1049),
            WindowFrameSample(t: 16, x: 1920, y: -83, width: 1920, height: 1049),
            WindowFrameSample(t: 20, x: 1920, y: 0, width: 480, height: 1049),
        ]
        let geometry = RecordedContentGeometry(document: doc, logs: ["events.json": events])
        #expect(geometry.crop(at: 1) == NormRect(x: 0, y: 0, width: 1, height: 1))
        let wide = try #require(geometry.crop(at: 17))
        #expect(wide.width == 1)
        #expect(abs(wide.height * 1048 - 524.5) < 0.01)
        let tall = try #require(geometry.crop(at: 22))
        #expect(tall.width < 0.51 && tall.height == 1)
        #expect(RecordedContentGeometry(document: doc, logs: [:]).crop(at: 17) == nil)
    }

    @Test func exactBoundsFollowFileTimeAcrossTrimReorderAndRepeat() throws {
        var doc = document()
        let full = NormRect(x: 0, y: 0, width: 1, height: 1)
        let inset = NormRect(x: 0.1, y: 0.05, width: 0.8, height: 0.5)
        var log = EventLog()
        log.captureContent = [CaptureContentSample(t: 0, rect: full), CaptureContentSample(t: 16, rect: inset)]
        var late = doc.primaryClip
        late.id = "late"
        late.mediaStart = 20
        late.mediaEnd = 25
        var early = doc.primaryClip
        early.id = "early"
        early.mediaEnd = 5
        var repeated = late
        repeated.id = "repeat"
        let imported = MediaClip(name: "Imported", path: "other.mov", mediaEnd: 5, width: 960, height: 1048)
        doc.timeline.clips = [late, early, imported, repeated]
        let geometry = RecordedContentGeometry(document: doc, logs: ["events.json": log])
        #expect(geometry.crop(at: 1) == inset)
        #expect(geometry.crop(at: 6) == full)
        #expect(geometry.crop(at: 11) == nil)
        #expect(geometry.crop(at: 16) == inset)
        let roundTrip = try JSONCoding.decoder.decode(EventLog.self, from: JSONCoding.compactEncoder.encode(log))
        #expect(roundTrip.captureContent == log.captureContent)
        #expect(log.clipped(to: 10).captureContent?.count == 1)
        log.captureContent = [CaptureContentSample(t: 0, rect: NormRect(x: 0, y: 0, width: .nan, height: 1))]
        #expect(RecordedContentGeometry(document: doc, logs: ["events.json": log]).crop(at: 1) == nil)
    }
}
