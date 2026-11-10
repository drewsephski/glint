import Foundation

/// Damped harmonic spring integrated with semi-implicit Euler at a fixed step. Deterministic, so a camera
/// path simulated for preview is bit-identical to the one used for export.
public struct Spring: Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double = 1
    public init(stiffness: Double, damping: Double, mass: Double = 1) { self.stiffness = stiffness; self.damping = damping; self.mass = mass }
    public var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

    @inline(__always)
    public func step(value: inout Double, velocity: inout Double, target: Double, dt: Double) {
        let force = -stiffness * (value - target) - damping * velocity
        velocity += force / mass * dt
        value += velocity * dt
    }
}

@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

// MARK: - Cursor

/// Uniformly resampled, zero-phase smoothed cursor path (source time). Offline smoothing has no lag, and
/// clicks are pinned so the drawn cursor is exactly where the user clicked.
public struct CursorPath: Sendable {
    public static let rate = 120.0
    public let start: Double
    public let xs: [Double]
    public let ys: [Double]
    /// Opacity track for idle hiding (same sampling).
    public let alpha: [Double]
    public let clicks: [ClickEvent]

    public init(log: EventLog, duration: Double, style: CursorStyle) {
        let samples = log.pointer
        clicks = log.clicks
        guard let first = samples.first else {
            start = 0; xs = []; ys = []; alpha = []; return
        }
        start = max(0, min(first.t, 0))
        let n = max(2, Int(((max(duration, samples.last!.t) - start) * Self.rate).rounded(.up)) + 1)
        var rx = [Double](repeating: 0, count: n), ry = rx
        // Linear resample.
        var j = 0
        for i in 0..<n {
            let t = start + Double(i) / Self.rate
            while j + 1 < samples.count && samples[j + 1].t <= t { j += 1 }
            let a = samples[j]
            if j + 1 < samples.count, t > a.t {
                let b = samples[j + 1]
                let f = (t - a.t) / max(1e-9, b.t - a.t)
                rx[i] = a.x + (b.x - a.x) * f; ry[i] = a.y + (b.y - a.y) * f
            } else { rx[i] = a.x; ry[i] = a.y }
        }
        // Gaussian smoothing.
        let sigma = max(0, min(1, style.smoothing)) * 0.11 * Self.rate   // up to ~110 ms
        var sx = rx, sy = ry
        if sigma >= 0.5 {
            let radius = Int((sigma * 3).rounded(.up))
            let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
            for i in 0..<n {
                var ax = 0.0, ay = 0.0, w = 0.0
                for k in -radius...radius {
                    let idx = min(n - 1, max(0, i + k))
                    let kw = kernel[k + radius]
                    ax += rx[idx] * kw; ay += ry[idx] * kw; w += kw
                }
                sx[i] = ax / w; sy[i] = ay / w
            }
            // Pin clicks: blend back to the raw path within ±150 ms of every press/release.
            let pinWindow = 0.15
            for c in log.clicks {
                for tc in [c.t] + (c.up.map { [$0] } ?? []) {
                    let i0 = max(0, Int(((tc - pinWindow - start) * Self.rate).rounded(.down)))
                    let i1 = min(n - 1, Int(((tc + pinWindow - start) * Self.rate).rounded(.up)))
                    guard i0 <= i1 else { continue }
                    for i in i0...i1 {
                        let t = start + Double(i) / Self.rate
                        let pin = 1 - smoothstep(0, pinWindow, abs(t - tc))
                        sx[i] = sx[i] + (rx[i] - sx[i]) * pin
                        sy[i] = sy[i] + (ry[i] - sy[i]) * pin
                    }
                }
            }
        }
        xs = sx; ys = sy
        // Idle hiding.
        var al = [Double](repeating: 1, count: n)
        if style.hideAfterIdle > 0 {
            let fade = 0.3
            var lastMove = start
            let clickTimes = log.clicks.map(\.t)
            var ci = 0
            for i in 0..<n {
                let t = start + Double(i) / Self.rate
                if i > 0, abs(rx[i] - rx[i - 1]) + abs(ry[i] - ry[i - 1]) > 0.0004 { lastMove = t }
                while ci < clickTimes.count && clickTimes[ci] <= t { lastMove = max(lastMove, clickTimes[ci]); ci += 1 }
                let idle = t - lastMove
                al[i] = 1 - smoothstep(style.hideAfterIdle, style.hideAfterIdle + fade, idle)
            }
        }
        alpha = al
    }

    private func sample(_ arr: [Double], _ t: Double) -> Double {
        guard !arr.isEmpty else { return 0.5 }
        let f = (t - start) * Self.rate
        if f <= 0 { return arr[0] }
        let i = Int(f)
        if i >= arr.count - 1 { return arr[arr.count - 1] }
        let w = f - Double(i)
        return arr[i] * (1 - w) + arr[i + 1] * w
    }

    public var isEmpty: Bool { xs.isEmpty }
    public func position(at t: Double) -> NormPoint { NormPoint(sample(xs, t), sample(ys, t)) }
    public func opacity(at t: Double) -> Double { alpha.isEmpty ? 1 : sample(alpha, t) }

    /// Press feedback: 0 → 1 → 0 over a click (used to shrink the cursor slightly).
    public func pressAmount(at t: Double) -> Double {
        var m = 0.0
        for c in clicks where t >= c.t - 0.05 && t <= c.t + 0.35 {
            let d = t - c.t
            m = max(m, d < 0 ? smoothstep(-0.05, 0, d) : 1 - smoothstep(0.05, 0.35, d))
        }
        return m
    }

    /// Active click ripples at t: (position, progress 0…1).
    public func ripples(at t: Double, duration: Double = 0.5) -> [(NormPoint, Double)] {
        clicks.compactMap { c in
            let p = (t - c.t) / duration
            return p >= 0 && p <= 1 ? (c.point, p) : nil
        }
    }
}

// MARK: - Camera

/// Camera state in canvas-normalized coordinates: `center` is the point of the canvas shown at the output
/// center, `scale` the magnification (1 = whole canvas).
public struct CameraState: Hashable, Sendable {
    public var scale: Double
    public var cx: Double
    public var cy: Double
    /// Speed of the camera (canvas fractions per second, log-scale rate) — drives motion blur.
    public var speed: Double
    public init(scale: Double, cx: Double, cy: Double, speed: Double = 0) { self.scale = scale; self.cx = cx; self.cy = cy; self.speed = speed }
    public static let identity = CameraState(scale: 1, cx: 0.5, cy: 0.5)
}

/// Where the screen video sits on the canvas (canvas-normalized, top-left origin).
public struct CanvasLayout: Hashable, Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var screenRect: NormRect

    public init(document: ProjectDocument, outputWidth: Double, outputHeight: Double) {
        canvasWidth = outputWidth; canvasHeight = outputHeight
        let pad = document.style.background.kind == .none ? 0 : max(0, min(0.4, document.style.frame.padding))
        let shorter = min(outputWidth, outputHeight)
        let availW = outputWidth - 2 * pad * shorter, availH = outputHeight - 2 * pad * shorter
        let srcAspect = Double(document.media.width) / Double(max(1, document.media.height))
        var w = availW, h = availW / srcAspect
        if h > availH { h = availH; w = availH * srcAspect }
        screenRect = NormRect(x: (outputWidth - w) / 2 / outputWidth, y: (outputHeight - h) / 2 / outputHeight,
                              width: w / outputWidth, height: h / outputHeight)
    }

    /// Screen-normalized point → canvas-normalized point.
    public func canvasPoint(_ p: NormPoint) -> NormPoint {
        NormPoint(screenRect.x + p.x * screenRect.width, screenRect.y + p.y * screenRect.height)
    }

    /// Where a shot of a different shape sits inside the screen frame (aspect-fit, centred), canvas-normalized.
    /// Returns the screen rect itself when the shapes match within 1%.
    public func fitted(pixelWidth w: Int, pixelHeight h: Int) -> NormRect {
        guard w > 0, h > 0 else { return screenRect }
        let frameAspect = (screenRect.width * canvasWidth) / max(1e-9, screenRect.height * canvasHeight)
        let a = Double(w) / Double(h)
        guard abs(a / frameAspect - 1) > 0.01 else { return screenRect }
        var fw = screenRect.width, fh = screenRect.height
        if a > frameAspect { fh = fw * canvasWidth / a / canvasHeight } else { fw = fh * canvasHeight * a / canvasWidth }
        return NormRect(x: screenRect.x + (screenRect.width - fw) / 2, y: screenRect.y + (screenRect.height - fh) / 2, width: fw, height: fh)
    }

    /// A point normalized to a shot shown in `content` (canvas-normalized) → canvas-normalized.
    public static func point(_ p: NormPoint, in content: NormRect) -> NormPoint {
        NormPoint(content.x + p.x * content.width, content.y + p.y * content.height)
    }

    /// Keep the visible viewport over the screen (or the screen inside the viewport when zoomed out).
    public func clamp(center c: NormPoint, scale: Double) -> NormPoint {
        let vw = 1 / scale, vh = 1 / scale
        func axis(_ v: Double, _ view: Double, _ lo: Double, _ size: Double) -> Double {
            if view <= size {
                return min(max(v, lo + view / 2), lo + size - view / 2)
            } else {
                // Viewport larger than the screen: keep the screen fully inside the viewport and inside the canvas.
                let a = min(max(v, lo + size - view / 2), lo + view / 2)
                return min(max(a, view / 2), 1 - view / 2)
            }
        }
        return NormPoint(axis(c.x, vw, screenRect.x, screenRect.width), axis(c.y, vh, screenRect.y, screenRect.height))
    }
}

/// Where the facecam bubble sits on the canvas.
public enum FacecamLayout {
    /// How far the screen is zoomed in, 0 (at rest) … 1 (zoomed), eased so the bubble resizes without a hard start.
    public static func zoomed(cameraScale: Double, restScale: Double) -> Double {
        let x = max(0, min(1, (cameraScale / max(0.01, restScale) - 1) / 0.4))
        return x * x * (3 - 2 * x)
    }

    /// The bubble in canvas-normalized coordinates (origin top-left). `zoomed` shrinks it towards its corner.
    public static func rect(_ s: FacecamStyle, canvasWidth W: Double, canvasHeight H: Double, zoomed: Double = 0) -> NormRect {
        let shorter = min(W, H)
        let margin = max(0, min(0.2, s.margin)) * shorter
        let k = 1 + (max(0.3, min(1, s.scaleWhenZoomed)) - 1) * max(0, min(1, zoomed))
        var h = max(0.08, min(0.6, s.size)) * shorter * k
        var w = h * s.aspect
        // A wide bubble on a narrow canvas: keep it inside the margins.
        let maxW = W - 2 * margin
        if w > maxW { w = maxW; h = w / s.aspect }
        let x = s.position.isLeft ? margin : W - margin - w
        let y = s.position.isTop ? margin : H - margin - h
        return NormRect(x: x / W, y: y / H, width: w / W, height: h / H)
    }
}

public struct CameraPath: Sendable {
    public static let rate = 120.0
    public let samples: [CameraState]

    /// Simulate the camera over the OUTPUT timeline so transitions keep their feel after speed changes.
    public init(document: ProjectDocument, map: TimeMap, cursor: CursorPath, layout: CanvasLayout) {
        let duration = map.outputDuration
        let style = document.style.zoom
        let spring = Spring(stiffness: max(1, style.stiffness), damping: max(0, style.damping), mass: max(0.1, style.mass))
        // Zoom segments in output time.
        struct Active { var range: TimeRange; var seg: ZoomSegment }
        let actives: [Active] = document.timeline.zooms.compactMap { z in
            guard z.end > z.start, let span = map.outputSpan(forSource: z.range) else { return nil }
            return Active(range: span, seg: z)
        }.sorted { $0.range.start < $1.range.start }

        let dt = 1.0 / 240.0
        let n = Int((duration * Self.rate).rounded(.up)) + 1
        var out: [CameraState] = []
        out.reserveCapacity(n)
        var logS = log(max(1, min(4, document.style.canvas.baseScale))), vS = 0.0
        var cx = 0.5, cy = 0.5, vx = 0.0, vy = 0.0
        var targetCenter = NormPoint(0.5, 0.5)
        var currentSegID: String?
        let lookahead = 0.3
        let baseScale = max(1, min(4, document.style.canvas.baseScale))
        var t = 0.0
        let substeps = Int(240 / Self.rate)
        var stepIndex = 0
        func cursorCanvas(_ tOut: Double) -> NormPoint {
            if cursor.isEmpty { return NormPoint(0.5, 0.5) }
            return layout.canvasPoint(cursor.position(at: map.source(forOutput: min(duration, tOut))))
        }
        while out.count < n {
            if stepIndex % substeps == 0 {
                let speed = (vx * vx + vy * vy).squareRoot() + abs(vS) * 0.5
                let c = layout.clamp(center: NormPoint(cx, cy), scale: exp(logS))
                out.append(CameraState(scale: exp(logS), cx: c.x, cy: c.y, speed: speed))
            }
            // Target.
            let active = actives.last(where: { $0.range.contains(t) })
            let targetScale: Double
            func follow(_ vw: Double) {
                let cur = cursorCanvas(t + lookahead)
                let dz = max(0.05, min(0.9, style.followDeadZone)) * vw / 2
                if cur.x > targetCenter.x + dz { targetCenter.x = cur.x - dz }
                if cur.x < targetCenter.x - dz { targetCenter.x = cur.x + dz }
                if cur.y > targetCenter.y + dz { targetCenter.y = cur.y - dz }
                if cur.y < targetCenter.y - dz { targetCenter.y = cur.y + dz }
            }
            if let a = active {
                targetScale = min(8, baseScale * max(1, a.seg.scale))
                switch a.seg.focus {
                case .point(let p):
                    targetCenter = layout.canvasPoint(p)
                case .followCursor:
                    if currentSegID != a.seg.id {
                        // Entering: aim at where the cursor will be when the action happens.
                        targetCenter = cursorCanvas(min(a.range.end, t + 0.6))
                    } else {
                        follow(1 / targetScale)
                    }
                }
                currentSegID = a.seg.id
            } else {
                targetScale = baseScale
                if baseScale > 1.01 {
                    if currentSegID != nil || t == 0 { targetCenter = cursorCanvas(t + lookahead) }
                    follow(1 / targetScale)
                } else {
                    targetCenter = NormPoint(0.5, 0.5)
                }
                currentSegID = nil
            }
            targetCenter = layout.clamp(center: targetCenter, scale: targetScale)
            spring.step(value: &logS, velocity: &vS, target: log(targetScale), dt: dt)
            spring.step(value: &cx, velocity: &vx, target: targetCenter.x, dt: dt)
            spring.step(value: &cy, velocity: &vy, target: targetCenter.y, dt: dt)
            if logS < 0 { logS = 0; vS = max(0, vS) }
            t += dt
            stepIndex += 1
        }
        samples = out
    }

    public func state(at t: Double) -> CameraState {
        guard !samples.isEmpty else { return .identity }
        let f = max(0, t) * Self.rate
        let i = Int(f)
        if i >= samples.count - 1 { return samples[samples.count - 1] }
        let w = f - Double(i)
        let a = samples[i], b = samples[i + 1]
        return CameraState(scale: a.scale + (b.scale - a.scale) * w, cx: a.cx + (b.cx - a.cx) * w,
                           cy: a.cy + (b.cy - a.cy) * w, speed: a.speed + (b.speed - a.speed) * w)
    }
}
