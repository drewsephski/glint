import Foundation
import Testing
@testable import GlintCore

@Suite struct PauseTimelineTests {
    @Test func pauseResumeShiftsLaterSamplesAndDropsPausedOnes() {
        var tl = PauseTimeline()
        let first = tl.pause(at: 102)
        let again = tl.pause(at: 103)                 // already paused
        #expect(first && !again)
        #expect(tl.isPaused)
        #expect(tl.contains(102) && tl.contains(1_000))   // open pause: everything after its start is dropped
        let resumed = tl.resume(at: 105)
        let resumedAgain = tl.resume(at: 106)         // not paused
        #expect(resumed && !resumedAgain)
        let second = tl.pause(at: 110), secondEnd = tl.resume(at: 111)
        let early = tl.pause(at: 109)                 // can't pause before the last resume
        #expect(second && secondEnd && !early)

        #expect(!tl.contains(101.9) && tl.contains(102) && tl.contains(104.99) && !tl.contains(105))
        #expect(tl.offset(at: 101) == 0)
        #expect(tl.offset(at: 105) == 3)            // the first pause is fully behind a sample at its end
        #expect(tl.offset(at: 110.5) == 3)          // inside the second pause: only the first counts (sample is dropped anyway)
        #expect(tl.offset(at: 112) == 4)
        // Gapless time: 100 → 100, 104 (paused) → the cut at 102, 106 → 103, 112 → 108.
        #expect(tl.collapse(100) == 100)
        #expect(tl.collapse(104) == 102)
        #expect(tl.collapse(106) == 103)
        #expect(tl.collapse(112) == 108)
        // As the finished take shows them, from a first frame at host 100.
        #expect(tl.records(origin: 100) == [PauseRecord(at: 2, duration: 3), PauseRecord(at: 7, duration: 1)])
        #expect(tl.totalPaused(now: 200) == 4)
    }

    @Test func openPauseCountsUpToNowAndHasNoDuration() {
        var tl = PauseTimeline()
        tl.pause(at: 10)
        #expect(tl.pausedDuration(before: 14) == 4)
        #expect(tl.collapse(14) == 10)
        #expect(tl.records(origin: 5) == [PauseRecord(at: 5, duration: nil)])
    }

    @Test func rebasedLogDropsPausedInputAndCollapsesTime() {
        // Tracker started at host 50; first frame at host 50.5; paused from host 52.5 to 55.5 (3 s).
        var tl = PauseTimeline()
        tl.pause(at: 52.5); tl.resume(at: 55.5)
        var log = EventLog()
        log.pointer = [PointerSample(t: 1, x: 0.1, y: 0.1), PointerSample(t: 3, x: 0.2, y: 0.2), PointerSample(t: 4, x: 0.3, y: 0.3), PointerSample(t: 6, x: 0.4, y: 0.4)]
        log.clicks = [ClickEvent(t: 1.5, x: 0.1, y: 0.1, up: 1.6), ClickEvent(t: 3.5, x: 0.2, y: 0.2), ClickEvent(t: 7, x: 0.5, y: 0.5, up: 7.1)]
        log.keys = [KeyEvent(t: 2), KeyEvent(t: 4.5), KeyEvent(t: 8)]
        log.scrolls = [ScrollEvent(t: 3.2, x: 0, y: 0)]
        log.apps = [AppFocusEvent(t: 0, bundleID: "a", name: "A"), AppFocusEvent(t: 4, bundleID: "b", name: "B")]
        log.markers = [Marker(time: 3, note: "while paused", author: .app)]
        log.windowFrames = [WindowFrameSample(t: 0, x: 0, y: 0, width: 100, height: 100), WindowFrameSample(t: 5, x: 40, y: 0, width: 100, height: 100)]
        let r = log.rebased(start: 50, origin: 50.5, pauses: tl)
        // Host = 50 + t; gapless = host − paused before; minus origin 50.5.
        #expect(r.pointer.map(\.t) == [0.5, 2, 2.5])     // t=3 dropped, t=4 (last in pause) at the cut (2.0), t=6 → 56−3−50.5
        #expect(r.pointer[1].x == 0.3)
        #expect(r.clicks.map(\.t) == [1, 3.5])           // the click while paused is gone
        #expect(abs((r.clicks[0].up ?? 0) - 1.1) < 1e-9)
        #expect(r.keys.map(\.t) == [1.5, 4.5])
        #expect(r.scrolls.isEmpty)
        #expect(r.apps.map(\.t) == [0, 2])               // the switch made while paused shows at the cut
        #expect(r.markers.map(\.time) == [2])
        #expect(r.windowFrames?.map(\.t) == [0, 2])
        #expect(r.pauses == [PauseRecord(at: 2, duration: 3)])
    }

    @Test func rebasedWithoutPausesMatchesThePlainShift() {
        var log = EventLog()
        log.pointer = [PointerSample(t: 0.1, x: 0, y: 0), PointerSample(t: 1, x: 0.5, y: 0.5)]
        log.clicks = [ClickEvent(t: 0.2, x: 0, y: 0), ClickEvent(t: 2, x: 0, y: 0)]
        log.apps = [AppFocusEvent(t: 0, bundleID: nil, name: "A")]
        let r = log.rebased(start: 10, origin: 10.4, pauses: PauseTimeline())
        #expect(r.pointer.map(\.t).map { ($0 * 1000).rounded() / 1000 } == [-0.3, 0.6])   // kept: within the 0.5 s lead-in
        #expect(r.clicks.map(\.t).map { ($0 * 1000).rounded() / 1000 } == [1.6])          // before the first frame: dropped
        #expect(r.apps.map(\.t) == [0])
        #expect(r.pauses == nil)
    }

    @Test func clippedKeepsWhatAPartialMovieShows() {
        var log = EventLog()
        log.pointer = [PointerSample(t: 1, x: 0, y: 0), PointerSample(t: 9, x: 0, y: 0)]
        log.clicks = [ClickEvent(t: 3.9, x: 0, y: 0, up: 4.3), ClickEvent(t: 6, x: 0, y: 0)]
        log.keys = [KeyEvent(t: 1), KeyEvent(t: 5)]
        log.markers = [Marker(time: 2, note: "a", author: .app), Marker(time: 7, note: "b", author: .app)]
        log.pauses = [PauseRecord(at: 2, duration: 1), PauseRecord(at: 8, duration: 1)]
        let c = log.clipped(to: 4)
        #expect(c.pointer.count == 1 && c.clicks.count == 1 && c.clicks[0].up == 4 && c.keys.count == 1 && c.markers.count == 1)
        #expect(c.pauses == [PauseRecord(at: 2, duration: 1)])
    }
}

@Suite struct WindowTrackingTests {
    @Test func pointsNormalizeAgainstTheWindowFrameAtThatInstant() {
        let initial: [Double] = [100, 200, 800, 600]
        let frames = [WindowFrameSample(t: 0, frame: initial), WindowFrameSample(t: 2, x: 300, y: 200, width: 800, height: 600),
                      WindowFrameSample(t: 5, x: 300, y: 260, width: 400, height: 300)]
        // The same global point lands in different places as the window moves.
        let before = CaptureGeometry.normalize(x: 500, y: 500, at: 1, samples: frames, initial: initial)
        #expect(before.x == 0.5 && before.y == 0.5)
        let moved = CaptureGeometry.normalize(x: 500, y: 500, at: 3, samples: frames, initial: initial)
        #expect(moved.x == 0.25 && moved.y == 0.5)
        // The pointer followed the window (dragging its title bar): same normalized spot.
        let followed = CaptureGeometry.normalize(x: 700, y: 500, at: 2, samples: frames, initial: initial)
        #expect(followed.x == 0.5 && followed.y == 0.5)
        let resized = CaptureGeometry.normalize(x: 500, y: 410, at: 9, samples: frames, initial: initial)
        #expect(resized.x == 0.5 && resized.y == 0.5)
        #expect(CaptureGeometry.frame(at: -1, samples: frames, initial: initial) == initial)
        #expect(CaptureGeometry.frame(at: 4.99, samples: frames, initial: initial) == [300, 200, 800, 600])
        #expect(!frames[0].differs(from: WindowFrameSample(t: 1, x: 100.2, y: 200, width: 800, height: 600)))
        #expect(frames[0].differs(from: frames[1]))
    }

    @Test func eventLogsWithoutTheNewFieldsStillDecode() throws {
        let old = #"{"formatVersion":1,"pointer":[{"t":0.5,"x":0.1,"y":0.2}],"clicks":[],"keys":[],"scrolls":[],"apps":[],"cursorChanges":[],"cursors":[],"markers":[]}"#
        let log = try JSONCoding.decoder.decode(EventLog.self, from: Data(old.utf8))
        #expect(log.pointer.count == 1 && log.windowFrames == nil && log.pauses == nil)
        var withNew = log
        withNew.windowFrames = [WindowFrameSample(t: 0, x: 1, y: 2, width: 3, height: 4)]
        withNew.pauses = [PauseRecord(at: 1, duration: 2)]
        let back = try JSONCoding.decoder.decode(EventLog.self, from: JSONCoding.compactEncoder.encode(withNew))
        #expect(back == withNew)
    }
}

@Suite struct RecoveryJournalTests {
    @Test func journalRoundTripsAndKnowsWhatIsRecoverable() throws {
        let b = try tempBundle()
        defer { try? FileManager.default.removeItem(at: b.url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)     // whole seconds: the journal stores ISO 8601
        let info = RecordingInfo(startedAt: now, source: "display:1", sourceName: "Display", displayFrame: [0, 0, 100, 100], recordedBy: .app, inputTracking: "poll")
        var j = RecordingJournal(pid: 42, processStartedAt: 1000, processName: "Glint", startedAt: now,
                                 media: MediaInfo(screen: "media/screen.mov", width: 100, height: 100, scale: 2, duration: 0, frameRate: 60), recording: info, options: .object(["frameRate": .number(60)]))
        j.pauses = [PauseRecord(at: 3, duration: 1.5)]
        j.warnings = ["camera disconnected"]
        try j.write(b)
        let read = try #require(RecordingJournal.read(b))
        #expect(read == j)
        #expect(read.isRecoverable(ownerAlive: false))
        #expect(!read.isRecoverable(ownerAlive: true))     // still recording in a live process
        var done = read; done.status = .finalized
        #expect(!done.isRecoverable(ownerAlive: false) && !done.isUnfinished)
        var broke = read; broke.status = .interrupted
        #expect(broke.isRecoverable(ownerAlive: true))     // finalizing failed: recoverable even though its process lives on
        #expect(RecordingJournal.read(ProjectBundle(url: b.url.appendingPathComponent("nope"))) == nil)
    }
}

@Suite struct PreflightMathTests {
    @Test func diskVerdicts() {
        let bps = PreflightMath.bytesPerSecond(videoBitsPerSecond: 16_000_000, audioBitsPerSecond: [192_000, 128_000])
        #expect(abs(bps - 16_320_000 / 8 * 1.1) < 1)
        let gb = 1_000_000_000.0
        // A 10-minute take needs ~1.35 GB.
        #expect(PreflightMath.diskCheck(freeBytes: 100 * gb, bytesPerSecond: bps, maxDuration: 600, volume: "Mac").verdict == .pass)
        #expect(PreflightMath.diskCheck(freeBytes: 2.5 * gb, bytesPerSecond: bps, maxDuration: 600, volume: "Mac").verdict == .warn)
        let fail = PreflightMath.diskCheck(freeBytes: 1.5 * gb, bytesPerSecond: bps, maxDuration: 600, volume: "Mac")
        #expect(fail.verdict == .fail && fail.fix != nil)
        // Open-ended takes: per-minute room.
        #expect(PreflightMath.diskCheck(freeBytes: 0.6 * gb, bytesPerSecond: bps, maxDuration: nil, volume: "Mac").verdict == .fail)
        #expect(PreflightMath.diskCheck(freeBytes: 1.5 * gb, bytesPerSecond: bps, maxDuration: nil, volume: "Mac").verdict == .warn)
        #expect(PreflightMath.diskCheck(freeBytes: 50 * gb, bytesPerSecond: bps, maxDuration: nil, volume: "Mac").verdict == .pass)
        let report = PreflightReport(checks: [PreflightCheck(id: "a", title: "A", verdict: .pass, detail: ""), PreflightCheck(id: "b", title: "B", verdict: .warn, detail: "")],
                                     estimatedBytesPerMinute: bps * 60, estimatedBytes: nil, freeBytes: nil)
        #expect(report.ok && report.warnings.count == 1 && report.failures.isEmpty)
        #expect(!PreflightReport(checks: [PreflightCheck(id: "x", title: "X", verdict: .fail, detail: "")], estimatedBytesPerMinute: 0, estimatedBytes: nil, freeBytes: nil).ok)
    }
}
