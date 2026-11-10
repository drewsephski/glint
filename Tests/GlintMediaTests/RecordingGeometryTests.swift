import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

@testable import GlintAgent
@testable import GlintCapture
@testable import GlintCore
@testable import GlintRender

@Suite(.serialized) struct RecordingGeometryTests {
    /// Opt in on a Mac whose test runner already has Screen Recording access. Captures only this test window.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["GLINT_TEST_LIVE_CAPTURE"] == "1"))
    func liveWindowResizeRecordsExactContentBounds() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "The opt-in live capture test requires an existing Screen Recording grant.")
        let directory = fixtureURL("live-resize")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .red
        window.orderFront(nil)
        defer { window.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let source = try #require(content.windows.first { $0.windowID == UInt32(window.windowNumber) })
        var options = RecordingOptions()
        options.systemAudio = false
        let recorder = try ScreenRecorder(
            filter: SCContentFilter(desktopIndependentWindow: source), pixelWidth: 320, pixelHeight: 360,
            options: options, mediaDirectory: directory)
        try await recorder.start()
        do {
            let deadline = Date().addingTimeInterval(5)
            while recorder.captureContent.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(recorder.captureContent.first?.rect == NormRect(x: 0, y: 0, width: 1, height: 1))
            window.setContentSize(CGSize(width: 640, height: 360))
            while recorder.captureContent.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
        _ = try await recorder.stop()
        let rect = try #require(recorder.captureContent.last?.rect)
        #expect(abs(rect.width - 1) < 0.01 && abs(rect.height - 0.5) < 0.01)
    }

    @Test func captureMetadataConvertsRetinaSizesAndRejectsInvalidBounds() throws {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let info: [SCStreamFrameInfo: Any] = [.contentRect: rect.dictionaryRepresentation, .scaleFactor: 2.0, .contentScale: 0.5]
        let crop = try #require(ScreenRecorder.contentRect(attachments: info, width: 800, height: 600))
        #expect(crop.x == 10.0 / 800 && crop.y == 20.0 / 600)
        #expect(crop.width == 0.5 && crop.height == 1.0 / 3)
        #expect(ScreenRecorder.contentRect(attachments: [:], width: 800, height: 600) == nil)
        #expect(ScreenRecorder.contentRect(attachments: info, width: 0, height: 600) == nil)
    }

    @Test func resizedWindowPaddingIsAbsentFromPreviewAndExport() async throws {
        let url = fixtureURL("window-resize")
        var doc = ProjectDocument(
            name: "Resize", media: MediaInfo(screen: "media/screen.mov", width: 320, height: 360, scale: 1, duration: 2, frameRate: 15))
        doc = try OperationApplier.apply(fullBleed, to: doc)
        var log = EventLog()
        log.windowFrames = [
            WindowFrameSample(t: 0, x: 0, y: 0, width: 320, height: 360), WindowFrameSample(t: 1, x: 0, y: 0, width: 640, height: 360),
        ]
        log.pointer = [PointerSample(t: -0.1, x: 0.5, y: 0.5), PointerSample(t: 2, x: 0.5, y: 0.5)]
        let bundle = try ProjectBundle.create(at: url, document: doc, events: log)
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticProject.writeVideo(to: bundle.resolve(doc.media.screen), duration: 2, width: 320, height: 360, fps: 15) {
            ctx, t, w, h in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            // CGContext is bottom-left; after the resize, content occupies the encoded frame's top half.
            ctx.fill(CGRect(x: 0, y: t < 1 ? 0 : h / 2, width: w, height: t < 1 ? h : h / 2))
        }
        let comp = try await EditComposition.build(bundle: bundle, document: doc, width: 320, height: 360)
        let r = comp.plan.contentRect(outputTime: 1.5)
        #expect(abs(r.height - 0.5) < 0.01)
        let inside = CGRect(x: r.x + 0.05, y: r.y + r.height * 0.65, width: r.width * 0.25, height: r.height * 0.25)
        let preview = try await Frames.image(comp, at: 1.5)
        let fraction = colorPresence(preview, RGBA(1, 0, 0), in: inside).fraction
        #expect(fraction > 0.95)
        let p = NormPoint(0.25, 0.75)
        let back = comp.plan.shotPoint(forView: comp.plan.viewPoint(p, outputTime: 1.5), outputTime: 1.5)
        #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
        doc.style.cursor.visible = true
        doc.style.cursor.appearance = .arrow
        doc.style.cursor.hideAfterIdle = 0
        doc.style.cursor.scale = 3
        let withCursor = try await EditComposition.build(bundle: bundle, document: doc, width: 320, height: 360)
        let cursorPreview = try await Frames.image(withCursor, at: 1.5)
        #expect(!withCursor.plan.cursor.isEmpty)
        #expect(
            meanAbsDiff(preview, cursorPreview) > 0.0005,
            "Enabling the cursor must change actual preview pixels, even with pre-roll samples.")
        let out = bundle.rendersURL.appendingPathComponent("resized.mp4")
        _ = try await Exporter.export(
            bundle: bundle, document: doc, variant: RenderVariant(name: "resize", aspect: .auto, size: 320, fps: 15), to: out)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        #expect(colorPresence(image, RGBA(1, 0, 0), in: inside).fraction > 0.95)
        #expect(meanAbsDiff(image, cursorPreview) < 0.005, "The export must include the same cursor and resized content as the preview.")
    }
}
