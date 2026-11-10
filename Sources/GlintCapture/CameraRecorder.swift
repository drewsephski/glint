import Foundation
import AVFoundation
import CoreMedia
import GlintCore

public struct CameraDevice: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
}

public enum Cameras {
    static func discovered() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    static var preferred: AVCaptureDevice? { AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) ?? discovered().first }

    /// Cameras that can be recorded, the system's preferred one first.
    public static func list() -> [CameraDevice] {
        let def = preferred?.uniqueID
        return discovered().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
            .sorted { $0.isDefault && !$1.isDefault }
    }

    /// The camera with this ID, or the system's preferred camera when no ID is given.
    public static func device(id: String?) -> AVCaptureDevice? {
        guard let id, !id.isEmpty else { return preferred }
        return discovered().first { $0.uniqueID == id }
    }

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    /// The person said no (or a profile forbids it): only System Settings can change it.
    public static var isDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    /// Asks once (macOS shows its prompt); afterwards answers from the stored decision.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// Camera → `media/camera.mov` (HEVC), on the same clock as the screen movie: time 0 is the screen's first frame, so
/// the editor can lay both tracks on one timeline without an offset.
///
/// The camera starts before the screen does and keeps only its newest frame until the screen's first frame arrives;
/// that frame becomes the camera movie's first, so the bubble is never empty at the start of a take.
///
/// Frames taken while the take's `PauseClock` is paused are dropped and later ones restamped, like the screen's. If the
/// camera is unplugged or its session fails mid-take, the take goes on: the camera movie keeps what it has, holds its
/// last picture to the end, and a warning says when it stopped.
public final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    public let url: URL
    public let device: CameraDevice
    public let clock: PauseClock?
    /// Called with a plain-language warning (camera disconnected, failed, stopped writing).
    public var onWarning: ((String) -> Void)?
    private let captureDevice: AVCaptureDevice
    private var observers: [NSObjectProtocol] = []
    private var restartedAfterError = false
    private let queue = DispatchQueue(label: "glint.capture.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var frames = 0
    private var delivering = false
    // Touched only on `queue`.
    private var writer: TrackWriter?
    private var origin: CMTime?
    private var held: CMSampleBuffer?
    private var last: CMSampleBuffer?
    private var lastPTS: CMTime = .invalid
    private var failed = false

    public var frameCount: Int { lock.withLock { frames } }
    /// Average bits per second of a 1080p camera movie (for disk estimates).
    public static let typicalBitrate = 7_000_000.0

    public init(deviceID: String?, mediaDirectory: URL, clock: PauseClock? = nil) throws {
        guard Cameras.isAuthorized else { throw CaptureError.cameraDenied }
        guard let dev = Cameras.device(id: deviceID) else { throw CaptureError.cameraNotFound(deviceID ?? "") }
        device = CameraDevice(id: dev.uniqueID, name: dev.localizedName, isDefault: deviceID == nil)
        captureDevice = dev
        self.clock = clock
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        url = mediaDirectory.appendingPathComponent("camera.mov")
        super.init()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: dev) } catch { throw CaptureError.failed("can't open \(dev.localizedName): \(error.localizedDescription)") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CaptureError.failed("can't use \(dev.localizedName)") }
        session.addInput(input)
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.failed("can't read frames from \(dev.localizedName)") }
        session.addOutput(output)
        observeFailures()
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    /// Unplugged, interrupted or failed mid-take: keep the take, say what happened.
    private func observeFailures() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: captureDevice, queue: nil) { [weak self] _ in
            self?.warn { "\($0.device.name) was disconnected\($0.takeTime.map { String(format: " at %.1f s", $0) } ?? ""); the facecam holds its last picture from there." }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            guard let self else { return }
            let err = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
            // Media services can reset under us; one restart usually brings the camera back.
            let retry = self.lock.withLock { () -> Bool in defer { self.restartedAfterError = true }; return !self.restartedAfterError }
            self.warn { "\($0.device.name) failed\($0.takeTime.map { String(format: " at %.1f s", $0) } ?? "") (\(err))\(retry ? "; Glint restarted it, so the facecam may have a short freeze." : "; the facecam holds its last picture from there.")" }
            if retry { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.warn { "\($0.device.name) was interrupted\($0.takeTime.map { String(format: " at %.1f s", $0) } ?? "") (another app may have taken it); the facecam holds its last picture until it comes back." }
        })
    }

    /// Seconds into the take of the newest camera frame (camera queue only).
    private var takeTime: Double? {
        guard let origin, lastPTS.isValid else { return nil }
        return CMTimeSubtract(lastPTS, origin).seconds
    }

    private func warn(_ message: @escaping (CameraRecorder) -> String) {
        queue.async { [weak self] in
            guard let self, self.writer != nil || self.origin != nil else { return }   // before the take: start() reports it
            self.onWarning?(message(self))
        }
    }

    /// Starts the camera and waits for its first picture (cameras take a moment to warm up; a camera that is listed
    /// but out of reach, such as an iPhone that isn't nearby, never delivers one). Nothing is written until `begin(at:)`.
    public func start() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning(); c.resume() }
        }
        guard session.isRunning else { throw CaptureError.failed("\(device.name) didn't start") }
        let deadline = Date().addingTimeInterval(4)
        while !lock.withLock({ delivering }) {
            guard Date() < deadline else {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning(); c.resume() }
                }
                throw CaptureError.failed("\(device.name) isn't sending a picture. Check that it is connected and not in use, or choose another camera.")
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// The screen's first frame arrived at `t` (host clock): the camera movie starts there.
    public func begin(at t: CMTime) {
        queue.async { if self.origin == nil { self.origin = t } }
    }

    /// Stops the camera and finalizes the movie so it ends where the screen movie ends.
    public func stop(at end: CMTime?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning(); c.resume() }
        }
        let (w, finishAt): (TrackWriter?, CMTime?) = await withCheckedContinuation { c in
            queue.async {
                var at: CMTime?
                if let end, self.writer != nil, self.lastPTS.isValid {
                    // Hold the last frame to the end of the take, as the screen movie does.
                    if CMTimeCompare(end, self.lastPTS) > 0, let last = self.last { self.append(last, at: end) }
                    at = CMTimeMaximum(end, self.lastPTS)
                }
                self.held = nil; self.last = nil
                c.resume(returning: (self.writer, at))
            }
        }
        await w?.finish(at: finishAt)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !failed, sb.isValid, let pixels = CMSampleBufferGetImageBuffer(sb) else { return }
        // Capture timestamps are on the session's clock; the screen movie is on the host clock.
        let host = CMClockGetHostTimeClock()
        var pts = sb.presentationTimeStamp
        if let clock = session.synchronizationClock, clock !== host { pts = CMSyncConvertTime(pts, from: clock, to: host) }
        if origin != nil, let clock {
            guard let shift = clock.shift(for: pts) else { return }   // paused
            pts = CMTimeSubtract(pts, shift)
        }
        guard let origin else {
            held = sb
            lock.withLock { delivering = true }
            return
        }
        if writer == nil {
            do { writer = try Self.makeWriter(url: url, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) }
            catch {
                failed = true
                onWarning?("The camera couldn't be recorded (\(error)); the take has no facecam.")
                return
            }
            writer?.start(at: origin)
            if let held, CMTimeCompare(pts, origin) > 0 { append(held, at: origin) }
            held = nil
        }
        let t = lastPTS.isValid ? pts : CMTimeMaximum(pts, origin)
        guard !lastPTS.isValid || CMTimeCompare(t, lastPTS) > 0 else { return }
        append(sb, at: t)
    }

    private func append(_ sb: CMSampleBuffer, at t: CMTime) {
        var out = sb
        if CMTimeCompare(sb.presentationTimeStamp, t) != 0 {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: t, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            out = copy
        }
        guard writer?.append(out) == true else {
            if let e = writer?.takeFailure() { onWarning?("The camera movie stopped writing\(takeTime.map { String(format: " at %.1f s", $0) } ?? "") (\(e.localizedDescription)); the facecam holds its last picture from there.") }
            return
        }
        last = out
        lastPTS = t
        lock.withLock { frames += 1 }
    }

    private static func makeWriter(url: URL, width: Int, height: Int) throws -> TrackWriter {
        let bitrate = min(16_000_000, max(3_000_000, Double(width * height) * 30 * 0.11))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        return try TrackWriter(url: url, fileType: .mov, input: AVAssetWriterInput(mediaType: .video, outputSettings: settings))
    }
}
