import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import AppKit
import GlintCore

/// Generates a deterministic demo project (fake product UI video + matching input events + optional voice),
/// used by tests and by `glint demo-project` to try the editor without recording permissions.
public enum SyntheticProject {
    /// Normalized positions of UI targets in the fake app.
    public static let saveButton = NormPoint(0.82, 0.12)
    public static let searchField = NormPoint(0.36, 0.42)

    public static func make(at url: URL, duration: Double = 9, width: Int = 1280, height: Int = 800, fps: Int = 30, voice: Bool = false) async throws -> ProjectBundle {
        try? FileManager.default.removeItem(at: url)
        let doc = ProjectDocument(name: url.deletingPathExtension().lastPathComponent,
                                  media: MediaInfo(screen: "media/screen.mov", width: width, height: height, scale: 2, duration: duration, frameRate: Double(fps)))
        let events = makeEvents(duration: duration)
        let b = try ProjectBundle.create(at: url, document: doc, events: events)
        try await writeVideo(to: b.mediaURL.appendingPathComponent("screen.mov"), duration: duration, width: width, height: height, fps: fps)
        var d = doc
        if voice, let mic = try? makeVoice(to: b.mediaURL) {
            d.media.microphone = "media/" + mic.lastPathComponent
        }
        try b.writeDocument(d)
        return b
    }

    static func makeEvents(duration: Double) -> EventLog {
        var log = EventLog()
        // Pointer path: rest → Save (click 1.6s) → search field (click 3.0s) → typing 3.2–4.8s → wander → rest from 6.4s.
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        let keyframes: [(Double, NormPoint)] = [(0, NormPoint(0.5, 0.6)), (0.6, NormPoint(0.5, 0.6)), (1.5, saveButton), (2.1, saveButton),
                                                (2.9, searchField), (5.2, searchField), (6.2, NormPoint(0.62, 0.7)), (duration, NormPoint(0.62, 0.7))]
        var t = 0.0
        while t <= duration {
            let i = max(0, (keyframes.lastIndex { $0.0 <= t } ?? 0))
            let a = keyframes[i], b = keyframes[min(keyframes.count - 1, i + 1)]
            let f = b.0 > a.0 ? ease((t - a.0) / (b.0 - a.0)) : 0
            log.pointer.append(PointerSample(t: t, x: a.1.x + (b.1.x - a.1.x) * f, y: a.1.y + (b.1.y - a.1.y) * f))
            t += 1.0 / 120
        }
        log.clicks = [ClickEvent(t: 1.6, x: saveButton.x, y: saveButton.y, up: 1.7, target: "Save"),
                      ClickEvent(t: 3.0, x: searchField.x, y: searchField.y, up: 3.08, target: "Search")]
        log.keys = stride(from: 3.2, through: 4.8, by: 0.11).map { KeyEvent(t: $0) }
        log.apps = [AppFocusEvent(t: 0, bundleID: "dev.glint.fixture", name: "Acme Analytics")]
        return log
    }

    static func writeVideo(to url: URL, duration: Double, width: Int, height: Int, fps: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                                                                            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        for i in 0...frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw ServiceError.invalid("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            drawFrame(ctx, t: Double(i) / Double(fps), w: Double(width), h: Double(height))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ServiceError.invalid("fixture video failed: \(writer.error?.localizedDescription ?? "?")") }
    }

    /// A believable SaaS dashboard with state changes at the scripted times.
    static func drawFrame(_ ctx: CGContext, t: Double, w: Double, h: Double) {
        func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double) -> CGRect { CGRect(x: x * w, y: h - (y + rh) * h, width: rw * w, height: rh * h) }
        func fill(_ r: CGRect, _ c: (Double, Double, Double), radius: Double = 0) {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            if radius > 0 { ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath() } else { ctx.fill(r) }
        }
        func text(_ s: String, _ x: Double, _ y: Double, size: Double, color: (Double, Double, Double) = (0.15, 0.16, 0.2), weight: NSFont.Weight = .regular) {
            let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size * h / 800, weight: weight),
                                                                   .foregroundColor: NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x * w, y: h - y * h)
            CTLineDraw(line, ctx)
        }
        fill(CGRect(x: 0, y: 0, width: w, height: h), (0.965, 0.968, 0.98))
        // Sidebar.
        fill(rect(0, 0, 0.18, 1), (0.11, 0.12, 0.16))
        text("Acme", 0.025, 0.07, size: 22, color: (1, 1, 1), weight: .bold)
        for (i, item) in ["Overview", "Reports", "Customers", "Billing", "Settings"].enumerated() {
            if i == 1 { fill(rect(0.012, 0.135 + Double(i) * 0.06, 0.156, 0.046), (0.22, 0.24, 0.32), radius: 6) }
            text(item, 0.03, 0.165 + Double(i) * 0.06, size: 15, color: (0.85, 0.87, 0.92))
        }
        // Header + Save button (turns green after the click at 1.6s).
        text("Quarterly revenue", 0.21, 0.09, size: 26, weight: .semibold)
        let saved = t >= 1.7
        fill(rect(saveButton.x - 0.06, saveButton.y - 0.03, 0.12, 0.06), saved ? (0.16, 0.65, 0.35) : (0.92, 0.18, 0.2), radius: 8)
        text(saved ? "Saved ✓" : "Save", saveButton.x - (saved ? 0.035 : 0.022), saveButton.y + 0.012, size: 16, color: (1, 1, 1), weight: .semibold)
        // Search field with typed text.
        fill(rect(0.21, 0.39, 0.32, 0.06), (1, 1, 1), radius: 8)
        ctx.setStrokeColor(CGColor(srgbRed: 0.3, green: 0.45, blue: 0.95, alpha: t >= 3.0 && t < 6 ? 1 : 0.25)); ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: rect(0.21, 0.39, 0.32, 0.06), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.strokePath()
        let query = "enterprise customers in EMEA"
        let typed = t < 3.2 ? 0 : min(query.count, Int((t - 3.2) / 1.6 * Double(query.count)) + 1)
        text(typed == 0 ? "Search reports…" : String(query.prefix(typed)), 0.225, 0.43, size: 16, color: typed == 0 ? (0.6, 0.62, 0.68) : (0.12, 0.13, 0.17))
        // Chart cards; results appear after typing, progress bar fills 5–6.4s.
        for i in 0..<3 {
            let x = 0.21 + Double(i) * 0.255
            fill(rect(x, 0.5, 0.235, 0.4), (1, 1, 1), radius: 10)
            text(["ARR", "Net retention", "Pipeline"][i], x + 0.015, 0.545, size: 14, color: (0.45, 0.47, 0.53))
            text(["$4.2M", "118%", "$9.8M"][i], x + 0.015, 0.6, size: 24, weight: .bold)
            let bars = 7
            for k in 0..<bars {
                let grow = t > 4.8 ? min(1, (t - 4.8) / 1.2) : 0.35
                let bh = (0.08 + 0.18 * abs(sin(Double(k * 3 + i) * 1.3))) * grow
                fill(rect(x + 0.02 + Double(k) * 0.03, 0.86 - bh, 0.018, bh), (0.33, 0.45, 0.95), radius: 3)
            }
        }
        let progress = max(0, min(1, (t - 5.0) / 1.4))
        fill(rect(0.21, 0.94, 0.75, 0.012), (0.88, 0.89, 0.92), radius: 4)
        fill(rect(0.21, 0.94, 0.75 * progress, 0.012), (0.33, 0.45, 0.95), radius: 4)
    }

    /// Spoken narration via the system voice (`say`), converted to AAC.
    static func makeVoice(to dir: URL) throws -> URL {
        let aiff = dir.appendingPathComponent("voice.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", aiff.path, "-r", "185",
                       "Here is our quarterly dashboard. [[slnc 600]] First I save the report. [[slnc 2200]] Um, now let's search for enterprise customers in Europe. [[slnc 900]] And the charts update instantly."]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ServiceError.invalid("say failed") }
        return aiff
    }
}
