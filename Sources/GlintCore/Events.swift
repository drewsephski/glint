import Foundation

/// Everything captured next to the video: pointer path, clicks, typing activity, scrolls, app focus, cursor
/// images and markers. Stored as `events.json` in the project bundle; all times are seconds from the first
/// video frame, positions normalized to the screen video (top-left origin).
public struct EventLog: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var formatVersion = EventLog.formatVersion
    /// Pointer samples (~120 Hz while moving).
    public var pointer: [PointerSample] = []
    public var clicks: [ClickEvent] = []
    /// Key-down instants. `key` is only filled when the user opted into keystroke capture (needs Input Monitoring);
    /// otherwise only timing is known, which is all the zoom/speed planners need.
    public var keys: [KeyEvent] = []
    public var scrolls: [ScrollEvent] = []
    public var apps: [AppFocusEvent] = []
    /// Cursor appearance changes; `cursorID` refers to `cursors/<id>.png` in the bundle.
    public var cursorChanges: [CursorChange] = []
    public var cursors: [CursorImage] = []
    public var markers: [Marker] = []
    /// Where a recorded window was over time (window recordings only; positions above are already normalized
    /// against the frame at each instant). Absent in files written before window tracking.
    public var windowFrames: [WindowFrameSample]?
    /// Where the take was paused and for how long. The paused time isn't in the files; absent when never paused.
    public var pauses: [PauseRecord]?
    public init() {}

    public var isEmpty: Bool { pointer.isEmpty && clicks.isEmpty && keys.isEmpty }
}

public struct PointerSample: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    public var point: NormPoint { NormPoint(x, y) }
}

public struct ClickEvent: Codable, Hashable, Sendable {
    public enum Button: String, Codable, Sendable { case left, right, other }
    public var t: Double
    public var x: Double
    public var y: Double
    public var button: Button
    /// Release time, if seen.
    public var up: Double?
    /// Accessibility label of the clicked element when available (needs Accessibility permission).
    public var target: String?
    public init(t: Double, x: Double, y: Double, button: Button = .left, up: Double? = nil, target: String? = nil) {
        self.t = t; self.x = x; self.y = y; self.button = button; self.up = up; self.target = target
    }
    public var point: NormPoint { NormPoint(x, y) }
}

public struct KeyEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var key: String?
    public var modifiers: [String]?
    public init(t: Double, key: String? = nil, modifiers: [String]? = nil) { self.t = t; self.key = key; self.modifiers = modifiers }
}

public struct ScrollEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

public struct AppFocusEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var bundleID: String?
    public var name: String
    public init(t: Double, bundleID: String?, name: String) { self.t = t; self.bundleID = bundleID; self.name = name }
}

public struct CursorChange: Codable, Hashable, Sendable {
    public var t: Double
    public var cursorID: String
    public init(t: Double, cursorID: String) { self.t = t; self.cursorID = cursorID }
}

public struct CursorImage: Codable, Hashable, Sendable {
    public var id: String
    /// Size in points and hotspot in points (top-left origin).
    public var width: Double
    public var height: Double
    public var hotX: Double
    public var hotY: Double
    /// Best-effort classification ("arrow", "pointingHand", "iBeam", …) for agents and for vector replacement.
    public var kind: String?
    public init(id: String, width: Double, height: Double, hotX: Double, hotY: Double, kind: String? = nil) {
        self.id = id; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY; self.kind = kind
    }
}

/// Derived, human/agent-readable activity summary of an event log.
public struct ActivitySummary: Codable, Hashable, Sendable {
    public struct Burst: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var count: Int
        public init(start: Double, end: Double, count: Int) { self.start = start; self.end = end; self.count = count }
    }
    public var clicks: [ClickEvent]
    public var typing: [Burst]
    public var scrolling: [Burst]
    public var idle: [TimeRange]
    public var apps: [AppFocusEvent]
    public var markers: [Marker]
    public var pointerTravel: Double
}

public enum Activity {
    /// Group instants into bursts where consecutive gaps are below `gap`.
    public static func bursts(_ times: [Double], gap: Double, minCount: Int = 1) -> [ActivitySummary.Burst] {
        let ts = times.sorted()
        var out: [ActivitySummary.Burst] = []
        var i = 0
        while i < ts.count {
            var j = i
            while j + 1 < ts.count && ts[j + 1] - ts[j] <= gap { j += 1 }
            if j - i + 1 >= minCount { out.append(.init(start: ts[i], end: ts[j], count: j - i + 1)) }
            i = j + 1
        }
        return out
    }

    /// Stretches with no pointer motion, clicks, keys or scrolls, longer than `minDuration`.
    public static func idleRanges(_ log: EventLog, duration: Double, minDuration: Double = 2.0, motionEpsilon: Double = 0.002) -> [TimeRange] {
        var activity: [Double] = log.clicks.map(\.t) + log.keys.map(\.t) + log.scrolls.map(\.t)
        var last: PointerSample?
        for s in log.pointer {
            if let l = last, abs(l.x - s.x) + abs(l.y - s.y) > motionEpsilon { activity.append(s.t) }
            last = s
        }
        activity.sort()
        var out: [TimeRange] = []
        var prev = 0.0
        for t in activity + [duration] {
            if t - prev >= minDuration { out.append(TimeRange(prev, t)) }
            prev = max(prev, t)
        }
        return out
    }

    public static func summarize(_ log: EventLog, duration: Double) -> ActivitySummary {
        var travel = 0.0
        for (a, b) in zip(log.pointer, log.pointer.dropFirst()) { travel += a.point.distance(to: b.point) }
        return ActivitySummary(
            clicks: log.clicks,
            typing: bursts(log.keys.map(\.t), gap: 1.2, minCount: 3),
            scrolling: bursts(log.scrolls.map(\.t), gap: 0.5, minCount: 2),
            idle: idleRanges(log, duration: duration),
            apps: log.apps,
            markers: log.markers,
            pointerTravel: travel
        )
    }

    /// Linear interpolation of the raw pointer path at time t.
    public static func pointer(at t: Double, in samples: [PointerSample]) -> NormPoint? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return first.point }
        guard let last = samples.last else { return nil }
        if t >= last.t { return last.point }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if samples[mid].t <= t { lo = mid } else { hi = mid } }
        let a = samples[lo], b = samples[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return NormPoint(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
}
