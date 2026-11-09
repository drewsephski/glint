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
    /// Bake the system cursor into the video. Off by default: Glint redraws a smooth, scalable cursor.
    public var showCursor: Bool = false
    /// Stop automatically after this many seconds (nil = until stopped).
    public var maxDuration: Double?
    public var projectName: String?
    /// Folder for the new project (default ~/Movies/Glint).
    public var directory: String?
    public init() {}
}

/// One output file fed with sample buffers from the stream.
final class TrackWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var appended = 0
    init(url: URL, fileType: AVFileType, input: AVAssetWriterInput) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
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
    func append(_ sb: CMSampleBuffer) {
        guard started, input.isReadyForMoreMediaData else { return }
        if input.append(sb) { appended += 1 }
    }
    func finish(at end: CMTime?) async {
        guard started else { writer.cancelWriting(); return }
        input.markAsFinished()
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
    }
}

/// ScreenCaptureKit stream → H.264/HEVC movie + AAC audio files, with timestamps on the host clock.
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
    public private(set) var frameCount = 0
    public var onFirstFrame: ((Double) -> Void)?
    public var onError: ((Error) -> Void)?
    private let lock = NSLock()
    public private(set) var streamError: Error?

    public let urls: (screen: URL, system: URL?, mic: URL?)
    public let pixelWidth: Int
    public let pixelHeight: Int

    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    public init(filter: SCContentFilter, pixelWidth: Int, pixelHeight: Int, options: RecordingOptions, mediaDirectory: URL) throws {
        self.filter = filter
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

        let bitsPerPixel = 0.12
        let bitrate = Double(self.pixelWidth * self.pixelHeight) * Double(options.frameRate) * bitsPerPixel
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: self.pixelWidth,
            AVVideoHeightKey: self.pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(80_000_000, max(6_000_000, bitrate)),
                AVVideoExpectedSourceFrameRateKey: options.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        video = try TrackWriter(url: screenURL, fileType: .mov, input: AVAssetWriterInput(mediaType: .video, outputSettings: vSettings))
        let aSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        if let sysURL { system = try TrackWriter(url: sysURL, fileType: .m4a, input: AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)) }
        if let micURL {
            let m: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
            mic = try TrackWriter(url: micURL, fileType: .m4a, input: AVAssetWriterInput(mediaType: .audio, outputSettings: m))
        }
        super.init()
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

    /// Stop and finalize. Returns the recorded duration (first frame → stop).
    public func stop() async throws -> Double {
        let stopHost = CMClockGetTime(CMClockGetHostTimeClock())
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        // Drain the queues.
        await withCheckedContinuation { c in videoQueue.async { c.resume() } }
        await withCheckedContinuation { c in audioQueue.async { c.resume() } }
        let (first, last) = lock.withLock { (firstPTS, lastVideo) }
        guard let first else {
            await video?.finish(at: nil); await system?.finish(at: nil); await mic?.finish(at: nil)
            throw CaptureError.failed(streamError.map { "\($0.localizedDescription)" } ?? "no frames were captured")
        }
        // ScreenCaptureKit only sends frames when the screen changes; repeat the last frame at the stop time so the
        // movie covers the whole recording, including a static ending.
        var end = stopHost
        if CMTimeCompare(end, lastPTS) <= 0 { end = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 60)) }
        if let last, let v = video {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy {
                v.append(copy)
            }
        }
        await video?.finish(at: end)
        await system?.finish(at: end)
        await mic?.finish(at: end)
        if let e = video?.writer.error { throw CaptureError.failed(e.localizedDescription) }
        return CMTimeSubtract(end, first).seconds
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
            lock.lock()
            if firstPTS == nil {
                firstPTS = pts
                lock.unlock()
                video?.start(at: pts); system?.start(at: pts); mic?.start(at: pts)
                onFirstFrame?(pts.seconds)
                lock.lock()
            }
            lastVideo = sb
            lastPTS = pts
            frameCount += 1
            lock.unlock()
            video?.append(sb)
        case .audio:
            lock.lock(); let ready = firstPTS != nil; lock.unlock()
            if ready { system?.append(sb) }
        case .microphone:
            lock.lock(); let ready = firstPTS != nil; lock.unlock()
            if ready { mic?.append(sb) }
        @unknown default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamError = error; lock.unlock()
        onError?(error)
    }
}
