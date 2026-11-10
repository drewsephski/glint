import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import CoreMedia
import GlintCore

/// Host-clock seconds — the same clock ScreenCaptureKit stamps frames with, so events and video align exactly.
public func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// Records pointer, clicks, typing activity, scrolls, frontmost app and cursor images.
///
/// Needs no permissions: it polls the pointer position, button state and "seconds since last key/scroll"
/// (`CGEventSource`) at 120 Hz. That yields exact typing *timing* without ever seeing which keys were pressed,
/// which is all the zoom and speed planners need. With Accessibility granted it also names click targets.
///
/// Times are kept relative to `start()` and rebased when read (`snapshot`/`stop`): onto the first video frame, with
/// input made while the take's `PauseClock` was paused dropped and the paused time collapsed (`EventLog.rebased`).
/// For a window recording the window's frame is polled (10 Hz, every tick while a button is held, which is when windows
/// get dragged) and positions are normalized against the frame at that instant; frame changes go into the log.
public final class InputTracker: @unchecked Sendable {
    public private(set) var log = EventLog()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var mainTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "glint.input", qos: .userInteractive)
    private var origin: Double = 0          // host seconds of the first video frame
    private var pendingOrigin = true
    private var region: CGRect              // captured region in global points (top-left origin)
    private var lastPos: CGPoint?
    private var buttons: [Bool] = [false, false]
    private var lastKeySecs: Double = .infinity
    private var lastScrollSecs: Double = .infinity
    private var startHost: Double = 0
    private var bufferedRaw: [(Double, CGPoint)] = []
    private var cursorHashes: [Int: String] = [:]
    private var lastCursorID: String?
    private var lastApp: String?
    private var referenceCursors: [Int: String] = [:]
    private let cursorsDir: URL?
    private let axTrusted = AXIsProcessTrusted()
    /// `.agent`: the pointer path comes only from reported agent actions (e.g. a browser driven over CDP, where the
    /// system cursor never moves); `.system`: poll the real cursor.
    public enum PointerSource: String, Sendable { case system, agent }
    public let pointerSource: PointerSource
    private var agentPos: NormPoint = .center
    private let clock: PauseClock?
    /// The recorded window (window recordings only): its frame is tracked over time.
    public let windowID: CGWindowID?
    private var windowFrames: [WindowFrameSample] = []
    // Touched only on `queue`.
    private var lastWindowPoll: Double = 0
    private var windowGone = false
    /// Called with a plain-language warning (the recorded window closed).
    public var onWarning: ((String) -> Void)?

    public init(region: CGRect, cursorsDirectory: URL?, pointerSource: PointerSource = .system, windowID: CGWindowID? = nil, clock: PauseClock? = nil) {
        self.region = region
        self.cursorsDir = cursorsDirectory
        self.pointerSource = pointerSource
        self.windowID = windowID
        self.clock = clock
    }

    /// An action an agent performed during the recording (it knows what it clicked; the OS may not have seen it).
    public enum AgentAction: Sendable {
        case move(NormPoint)
        case click(NormPoint, label: String?)
        case type(count: Int, duration: Double, text: String?)
        case scroll(NormPoint)
    }

    /// Record an agent-reported action at the current time. In `.agent` pointer mode the cursor glides to the
    /// target over the preceding 0.45 s so the redrawn cursor looks natural.
    public func report(_ action: AgentAction) {
        lock.lock(); defer { lock.unlock() }
        let now = t(hostSeconds())
        func glide(to p: NormPoint) {
            guard pointerSource == .agent else { return }
            let from = agentPos, dur = 0.45
            for i in 0...27 {
                let f = Double(i) / 27, e = f * f * (3 - 2 * f)
                log.pointer.append(PointerSample(t: now - dur + dur * f, x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e))
            }
            agentPos = p
        }
        switch action {
        case .move(let p): glide(to: p)
        case .click(let p, let label):
            glide(to: p)
            log.clicks.append(ClickEvent(t: now, x: p.x, y: p.y, button: .left, up: now + 0.08, target: label))
        case .type(let count, let duration, let text):
            let n = max(1, count)
            let chars = text.map(Array.init)
            for i in 0..<n {
                log.keys.append(KeyEvent(t: now + duration * Double(i) / Double(n), key: chars.flatMap { i < $0.count ? String($0[i]) : nil }))
            }
        case .scroll(let p):
            log.scrolls.append(ScrollEvent(t: now, x: p.x, y: p.y))
        }
    }

    /// Convert a global point (top-left origin, points) into this recording's normalized space.
    public func normalized(global p: CGPoint) -> NormPoint {
        let (x, y) = lock.withLock { normalize(p) }
        return NormPoint(x, y)
    }

    /// Start polling now; event times are rebased once `setOrigin` receives the first frame's host time.
    public func start() {
        startHost = hostSeconds()
        if windowID != nil {
            lock.withLock { windowFrames = [WindowFrameSample(t: 0, x: region.minX, y: region.minY, width: region.width, height: region.height)] }
            lastWindowPoll = startHost
        }
        lastKeySecs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        lastScrollSecs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        let mt = DispatchSource.makeTimerSource(queue: .main)
        mt.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        var prepared = false
        mt.setEventHandler { [weak self] in
            guard let self else { return }
            if !prepared { prepared = true; self.prepareReferenceCursors() }
            self.pollMain()
        }
        mt.resume()
        mainTimer = mt
    }

    public func setOrigin(_ hostTime: Double) {
        lock.lock(); defer { lock.unlock() }
        guard pendingOrigin else { return }
        origin = hostTime
        pendingOrigin = false
    }

    public func stop() -> EventLog {
        timer?.cancel(); timer = nil
        mainTimer?.cancel(); mainTimer = nil
        // Let a poll already running finish before reading the log.
        queue.sync {}
        return snapshot()
    }

    /// The log so far, rebased onto the take (first video frame = 0, paused time removed). Used for the periodic
    /// recovery checkpoint and, at stop, for the final events.
    public func snapshot() -> EventLog {
        lock.lock(); defer { lock.unlock() }
        var raw = log
        if windowID != nil { raw.windowFrames = windowFrames }
        let pauses = clock?.snapshot ?? PauseTimeline()
        return raw.rebased(start: startHost, origin: originHost(pauses), pauses: pauses)
    }

    /// Gapless host time of the first frame (or of tracker start before one arrives). Caller holds the lock.
    private func originHost(_ pauses: PauseTimeline) -> Double { pendingOrigin ? pauses.collapse(startHost) : origin }

    /// Drops a marker now. The returned marker carries its time in the take.
    public func addMarker(_ note: String, author: Author) -> Marker {
        lock.lock(); defer { lock.unlock() }
        let now = hostSeconds()
        var m = Marker(time: now - startHost, note: note, author: author)
        log.markers.append(m)
        let pauses = clock?.snapshot ?? PauseTimeline()
        m.time = max(0, pauses.collapse(now) - originHost(pauses))
        return m
    }

    private func t(_ host: Double) -> Double { host - startHost }

    /// Seconds of take since the first video frame, paused time excluded (for live status).
    public var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        let pauses = clock?.snapshot ?? PauseTimeline()
        return max(0, pauses.collapse(hostSeconds()) - originHost(pauses))
    }

    /// Re-reads the recorded window's frame (on `queue`). Window Server bounds are global points with a top-left
    /// origin, the same space as pointer locations, and need no permission.
    private func refreshWindowFrame(_ now: Double) {
        lastWindowPoll = now
        guard let id = windowID, !windowGone else { return }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        guard let entry = info?.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bounds as CFDictionary), r.width > 1, r.height > 1 else {
            windowGone = true
            let at = elapsed
            onWarning?(String(format: "The recorded window closed at %.1f s; pointer positions after that use its last frame.", at))
            return
        }
        lock.withLock {
            let sample = WindowFrameSample(t: t(now), x: r.minX, y: r.minY, width: r.width, height: r.height)
            if let last = windowFrames.last, !sample.differs(from: last) { return }
            region = r
            windowFrames.append(sample)
        }
    }

    static func fnv(_ d: Data) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }

    /// Caller holds the lock.
    private func normalize(_ p: CGPoint) -> (Double, Double) {
        let n = CaptureGeometry.normalize(x: p.x, y: p.y, in: [region.minX, region.minY, region.width, region.height])
        return (n.x, n.y)
    }

    private func poll() {
        let now = hostSeconds()
        guard let pos = CGEvent(source: nil)?.location else { return }
        if windowID != nil {
            let held = CGEventSource.buttonState(.combinedSessionState, button: .left)
            if held || now - lastWindowPoll >= 0.1 { refreshWindowFrame(now) }
        }
        lock.lock(); defer { lock.unlock() }
        let time = t(now)
        let (nx, ny) = normalize(pos)
        if pointerSource == .agent { return }
        if lastPos != pos {
            log.pointer.append(PointerSample(t: time, x: nx, y: ny))
            lastPos = pos
        } else if let last = log.pointer.last, time - last.t > 0.25 {
            // Keep a sparse heartbeat while still so interpolation never spans long gaps.
            log.pointer.append(PointerSample(t: time, x: nx, y: ny))
        }
        // Buttons.
        for (i, button) in [CGMouseButton.left, .right].enumerated() {
            let down = CGEventSource.buttonState(.combinedSessionState, button: button)
            if down != buttons[i] {
                buttons[i] = down
                if down {
                    log.clicks.append(ClickEvent(t: time, x: nx, y: ny, button: i == 0 ? .left : .right))
                    if axTrusted { lookupTarget(at: pos, index: log.clicks.count - 1) }
                } else if let idx = log.clicks.lastIndex(where: { $0.up == nil && $0.button == (i == 0 ? .left : .right) }) {
                    log.clicks[idx].up = time
                }
            }
        }
        // Keys / scroll: the "seconds since" counter resets when a new event arrives.
        let ks = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if ks < lastKeySecs - 0.001 {
            log.keys.append(KeyEvent(t: time - ks))
        }
        lastKeySecs = ks
        let ss = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        if ss < lastScrollSecs - 0.001 {
            log.scrolls.append(ScrollEvent(t: time - ss, x: nx, y: ny))
        }
        lastScrollSecs = ss
    }

    private func lookupTarget(at p: CGPoint, index: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sys = AXUIElementCreateSystemWide()
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return }
            func attr(_ a: String) -> String? {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
                return s
            }
            let label = attr(kAXTitleAttribute) ?? attr(kAXDescriptionAttribute) ?? attr(kAXValueAttribute).map { String($0.prefix(40)) } ?? attr(kAXRoleDescriptionAttribute)
            guard let self, let label else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.log.clicks.indices.contains(index) { self.log.clicks[index].target = label }
        }
    }

    // MARK: Main-thread sampling: cursor image + frontmost app.

    private func prepareReferenceCursors() {
        let refs: [(NSCursor, String)] = [(.arrow, "arrow"), (.iBeam, "iBeam"), (.pointingHand, "pointingHand"), (.openHand, "openHand"),
                                          (.closedHand, "closedHand"), (.crosshair, "crosshair"), (.operationNotAllowed, "notAllowed"),
                                          (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown")]
        for (c, n) in refs { if let d = c.image.tiffRepresentation { referenceCursors[Self.fnv(d)] = n } }
    }

    private func pollMain() {
        let now = hostSeconds()
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            if name != lastApp {
                lastApp = name
                lock.lock(); log.apps.append(AppFocusEvent(t: t(now), bundleID: app.bundleIdentifier, name: name)); lock.unlock()
            }
        }
        guard let cursorsDir, let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let h = Self.fnv(tiff)
        let id: String
        if let existing = cursorHashes[h] { id = existing } else {
            id = "cur\(cursorHashes.count)"
            cursorHashes[h] = id
            // Save the highest-resolution representation.
            let best = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
                ?? NSBitmapImageRep(data: tiff)
            if let png = best?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: cursorsDir, withIntermediateDirectories: true)
                try? png.write(to: cursorsDir.appendingPathComponent("\(id).png"))
            }
            let info = CursorImage(id: id, width: image.size.width, height: image.size.height, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y, kind: referenceCursors[h])
            lock.lock(); log.cursors.append(info); lock.unlock()
        }
        if id != lastCursorID {
            lastCursorID = id
            lock.lock(); log.cursorChanges.append(CursorChange(t: t(now), cursorID: id)); lock.unlock()
        }
    }
}
