import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import GlintCore

public struct RecordingOptions: Codable, Hashable, Sendable {
    public var displayID: UInt32?
    public var windowID: UInt32?
    public var frameRate: Int = 60
    public var systemAudio: Bool = true
    public var microphone: Bool = false
    /// Record the camera too (`media/camera.mov`), drawn as a facecam bubble in the edit.
    public var camera: Bool = false
    /// Camera to use (`Cameras.list()`); nil = the system's preferred camera.
    public var cameraID: String?
    /// Bake the system cursor into the video. Off by default: Glint redraws a smooth, scalable cursor.
    public var showCursor: Bool = false
    /// "system" (poll the real cursor) or "agent" (cursor path from reported agent actions).
    public var pointer: String = "system"
    /// Stop automatically after this many seconds (nil = until stopped).
    public var maxDuration: Double?
    public var projectName: String?
    /// Folder for the new project (default ~/Movies/Glint).
    public var directory: String?
    public init() {}
}

/// One output file fed with sample buffers from the stream.
///
/// Files are written as fragmented movies (a fragment every `fragmentInterval` of media time), so a take interrupted
/// by a crash or a forced quit stays readable up to its last fragment; see `GlintService.recover`.
final class TrackWriter {
    static let fragmentInterval = CMTime(seconds: RecordingJournal.checkpointInterval, preferredTimescale: 600)
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var appended = 0
    private(set) var lastPTS: CMTime = .invalid
    private var lastEnd: CMTime = .invalid
    private var lastShift: CMTime = .zero
    private var failureReported = false

    init(url: URL, fileType: AVFileType, input: AVAssetWriterInput) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.movieFragmentInterval = Self.fragmentInterval
        input.expectsMediaDataInRealTime = true
        self.input = input
        guard writer.canAdd(input) else { throw CaptureError.failed("can't add input for \(url.lastPathComponent)") }
        writer.add(input)
    }
    func start(at t: CMTime) {
        guard !started else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: t)
        started = true
    }

    /// Appends `sb` moved `shift` earlier (the time paused before it). Returns false when the sample was dropped.
    @discardableResult
    func append(_ sb: CMSampleBuffer, shift: CMTime = .zero) -> Bool {
        guard started, writer.status == .writing, input.isReadyForMoreMediaData, let out = retimed(sb, by: shift) else { return false }
        let pts = out.presentationTimeStamp
        if lastPTS.isValid {
            // Never step backwards (the writer would fail the whole file), and across a pause cut drop an audio buffer
            // that would overlap the one before the cut.
            if CMTimeCompare(pts, lastPTS) <= 0 { return false }
            if CMTimeCompare(shift, lastShift) != 0, lastEnd.isValid, CMTimeCompare(pts, lastEnd) < 0 { return false }
        }
        guard input.append(out) else { return false }
        appended += 1
        lastPTS = pts
        lastShift = shift
        let d = CMSampleBufferGetDuration(out)
        lastEnd = d.isValid && d.seconds > 0 ? CMTimeAdd(pts, d) : pts
        return true
    }

    var isFailed: Bool { writer.status == .failed }

    /// The writer's error the first time it is seen failed (so it is reported once).
    func takeFailure() -> Error? {
        guard !failureReported, writer.status == .failed else { return nil }
        failureReported = true
        return writer.error ?? CaptureError.failed("\(url.lastPathComponent) stopped writing")
    }

    func finish(at end: CMTime?) async {
        guard started else { writer.cancelWriting(); return }
        guard writer.status == .writing else { return }      // failed: what was written is left as fragments
        input.markAsFinished()
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
    }
}

/// ScreenCaptureKit stream → H.264/HEVC movie + AAC audio files, with timestamps on the host clock.
///
/// While the shared `PauseClock` is paused, frames and audio are dropped; afterwards they are restamped earlier by the
/// time spent paused, so the files are gapless. The newest frame seen during a pause is shown at the cut, so the take
/// resumes on the current screen even when nothing changes after resuming.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "glint.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "glint.capture.audio", qos: .userInteractive)
    private var video: TrackWriter?
    private var system: TrackWriter?
    private var mic: TrackWriter?
    private var firstPTS: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var lastPTS: CMTime = .zero
    /// Newest frame delivered while paused (shown at the cut on resume).
    private var pausedFrame: CMSampleBuffer?
    public private(set) var frameCount = 0
    public var onFirstFrame: ((Double) -> Void)?
    /// The stream stopped or the screen movie stopped writing: the take can't continue (finalize what exists).
    public var onError: ((Error) -> Void)?
    /// Something was lost but the take goes on (an audio track stopped writing).
    public var onWarning: ((String) -> Void)?
    private let lock = NSLock()
    public private(set) var streamError: Error?
    /// Host time the movie ends at (set by `stop`, gapless), so other tracks can end with it.
    public private(set) var endTime: CMTime?
    public let clock: PauseClock

    public let urls: (screen: URL, system: URL?, mic: URL?)
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let videoBitrate: Double

    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    /// Bits per second of the HEVC screen movie for a capture size and frame rate.
    public static func videoBitrate(pixelWidth: Int, pixelHeight: Int, frameRate: Int) -> Double {
        let bitsPerPixel = 0.12
        return min(80_000_000, max(6_000_000, Double(pixelWidth * pixelHeight) * Double(max(1, frameRate)) * bitsPerPixel))
    }
    public static let systemAudioBitrate = 192_000.0
    public static let microphoneBitrate = 128_000.0

    public init(filter: SCContentFilter, pixelWidth: Int, pixelHeight: Int, options: RecordingOptions, mediaDirectory: URL, clock: PauseClock = PauseClock()) throws {
        self.filter = filter
        self.clock = clock
        self.pixelWidth = pixelWidth - pixelWidth % 2
        self.pixelHeight = pixelHeight - pixelHeight % 2
        let c = SCStreamConfiguration()
        c.width = self.pixelWidth
        c.height = self.pixelHeight
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.frameRate)))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = options.showCursor
        c.queueDepth = 8
        c.capturesAudio = options.systemAudio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48000
        c.channelCount = 2
        if options.microphone { c.captureMicrophone = true }
        self.config = c

        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let screenURL = mediaDirectory.appendingPathComponent("screen.mov")
        let sysURL = options.systemAudio ? mediaDirectory.appendingPathComponent("system.m4a") : nil
        let micURL = options.microphone ? mediaDirectory.appendingPathComponent("mic.m4a") : nil
        urls = (screenURL, sysURL, micURL)

        videoBitrate = Self.videoBitrate(pixelWidth: self.pixelWidth, pixelHeight: self.pixelHeight, frameRate: options.frameRate)
        video = try TrackWriter(url: screenURL, fileType: .mov, input: AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: self.pixelWidth, height: self.pixelHeight, bitrate: videoBitrate, frameRate: options.frameRate)))
        if let sysURL { system = try TrackWriter(url: sysURL, fileType: .m4a, input: AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 2, bitrate: Self.systemAudioBitrate))) }
        if let micURL { mic = try TrackWriter(url: micURL, fileType: .m4a, input: AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitrate: Self.microphoneBitrate))) }
        super.init()
        clock.observe { [weak self] paused in if !paused { self?.showLatestFrameAtCut() } }
    }

    /// AAC settings of the system audio (stereo) and microphone (mono) files.
    static func audioSettings(channels: Int, bitrate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: Int(bitrate)]
    }

    /// The screen movie's writer settings (also used by tests that exercise recovery with the same configuration).
    static func videoSettings(width: Int, height: Int, bitrate: Double, frameRate: Int) -> [String: Any] {
        [
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
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    }

    public func start() async throws {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if system != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if mic != nil { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue) }
        stream = s
        do { try await s.startCapture() } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    /// Stop and finalize. Returns the recorded duration (first frame → stop, paused time excluded). Audio tracks that
    /// failed along the way are reported through `onWarning`; only a screen movie that can't be finished throws.
    public func stop() async throws -> Double {
        let stopHost = CMClockGetTime(CMClockGetHostTimeClock())
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        // Drain the queues.
        await withCheckedContinuation { c in videoQueue.async { c.resume() } }
        await withCheckedContinuation { c in audioQueue.async { c.resume() } }
        let (first, last, lastT) = lock.withLock { (firstPTS, lastVideo, lastPTS) }
        guard let first else {
            await video?.finish(at: nil); await system?.finish(at: nil); await mic?.finish(at: nil)
            throw CaptureError.failed(streamError.map { "\($0.localizedDescription)" } ?? "no frames were captured")
        }
        // ScreenCaptureKit only sends frames when the screen changes; repeat the last frame at the stop time so the
        // movie covers the whole recording, including a static ending. Stopped while paused: the take ends at the cut.
        var end = clock.collapse(stopHost)
        if CMTimeCompare(end, lastT) <= 0 { end = CMTimeAdd(lastT, CMTime(value: 1, timescale: 60)) }
        if let last, let v = video, let copy = retimed(last, to: end) { v.append(copy) }
        endTime = end
        await video?.finish(at: end)
        await system?.finish(at: end)
        await mic?.finish(at: end)
        reportWriterFailures()
        if let v = video, v.isFailed {
            throw CaptureError.failed("the screen movie couldn't be finished: \(v.writer.error?.localizedDescription ?? "unknown error")")
        }
        return CMTimeSubtract(end, first).seconds
    }

    /// On resume: put the newest frame seen while paused at the cut, so the take continues on the current screen.
    private func showLatestFrameAtCut() {
        videoQueue.async { [self] in
            lock.lock()
            guard let frame = pausedFrame, firstPTS != nil else { pausedFrame = nil; lock.unlock(); return }
            pausedFrame = nil
            let cutHost = clock.snapshot.intervals.last?.end ?? hostSeconds()
            let cut = clock.collapse(CMTime(seconds: cutHost, preferredTimescale: 1_000_000_000))
            guard CMTimeCompare(cut, lastPTS) > 0, let copy = retimed(frame, to: cut) else { lock.unlock(); return }
            lastVideo = copy
            lastPTS = cut
            frameCount += 1
            lock.unlock()
            video?.append(copy)
        }
    }

    private func reportWriterFailures() {
        if let e = system?.takeFailure() { onWarning?("System audio stopped recording partway: \(e.localizedDescription)") }
        if let e = mic?.takeFailure() { onWarning?("The microphone track stopped recording partway: \(e.localizedDescription)") }
        if let e = video?.takeFailure() { onError?(CaptureError.failed("writing the screen movie failed: \(e.localizedDescription)")) }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
                  CMSampleBufferGetImageBuffer(sb) != nil else { return }
            let pts = sb.presentationTimeStamp
            guard let shift = clock.shift(for: pts) else {
                lock.withLock { pausedFrame = sb }
                return
            }
            let t = CMTimeSubtract(pts, shift)
            lock.lock()
            if firstPTS == nil {
                firstPTS = t
                lock.unlock()
                video?.start(at: t); system?.start(at: t); mic?.start(at: t)
                onFirstFrame?(t.seconds)
                lock.lock()
            }
            guard lastVideo == nil || CMTimeCompare(t, lastPTS) > 0 else { lock.unlock(); return }
            lastVideo = sb
            lastPTS = t
            frameCount += 1
            lock.unlock()
            video?.append(sb, shift: shift)
            if let e = video?.takeFailure() { onError?(CaptureError.failed("writing the screen movie failed: \(e.localizedDescription)")) }
        case .audio, .microphone:
            lock.lock(); let ready = firstPTS != nil; lock.unlock()
            guard ready, let shift = clock.shift(for: sb.presentationTimeStamp) else { return }
            let w = type == .audio ? system : mic
            w?.append(sb, shift: shift)
            if let e = w?.takeFailure() {
                onWarning?(type == .audio ? "System audio stopped recording partway: \(e.localizedDescription)" : "The microphone track stopped recording partway: \(e.localizedDescription)")
            }
        @unknown default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamError = error; lock.unlock()
        onError?(error)
    }
}
