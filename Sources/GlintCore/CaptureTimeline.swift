import Foundation

// Pure models for capture reliability: pausing within a take, tracking a moving window, the crash-recovery journal
// and preflight checks. Capture (GlintCapture) and the service (GlintAgent) build on these; nothing here touches
// media, so the time maths is unit-tested directly.

// MARK: - Pause/resume

/// A pause inside a finished take, as the recording shows it. The paused stretch is not in the files: the take simply
/// continues at `at`, which is where a viewer sees the cut. `duration` is how long the take was paused (wall clock).
public struct PauseRecord: Codable, Hashable, Sendable {
    /// Seconds from the take's first frame (gapless recording time) where the pause sits.
    public var at: Double
    /// Seconds the take was paused for; nil while still paused.
    public var duration: Double?
    public init(at: Double, duration: Double?) { self.at = at; self.duration = duration }
}

/// Pause/resume bookkeeping on the host clock (the clock every capture sample is stamped with).
///
/// Samples stamped inside a pause are dropped; everything after a pause moves earlier by the time spent paused, so the
/// screen, audio, camera and input tracks stay aligned and the files have no gap.
public struct PauseTimeline: Codable, Hashable, Sendable {
    public struct Interval: Codable, Hashable, Sendable {
        /// Host seconds the pause began.
        public var start: Double
        /// Host seconds it ended; nil while paused.
        public var end: Double?
        public init(start: Double, end: Double?) { self.start = start; self.end = end }
        public func contains(_ t: Double) -> Bool { t >= start && (end.map { t < $0 } ?? true) }
    }

    public private(set) var intervals: [Interval] = []
    public init() {}

    public var isPaused: Bool { intervals.last.map { $0.end == nil } ?? false }

    /// Starts a pause at `host`. False if already paused, or if `host` is earlier than the last resume.
    @discardableResult
    public mutating func pause(at host: Double) -> Bool {
        guard !isPaused else { return false }
        if let last = intervals.last?.end, host < last { return false }
        intervals.append(Interval(start: host, end: nil))
        return true
    }

    /// Ends the current pause at `host`. False if not paused.
    @discardableResult
    public mutating func resume(at host: Double) -> Bool {
        guard isPaused, let i = intervals.indices.last else { return false }
        intervals[i].end = max(intervals[i].start, host)
        return true
    }

    /// Whether a sample stamped `host` falls inside a pause (and is dropped).
    public func contains(_ host: Double) -> Bool { intervals.contains { $0.contains(host) } }

    /// Seconds spent paused before `host`. An instant inside a pause counts that pause up to the instant.
    public func pausedDuration(before host: Double) -> Double {
        var total = 0.0
        for iv in intervals {
            guard host > iv.start else { break }
            total += min(host, iv.end ?? host) - iv.start
        }
        return total
    }

    /// Seconds spent paused in closed pauses that ended at or before `host`: the shift applied to a sample at `host`.
    public func offset(at host: Double) -> Double {
        var total = 0.0
        for iv in intervals {
            guard let e = iv.end, e <= host else { break }
            total += e - iv.start
        }
        return total
    }

    /// Gapless time for a host instant: the instant minus everything paused before it. An instant inside a pause maps
    /// to the cut (where that pause sits in the finished take).
    public func collapse(_ host: Double) -> Double { host - pausedDuration(before: host) }

    /// Index of the pause containing `host`, if any.
    public func pauseIndex(containing host: Double) -> Int? { intervals.firstIndex { $0.contains(host) } }

    /// The pauses as the finished take shows them, measured from `origin` (the gapless host time of the first frame).
    public func records(origin: Double) -> [PauseRecord] {
        intervals.map { iv in
            PauseRecord(at: max(0, collapse(iv.start) - origin), duration: iv.end.map { $0 - iv.start })
        }
    }

    /// Total seconds paused so far (an open pause counts up to `now`).
    public func totalPaused(now: Double) -> Double { pausedDuration(before: now) }
}

// MARK: - Window frames

/// Where a recorded window was on screen at time `t` (global points, top-left origin). Window recordings follow the
/// window, so pointer positions are normalized against the frame at that instant.
public struct WindowFrameSample: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(t: Double, x: Double, y: Double, width: Double, height: Double) {
        self.t = t; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(t: Double, frame: [Double]) {
        self.init(t: t, x: frame.count > 0 ? frame[0] : 0, y: frame.count > 1 ? frame[1] : 0,
                  width: frame.count > 2 ? frame[2] : 1, height: frame.count > 3 ? frame[3] : 1)
    }
    public var frame: [Double] { [x, y, width, height] }

    /// True when `other` differs by more than `tolerance` points in position or size.
    public func differs(from other: WindowFrameSample, tolerance: Double = 0.5) -> Bool {
        abs(x - other.x) > tolerance || abs(y - other.y) > tolerance || abs(width - other.width) > tolerance || abs(height - other.height) > tolerance
    }
}

public enum CaptureGeometry {
    /// A global point (points, top-left origin) in the 0–1 space of `frame` ([x, y, w, h], same coordinates).
    public static func normalize(x: Double, y: Double, in frame: [Double]) -> (x: Double, y: Double) {
        guard frame.count >= 4 else { return (x, y) }
        return ((x - frame[0]) / max(1, frame[2]), (y - frame[1]) / max(1, frame[3]))
    }

    /// The window frame in effect at `t`: the latest sample at or before `t` (frames change in steps), else the
    /// first one, else `initial`.
    public static func frame(at t: Double, samples: [WindowFrameSample], initial: [Double]) -> [Double] {
        guard let first = samples.first else { return initial }
        if t < first.t { return initial }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo].frame
    }

    /// Normalize a global point at time `t` against the window frame in effect then.
    public static func normalize(x: Double, y: Double, at t: Double, samples: [WindowFrameSample], initial: [Double]) -> (x: Double, y: Double) {
        normalize(x: x, y: y, in: frame(at: t, samples: samples, initial: initial))
    }
}

// MARK: - Rebasing a captured event log

extension EventLog {
    /// Rebases a log whose times are seconds since `start` (host clock) onto the finished take: drops pointer, click,
    /// key and scroll input made while paused, moves state changes made during a pause (app focus, cursor image,
    /// window frame, markers) to the cut, collapses the paused time, and measures from `origin`, the gapless host time
    /// of the first video frame. The last pointer position of each pause is kept at the cut so the cursor resumes
    /// where it really is.
    public func rebased(start: Double, origin: Double, pauses: PauseTimeline) -> EventLog {
        func host(_ t: Double) -> Double { start + t }
        func map(_ t: Double) -> Double { pauses.collapse(host(t)) - origin }
        func paused(_ t: Double) -> Bool { pauses.contains(host(t)) }
        var l = self
        // Pointer: drop samples inside pauses except each pause's last one, which lands on the cut.
        var lastInPause: [Int: PointerSample] = [:]
        var pointer: [PointerSample] = []
        for p in self.pointer {
            if let i = pauses.pauseIndex(containing: host(p.t)) { lastInPause[i] = PointerSample(t: map(p.t), x: p.x, y: p.y); continue }
            pointer.append(PointerSample(t: map(p.t), x: p.x, y: p.y))
        }
        pointer += lastInPause.values
        l.pointer = pointer.filter { $0.t >= -0.5 }.sorted { $0.t < $1.t }
        l.clicks = clicks.filter { !paused($0.t) }.map { var c = $0; c.t = map(c.t); c.up = c.up.map(map); return c }.filter { $0.t >= 0 }
        l.keys = keys.filter { !paused($0.t) }.map { var k = $0; k.t = map(k.t); return k }.filter { $0.t >= 0 }
        l.scrolls = scrolls.filter { !paused($0.t) }.map { var k = $0; k.t = map(k.t); return k }.filter { $0.t >= 0 }
        l.apps = apps.map { var k = $0; k.t = max(0, map(k.t)); return k }
        l.cursorChanges = cursorChanges.map { var k = $0; k.t = max(0, map(k.t)); return k }
        l.markers = markers.map { var k = $0; k.time = max(0, map(k.time)); return k }
        if let w = windowFrames { l.windowFrames = w.map { var k = $0; k.t = max(0, map(k.t)); return k } }
        let records = pauses.records(origin: origin)
        l.pauses = records.isEmpty ? nil : records
        return l
    }

    /// Only what happened within the first `duration` seconds: what a partial movie can still show.
    public func clipped(to duration: Double) -> EventLog {
        var l = self
        l.pointer = pointer.filter { $0.t <= duration }
        l.clicks = clicks.filter { $0.t <= duration }.map { var c = $0; if let u = c.up, u > duration { c.up = duration }; return c }
        l.keys = keys.filter { $0.t <= duration }
        l.scrolls = scrolls.filter { $0.t <= duration }
        l.apps = apps.filter { $0.t <= duration }
        l.cursorChanges = cursorChanges.filter { $0.t <= duration }
        l.markers = markers.filter { $0.time <= duration }
        l.windowFrames = windowFrames?.filter { $0.t <= duration }
        l.pauses = pauses?.filter { $0.at <= duration }
        return l
    }
}

// MARK: - Recovery journal

/// `recording.json` in a project bundle: written when a take starts and updated every couple of seconds, so a take
/// interrupted by a crash, a forced quit or a power cut can be found and recovered. On a normal stop it is marked
/// `finalized` and kept as the take's capture record (pauses, warnings).
public struct RecordingJournal: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The take is being recorded (or its process died: see `RecordingJournal.ownerIsAlive`).
        case recording
        /// Stopped normally; project.json and events.json are complete.
        case finalized
        /// Finalizing failed (or capture broke); the partial media is on disk and can be recovered.
        case interrupted
        /// Rebuilt from the partial media by recovery.
        case recovered
    }
    public static let fileName = "recording.json"
    /// Input events captured so far, rewritten atomically every checkpoint.
    public static let eventsCheckpointName = "events.checkpoint.json"
    public static let formatVersion = 1
    /// How often media fragments and event checkpoints are written: the most a crash can lose.
    public static let checkpointInterval = 2.0

    public var formatVersion = RecordingJournal.formatVersion
    public var status: Status
    /// The process recording the take; with `processStartedAt` it tells a live owner from a reused PID.
    public var pid: Int32
    public var processStartedAt: Double?
    public var processName: String
    public var startedAt: Date
    public var updatedAt: Date
    /// The planned media (paths, size, frame rate); duration is filled in from the files on recovery.
    public var media: MediaInfo
    public var recording: RecordingInfo
    /// The options the take was started with (as the capture layer encodes them).
    public var options: JSONValue?
    public var paused: Bool = false
    public var pauses: [PauseRecord] = []
    /// Recording seconds (paused time excluded) at the last checkpoint.
    public var elapsed: Double = 0
    public var warnings: [String] = []
    public var error: String?
    /// What recovery found and what was lost.
    public var notes: [String]?
    public var finishedAt: Date?

    public init(status: Status = .recording, pid: Int32, processStartedAt: Double?, processName: String, startedAt: Date,
                media: MediaInfo, recording: RecordingInfo, options: JSONValue?) {
        self.status = status; self.pid = pid; self.processStartedAt = processStartedAt; self.processName = processName
        self.startedAt = startedAt; self.updatedAt = startedAt; self.media = media; self.recording = recording; self.options = options
    }

    public static func url(in bundle: ProjectBundle) -> URL { bundle.url.appendingPathComponent(fileName) }
    public static func checkpointURL(in bundle: ProjectBundle) -> URL { bundle.url.appendingPathComponent(eventsCheckpointName) }

    public static func read(_ bundle: ProjectBundle) -> RecordingJournal? {
        guard let d = try? Data(contentsOf: url(in: bundle)) else { return nil }
        return try? JSONCoding.decoder.decode(RecordingJournal.self, from: d)
    }

    public func write(_ bundle: ProjectBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: Self.url(in: bundle), options: .atomic)
    }

    /// Recording or interrupted, i.e. not finished by a normal stop or by recovery.
    public var isUnfinished: Bool { status == .recording || status == .interrupted }

    /// A take is recoverable when it never finished and the process that recorded it is gone (`ownerAlive` false),
    /// or when finalizing it failed.
    public func isRecoverable(ownerAlive: Bool) -> Bool {
        switch status {
        case .interrupted: return true          // the take already ended without finishing
        case .recording: return !ownerAlive
        case .finalized, .recovered: return false
        }
    }
}

// MARK: - Preflight

/// One thing checked before recording, with a plain-language fix when it isn't right.
public struct PreflightCheck: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable { case pass, warn, fail }
    public var id: String
    public var title: String
    public var verdict: Verdict
    public var detail: String
    public var fix: String?
    public init(id: String, title: String, verdict: Verdict, detail: String, fix: String? = nil) {
        self.id = id; self.title = title; self.verdict = verdict; self.detail = detail; self.fix = fix
    }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    /// No check failed: recording can start (warnings are worth reading first).
    public var ok: Bool
    public var checks: [PreflightCheck]
    /// Estimated size of the take: for `max_duration`, or per minute when the take has no limit.
    public var estimatedBytesPerMinute: Double
    public var estimatedBytes: Double?
    public var freeBytes: Double?
    public init(checks: [PreflightCheck], estimatedBytesPerMinute: Double, estimatedBytes: Double?, freeBytes: Double?) {
        self.checks = checks; self.ok = !checks.contains { $0.verdict == .fail }
        self.estimatedBytesPerMinute = estimatedBytesPerMinute; self.estimatedBytes = estimatedBytes; self.freeBytes = freeBytes
    }
    public var failures: [PreflightCheck] { checks.filter { $0.verdict == .fail } }
    public var warnings: [PreflightCheck] { checks.filter { $0.verdict == .warn } }
}

public enum PreflightMath {
    /// Space kept free beyond the take itself (the system and other apps need room too).
    public static let headroomBytes = 500.0 * 1_000_000

    /// Bytes per second of a take: video at its average bitrate plus each audio track, with 10 % container overhead.
    public static func bytesPerSecond(videoBitsPerSecond: Double, audioBitsPerSecond: [Double], cameraBitsPerSecond: Double = 0) -> Double {
        (videoBitsPerSecond + cameraBitsPerSecond + audioBitsPerSecond.reduce(0, +)) / 8 * 1.1
    }

    /// The disk check. With a time limit the whole take must fit; without one, fewer than 2 minutes of room fails and
    /// fewer than 15 minutes warns.
    public static func diskCheck(freeBytes: Double, bytesPerSecond: Double, maxDuration: Double?, volume: String) -> PreflightCheck {
        let usable = max(0, freeBytes - headroomBytes)
        let minutes = bytesPerSecond > 0 ? usable / bytesPerSecond / 60 : .infinity
        let free = formatBytes(freeBytes)
        let rate = formatBytes(bytesPerSecond * 60)
        if let maxDuration, maxDuration > 0 {
            let need = bytesPerSecond * maxDuration
            if need > usable {
                return PreflightCheck(id: "disk", title: "Free disk space", verdict: .fail,
                                      detail: "This take needs about \(formatBytes(need + headroomBytes)) on \(volume) (\(rate) a minute, plus room for the system); \(free) is free.",
                                      fix: "Free up space on \(volume), record to another folder (directory), or record a shorter take.")
            }
            if need * 2 > usable {
                return PreflightCheck(id: "disk", title: "Free disk space", verdict: .warn,
                                      detail: "\(free) free on \(volume); this take needs about \(formatBytes(need)) (\(rate) a minute). That leaves little room.",
                                      fix: "Free up some space on \(volume) to be safe.")
            }
            return PreflightCheck(id: "disk", title: "Free disk space", verdict: .pass, detail: "\(free) free on \(volume); this take needs about \(formatBytes(need)).")
        }
        if minutes < 2 {
            return PreflightCheck(id: "disk", title: "Free disk space", verdict: .fail,
                                  detail: "\(free) free on \(volume): room for less than 2 minutes at \(rate) a minute.",
                                  fix: "Free up space on \(volume) or record to another folder (directory).")
        }
        if minutes < 15 {
            return PreflightCheck(id: "disk", title: "Free disk space", verdict: .warn,
                                  detail: "\(free) free on \(volume): room for about \(Int(minutes)) minutes at \(rate) a minute.",
                                  fix: "Free up space on \(volume), or keep the take short (max_duration).")
        }
        let shown = minutes > 600 ? "more than 10 hours" : "about \(Int(minutes)) minutes"
        return PreflightCheck(id: "disk", title: "Free disk space", verdict: .pass, detail: "\(free) free on \(volume): room for \(shown) at \(rate) a minute.")
    }

    public static func formatBytes(_ b: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(max(0, b.isFinite ? b : 0)))
    }
}
