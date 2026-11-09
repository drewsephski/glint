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

    public init(region: CGRect, cursorsDirectory: URL?, pointerSource: PointerSource = .system) {
        self.region = region
        self.cursorsDir = cursorsDirectory
        self.pointerSource = pointerSource
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
        let (x, y) = normalize(p)
        return NormPoint(x, y)
    }

    /// Start polling now; event times are rebased once `setOrigin` receives the first frame's host time.
    public func start() {
        startHost = hostSeconds()
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
        lock.lock(); defer { lock.unlock() }
        // Times were recorded relative to tracker start; rebase them onto the first video frame.
        let shift = pendingOrigin ? 0 : (startHost - origin)
        var l = log
        l.pointer = l.pointer.map { PointerSample(t: $0.t + shift, x: $0.x, y: $0.y) }.filter { $0.t >= -0.5 }.sorted { $0.t < $1.t }
        l.clicks = l.clicks.map { var c = $0; c.t += shift; c.up = c.up.map { $0 + shift }; return c }.filter { $0.t >= 0 }
        l.keys = l.keys.map { var k = $0; k.t += shift; return k }.filter { $0.t >= 0 }
        l.scrolls = l.scrolls.map { var k = $0; k.t += shift; return k }.filter { $0.t >= 0 }
        l.apps = l.apps.map { var k = $0; k.t = max(0, k.t + shift); return k }
        l.cursorChanges = l.cursorChanges.map { var k = $0; k.t = max(0, k.t + shift); return k }
        l.markers = l.markers.map { var k = $0; k.time = max(0, k.time + shift); return k }
        return l
    }

    public func addMarker(_ note: String, author: Author) -> Marker {
        lock.lock(); defer { lock.unlock() }
        let m = Marker(time: hostSeconds() - startHost, note: note, author: author)
        log.markers.append(m)
        return m
    }

    private func t(_ host: Double) -> Double { host - startHost }

    /// Seconds since the first video frame (for live status).
    public var elapsed: Double { lock.lock(); defer { lock.unlock() }; return hostSeconds() - (pendingOrigin ? startHost : origin) }

    static func fnv(_ d: Data) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }

    private func normalize(_ p: CGPoint) -> (Double, Double) {
        ((p.x - region.minX) / max(1, region.width), (p.y - region.minY) / max(1, region.height))
    }

    private func poll() {
        let now = hostSeconds()
        guard let pos = CGEvent(source: nil)?.location else { return }
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
