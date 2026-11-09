import Foundation
import CoreImage
import CoreGraphics
import GlintCore

/// Everything needed to draw any output frame, precomputed from a document snapshot. Immutable apart from
/// thread-safe caches, so the compositor can render frames concurrently. Preview and export share it.
public final class RenderPlan: @unchecked Sendable {
    public let document: ProjectDocument
    public let events: EventLog
    public let map: TimeMap
    public let cursor: CursorPath
    public let camera: CameraPath
    public let layout: CanvasLayout
    public let width: Int
    public let height: Int
    let background: CIImage
    let cursorImages: [String: (CIImage, CursorImage)]
    let arrow: (CIImage, hot: CGPoint, sizePt: CGSize)?
    let ring: CIImage?
    /// Sub-frames averaged for camera motion blur (preview uses few, export more).
    public var motionSamples = 4
    private var captionCache: [String: CIImage] = [:]
    private let cacheLock = NSLock()

    public init(document: ProjectDocument, events: EventLog, bundle: ProjectBundle?, width: Int, height: Int) {
        self.document = document
        self.events = events
        self.width = width - width % 2
        self.height = height - height % 2
        map = TimeMap(document: document)
        cursor = CursorPath(log: events, duration: document.media.duration, style: document.style.cursor)
        layout = CanvasLayout(document: document, outputWidth: Double(self.width), outputHeight: Double(self.height))
        camera = CameraPath(document: document, map: map, cursor: cursor, layout: layout)
        background = Artwork.background(document.style.background, width: self.width, height: self.height, bundle: bundle)
        var imgs: [String: (CIImage, CursorImage)] = [:]
        if let bundle {
            for c in events.cursors {
                if let img = CIImage(contentsOf: bundle.cursorsURL.appendingPathComponent("\(c.id).png")) { imgs[c.id] = (img, c) }
            }
        }
        cursorImages = imgs
        arrow = Artwork.arrowCursor()
        ring = Artwork.ring()
    }

    /// Output size for a project at a target height and aspect.
    public static func outputSize(document: ProjectDocument, aspect: Aspect? = nil, height: Int = 1080) -> (Int, Int) {
        let a = (aspect ?? document.style.canvas.aspect).ratio(sourceWidth: document.media.width, sourceHeight: document.media.height)
        if a >= 1 {
            let h = height, w = Int((Double(h) * a).rounded())
            return (w - w % 2, h)
        } else {
            // Portrait: `height` names the short side (1080 → 1080×1920).
            let w = height, h = Int((Double(w) / a).rounded())
            return (w, h - h % 2)
        }
    }

    func caption(_ key: String, make: () -> CIImage?) -> CIImage? {
        cacheLock.lock()
        if let c = captionCache[key] { cacheLock.unlock(); return c }
        cacheLock.unlock()
        guard let img = make() else { return nil }
        cacheLock.lock(); captionCache[key] = img
        if captionCache.count > 400 { captionCache.removeAll() }
        cacheLock.unlock()
        return img
    }
}

/// Composes one output frame: background, shadowed rounded screen, cursor, click ripples, captions —
/// under a spring-animated camera, with sub-frame motion blur on fast camera moves.
public enum SceneRenderer {
    public static func render(plan: RenderPlan, screen: CIImage?, outputTime t: Double, frameDuration: Double = 1.0 / 60) -> CIImage {
        let W = Double(plan.width), H = Double(plan.height)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let cam = plan.camera.state(at: t)
        let blur = plan.document.style.zoom.motionBlur
        var scene: CIImage
        if blur > 0, cam.speed > 0.35 {
            // Average sub-frame camera positions across the shutter interval with tent weights.
            // Weights scale alpha only: CIColorMatrix works on unpremultiplied colour, so scaling alpha scales the
            // premultiplied contribution exactly once.
            let n = max(4, Int((Double(plan.motionSamples) * min(1, cam.speed / 1.2)).rounded()))
            let shutter = frameDuration * 0.5 * min(1, blur * 1.5)
            let weights = (0..<n).map { i -> Double in 1 - abs(Double(i) / Double(n - 1) - 0.5) }
            let total = weights.reduce(0, +)
            var acc: CIImage?
            for i in 0..<n {
                let dt = shutter * (Double(i) / Double(n - 1) - 0.5)
                let layer = faded(sceneLayer(plan: plan, screen: screen, camera: plan.camera.state(at: max(0, t + dt)), t: t, canvas: canvas), weights[i] / total)
                acc = acc.map { layer.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? layer
            }
            scene = acc!
        } else {
            scene = sceneLayer(plan: plan, screen: screen, camera: cam, t: t, canvas: canvas)
        }
        // Captions sit above the camera (not zoomed).
        if let cap = captionLayer(plan: plan, t: t, canvas: canvas) { scene = cap.composited(over: scene) }
        return scene.cropped(to: canvas)
    }

    /// Canvas-normalized (top-left) → output pixels (CI, bottom-left) under the camera.
    @inline(__always)
    static func transform(_ cam: CameraState, W: Double, H: Double) -> CGAffineTransform {
        // p_out = (p_ci - C) * s + O, where C = camera center in CI pixels.
        let cxp = cam.cx * W, cyp = (1 - cam.cy) * H
        return CGAffineTransform(translationX: W / 2, y: H / 2).scaledBy(x: cam.scale, y: cam.scale).translatedBy(x: -cxp, y: -cyp)
    }

    static func sceneLayer(plan: RenderPlan, screen: CIImage?, camera cam: CameraState, t: Double, canvas: CGRect) -> CIImage {
        let W = canvas.width, H = canvas.height
        let doc = plan.document
        let T = transform(cam, W: W, H: H)
        let shorter = min(W, H)
        // Screen rect in canvas CI pixels.
        let sr = plan.layout.screenRect
        let screenCI = CGRect(x: sr.x * W, y: (1 - sr.y - sr.height) * H, width: sr.width * W, height: sr.height * H)
        let screenOut = screenCI.applying(T)
        let radius = doc.style.frame.cornerRadius * min(screenCI.width, screenCI.height) * cam.scale

        var out = plan.background.transformed(by: T)
        // Background beyond the canvas edges (only visible during spring overshoot) is clamped.
        out = out.clampedToExtent().cropped(to: canvas)

        if doc.style.background.kind != .none, doc.style.frame.shadowOpacity > 0 {
            let r = doc.style.frame.shadowRadius * shorter * cam.scale
            let shadowRect = screenOut.offsetBy(dx: 0, dy: -r * 0.35)
            let shape = roundedRect(shadowRect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: doc.style.frame.shadowOpacity))
            let shadow = shape.applyingGaussianBlur(sigma: max(0.5, r * 0.5))
            out = shadow.composited(over: out)
        }

        // Screen: one transform from source pixels straight to output pixels keeps full source sharpness.
        if let screen {
            let ext = screen.extent
            let place = CGAffineTransform(translationX: screenCI.minX, y: screenCI.minY)
                .scaledBy(x: screenCI.width / ext.width, y: screenCI.height / ext.height)
                .translatedBy(x: -ext.minX, y: -ext.minY)
            var s = screen.transformed(by: place.concatenating(T), highQualityDownsample: true)
            if radius > 0.5, doc.style.background.kind != .none {
                let mask = roundedRect(screenOut, radius: radius, color: .white)
                s = s.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
            } else {
                s = s.cropped(to: screenOut)
            }
            out = s.composited(over: out)
        } else {
            out = roundedRect(screenOut, radius: radius, color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).composited(over: out)
        }

        // Cursor + ripples (content-space, so they scale with the camera).
        let srcT = plan.map.source(forOutput: t)
        let cs = doc.style.cursor
        if cs.visible, !plan.cursor.isEmpty {
            let alpha = plan.cursor.opacity(at: srcT)
            let pos = plan.cursor.position(at: srcT)
            let canvasPt = plan.layout.canvasPoint(pos)
            let p = CGPoint(x: canvasPt.x * W, y: (1 - canvasPt.y) * H).applying(T)
            // Points → output pixels: source px per pt (media scale) × placement scale × camera scale.
            let placementScale = screenCI.width / Double(doc.media.width)
            let ptToOut = doc.media.scale * placementScale * cam.scale * cs.scale

            if cs.clickEffect, let ring = plan.ring {
                for (cp, prog) in plan.cursor.ripples(at: srcT) {
                    let c = plan.layout.canvasPoint(cp)
                    let center = CGPoint(x: c.x * W, y: (1 - c.y) * H).applying(T)
                    let diameter = (18 + 34 * easeOut(prog)) * ptToOut
                    let a = (1 - prog) * cs.clickColor.a
                    let k = diameter / ring.extent.width
                    let r = ring.transformed(by: CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2).scaledBy(x: k, y: k))
                        .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: cs.clickColor.r, y: 0, z: 0, w: 0),
                                                                      "inputGVector": CIVector(x: 0, y: cs.clickColor.g, z: 0, w: 0),
                                                                      "inputBVector": CIVector(x: 0, y: 0, z: cs.clickColor.b, w: 0),
                                                                      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
                    out = r.composited(over: out)
                }
            }

            if alpha > 0.01 {
                let press = 1 - 0.14 * plan.cursor.pressAmount(at: srcT)
                var img: CIImage, hot: CGPoint, sizePt: CGSize
                let id = plan.events.cursorChanges.last(where: { $0.t <= srcT })?.cursorID
                if cs.appearance == .recorded, let id, let (ci, info) = plan.cursorImages[id] {
                    img = ci; hot = CGPoint(x: info.hotX, y: info.hotY); sizePt = CGSize(width: info.width, height: info.height)
                } else if let a = plan.arrow {
                    img = a.0; hot = a.hot; sizePt = a.sizePt
                } else { return out }
                let targetW = sizePt.width * ptToOut * press
                let k = targetW / img.extent.width
                // Hotspot is top-left origin in points; image y is up.
                let hx = hot.x * ptToOut * press, hy = (sizePt.height - hot.y) * ptToOut * press
                var c = img.transformed(by: CGAffineTransform(translationX: p.x - hx, y: p.y - hy).scaledBy(x: k, y: k), highQualityDownsample: true)
                if alpha < 0.999 { c = faded(c, alpha) }
                out = c.composited(over: out)
            }
        }
        return out
    }

    static func captionLayer(plan: RenderPlan, t: Double, canvas: CGRect) -> CIImage? {
        let style = plan.document.style.captions
        guard style.enabled else { return nil }
        let srcT = plan.map.source(forOutput: t)
        guard let seg = plan.document.timeline.captions.first(where: { !$0.hidden && srcT >= $0.start && srcT < $0.end }) else { return nil }
        let words = seg.words.map(\.text)
        let active = seg.words.lastIndex(where: { srcT >= $0.start - 0.02 })
        let key = "\(seg.id)|\(seg.text.hashValue)|\(style.look == .highlight ? (active ?? -1) : -1)"
        guard let img = plan.caption(key, make: {
            Artwork.caption(text: seg.text, words: words, activeWord: active, style: style, canvasHeight: canvas.height, maxWidth: canvas.width * 0.88)
        }) else { return nil }
        let margin = canvas.height * 0.06
        let x = (canvas.width - img.extent.width) / 2
        let y = style.position == "top" ? canvas.height - margin - img.extent.height : margin
        // Fade in/out over 120 ms.
        let fadeIn = min(1, (srcT - seg.start) / 0.12), fadeOut = min(1, (seg.end - srcT) / 0.12)
        let a = max(0, min(fadeIn, fadeOut))
        var placed = img.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        if a < 0.999 { placed = faded(placed, a) }
        return placed
    }

    static func roundedRect(_ r: CGRect, radius: Double, color: CIColor) -> CIImage {
        let f = CIFilter(name: "CIRoundedRectangleGenerator")!
        f.setValue(CIVector(cgRect: r), forKey: "inputExtent")
        f.setValue(min(radius, min(r.width, r.height) / 2), forKey: "inputRadius")
        f.setValue(color, forKey: "inputColor")
        return f.outputImage ?? CIImage.empty()
    }

    @inline(__always) static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// Multiply opacity (alpha-only; colour channels pass through unpremultiplied).
    static func faded(_ img: CIImage, _ alpha: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }
}
