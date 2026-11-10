import Foundation
import Testing
import CoreGraphics
import CoreMedia
import CoreVideo
import AVFoundation
@testable import GlintCore
@testable import GlintCapture
@testable import GlintAgent

// Exercises the capture writers exactly as ScreenRecorder configures them (TrackWriter: fragmented movies, the same
// HEVC/AAC settings), fed with synthetic frames and audio stamped like ScreenCaptureKit's host-clock samples.

private let width = 320, height = 240, fps = 30

/// A flat grey BGRA frame (`shade` 0–255) presented at `pts`.
private func frame(shade: UInt8, pts: CMTime) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    let base = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(p)
    for y in 0..<height { for x in 0..<width { let i = y * row + x * 4; base[i] = shade; base[i + 1] = shade; base[i + 2] = shade; base[i + 3] = 255 } }
    CVPixelBufferUnlockBaseAddress(p, [])
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: p, formatDescriptionOut: &fmt)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: p, formatDescription: fmt!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}

/// 1024 frames of a mono 440 Hz tone (float PCM, 48 kHz) presented at `pts`.
private func tone(pts: CMTime, startFrame: Int64) -> CMSampleBuffer {
    let n = 1024
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                       dataLength: n * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    let samples = (0..<n).map { Float(sin(Double(startFrame + Int64($0)) * 2 * .pi * 440 / 48000) * 0.3) }
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: n, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

private func screenWriter(_ url: URL) throws -> TrackWriter {
    let settings = ScreenRecorder.videoSettings(width: width, height: height, bitrate: ScreenRecorder.videoBitrate(pixelWidth: width, pixelHeight: height, frameRate: fps), frameRate: fps)
    return try TrackWriter(url: url, fileType: .mov, input: AVAssetWriterInput(mediaType: .video, outputSettings: settings))
}

private func micWriter(_ url: URL) throws -> TrackWriter {
    try TrackWriter(url: url, fileType: .m4a, input: AVAssetWriterInput(mediaType: .audio, outputSettings: ScreenRecorder.audioSettings(channels: 1, bitrate: ScreenRecorder.microphoneBitrate)))
}

/// Appends like a live source: waits for the writer to be ready (a real-time input drops when it isn't).
private func feed(_ w: TrackWriter, _ sb: CMSampleBuffer, shift: CMTime = .zero) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !w.input.isReadyForMoreMediaData && Date() < deadline { usleep(500) }
    return w.append(sb, shift: shift)
}

private func playableSeconds(_ url: URL, video: Bool) async -> Double {
    await GlintService.probe(url, video: video)?.duration ?? 0
}

/// A process that has exited (and been reaped): its PID belongs to nobody.
private func deadPID() throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run(); p.waitUntilExit()
    return p.processIdentifier
}

private func journal(for b: ProjectBundle, pid: Int32, processStartedAt: Double?, elapsed: Double) -> RecordingJournal {
    let info = RecordingInfo(startedAt: Date(), source: "display:1", sourceName: "Test Display", displayFrame: [0, 0, 1600, 1200], recordedBy: Author(.agent, "test-agent"), inputTracking: "poll")
    var j = RecordingJournal(pid: pid, processStartedAt: processStartedAt, processName: "glint", startedAt: Date(),
                             media: MediaInfo(screen: "media/screen.mov", microphone: "media/mic.m4a", width: width, height: height, scale: 2, duration: 0, frameRate: Double(fps)),
                             recording: info, options: nil)
    j.elapsed = elapsed
    return j
}

@Suite(.serialized) struct CaptureReliabilityTests {
    /// A take whose process dies mid-recording: the files on disk are partial fragmented movies (never finished) and
    /// the last events checkpoint. Recovery must read them and produce a normal, renderable project.
    @Test func interruptedTakeIsRecoveredFromFragments() async throws {
        let fm = FileManager.default
        let projects = fm.temporaryDirectory.appendingPathComponent("glint-recovery-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: projects) }
        let placeholder = ProjectDocument(name: "x", media: MediaInfo(screen: "media/screen.mov", width: width, height: height, scale: 2, duration: 0, frameRate: Double(fps)))
        let live = try ProjectBundle.create(at: projects.appendingPathComponent("Abandoned.glint"), document: placeholder, events: EventLog())
        let snapshot = try ProjectBundle.create(at: projects.appendingPathComponent("Copied mid-write.glint"), document: placeholder, events: EventLog())

        // Record ~8 s into the live bundle with the production writer configuration.
        let screen = try screenWriter(live.mediaURL.appendingPathComponent("screen.mov"))
        let mic = try micWriter(live.mediaURL.appendingPathComponent("mic.m4a"))
        let t0 = CMTime(seconds: 7_000, preferredTimescale: 1_000_000_000)     // a host-clock-like start
        screen.start(at: t0); mic.start(at: t0)
        var audioFrame: Int64 = 0
        func record(until seconds: Double, from startIndex: Int) -> Int {
            var i = startIndex
            while Double(i) / Double(fps) < seconds {
                let t = CMTimeAdd(t0, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
                _ = feed(screen, frame(shade: UInt8(i % 200 + 30), pts: t))
                while Double(audioFrame) / 48000 < Double(i + 1) / Double(fps) {
                    _ = feed(mic, tone(pts: CMTimeAdd(t0, CMTime(value: audioFrame, timescale: 48000)), startFrame: audioFrame))
                    audioFrame += 1024
                }
                i += 1
            }
            return i
        }
        var next = record(until: 5.2, from: 0)
        // Mid-write: copy what's on disk while the writers are still open (as a crash at this instant would leave it).
        var copied = 0.0
        let deadline = Date().addingTimeInterval(10)
        repeat {
            try? await Task.sleep(nanoseconds: 200_000_000)
            for name in ["screen.mov", "mic.m4a"] {
                let dst = snapshot.mediaURL.appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: live.mediaURL.appendingPathComponent(name), to: dst)
            }
            copied = await playableSeconds(snapshot.mediaURL.appendingPathComponent("screen.mov"), video: true)
        } while copied < 3.9 && Date() < deadline
        #expect(copied >= 3.9, "a 5 s take should have its 2 s and 4 s fragments on disk, got \(copied) s")
        #expect(screen.writer.status == .writing)       // still mid-write
        next = record(until: 8.2, from: next)
        try? await Task.sleep(nanoseconds: 600_000_000)
        // The live writers are now abandoned without finishWriting: the process "died".
        #expect(await playableSeconds(live.mediaURL.appendingPathComponent("screen.mov"), video: true) >= 5.9)

        // What the recorder had checkpointed: input up to ~8 s, plus things the partial movie can't show.
        var events = EventLog()
        events.pointer = stride(from: 0.0, through: 8.0, by: 0.1).map { PointerSample(t: $0, x: $0 / 8, y: 0.5) }
        events.clicks = [ClickEvent(t: 1.0, x: 0.2, y: 0.4, up: 1.1, target: "Save"), ClickEvent(t: 3.0, x: 0.6, y: 0.4, up: 3.1), ClickEvent(t: 7.5, x: 0.9, y: 0.9)]
        events.keys = [KeyEvent(t: 2), KeyEvent(t: 2.1), KeyEvent(t: 7.9)]
        events.markers = [Marker(time: 0.5, note: "start", author: .app), Marker(time: 7.8, note: "late", author: .app)]
        events.pauses = [PauseRecord(at: 1.5, duration: 4)]
        for b in [live, snapshot] { try JSONCoding.compactEncoder.encode(events).write(to: RecordingJournal.checkpointURL(in: b)) }
        let dead = try deadPID()
        try journal(for: snapshot, pid: dead, processStartedAt: nil, elapsed: 5.2).write(snapshot)
        // Same PID as a running process but a different start time: a reused PID, so the owner is gone too.
        let parent = getppid()
        try journal(for: live, pid: parent, processStartedAt: (OwnerProcess.startTime(pid: parent) ?? 0) - 1000, elapsed: 8.2).write(live)
        // A take whose recorder is genuinely alive is never offered.
        let running = try ProjectBundle.create(at: projects.appendingPathComponent("Still recording.glint"), document: placeholder, events: EventLog())
        try journal(for: running, pid: parent, processStartedAt: OwnerProcess.startTime(pid: parent), elapsed: 3).write(running)

        let service = GlintService()
        let found = service.recoverableRecordings(in: projects, includeStale: false)
        #expect(Set(found.map(\.project)) == [live.url.path, snapshot.url.path])
        #expect(found.first { $0.project == snapshot.url.path }?.files["media/screen.mov"] ?? 0 > 1000)
        await #expect(throws: ServiceError.self) { _ = try await service.recover(running) }

        // Recover the mid-write copy.
        let r = try await service.recover(snapshot)
        #expect(r.duration >= 3.9 && r.duration <= 5.3)
        #expect(r.tracks.contains("screen") && r.tracks.contains("microphone"))
        #expect(r.notes.contains { $0.contains("lost") })          // ~1 s after the last fragment didn't make it
        let doc = try snapshot.readDocument()
        #expect(doc.media.duration == r.duration && doc.media.width == width && doc.media.height == height)
        #expect(doc.media.microphone == "media/mic.m4a" && doc.recording?.recordedBy == Author(.agent, "test-agent"))
        let ev = snapshot.readEvents()
        #expect(ev.clicks.map(\.t) == [1.0, 3.0])                   // the 7.5 s click is past the movie
        #expect(ev.keys.count == 2 && ev.markers.map(\.note) == ["start"])
        #expect(ev.pointer.allSatisfy { $0.t <= r.duration } && ev.pointer.count > 30)
        #expect(doc.timeline.markers.map(\.note) == ["start"])
        let j = try #require(RecordingJournal.read(snapshot))
        #expect(j.status == .recovered && j.notes == r.notes)
        #expect(!fm.fileExists(atPath: RecordingJournal.checkpointURL(in: snapshot).path))
        // A normal project now: summary, and a rendered frame from the partial movie.
        let summary = try service.summary(snapshot)
        #expect(summary.sourceDuration == r.duration && summary.counts["clicks"] == 2)
        let png = try await service.renderFrame(snapshot, time: 1.0, proposal: nil, variant: nil, maxWidth: 320)
        #expect((try fm.attributesOfItem(atPath: png.path)[.size] as? Int ?? 0) > 1000)
        await #expect(throws: ServiceError.self) { _ = try await service.recover(snapshot) }      // already recovered

        // Recover the abandoned original through the tool, as an agent would.
        let out = try await ToolRegistry.call("glint_recover_recordings", arguments: .object(["action": .string("recover"), "project": .string(live.url.path)]),
                                              context: ToolContext(author: Author(.agent, "test"), service: service))
        let rec = try #require(out.json["recovered"]?.arrayValue?.first)
        #expect(rec.str("error") == nil)
        #expect((rec.num("duration") ?? 0) >= 5.9)
        let liveDuration = rec.num("duration") ?? 0
        #expect(live.readEvents().clicks.count == events.clicks.filter { $0.t <= liveDuration }.count)
        #expect(service.recoverableRecordings(in: projects, includeStale: false).isEmpty)
        _ = next
    }

    /// Pausing cuts every track at the same instant: samples taken while paused are dropped and later ones restamped,
    /// so the movie and audio are gapless, the same length, and resume on what came after the pause.
    @Test func pausedSamplesAreDroppedAndLaterOnesRetimed() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glint-pause-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let screen = try screenWriter(dir.appendingPathComponent("screen.mov"))
        let mic = try micWriter(dir.appendingPathComponent("mic.m4a"))
        let clock = PauseClock()
        let base = 9_000.0
        let t0 = CMTime(seconds: base, preferredTimescale: 1_000_000_000)
        screen.start(at: t0); mic.start(at: t0)
        var audioFrame: Int64 = 0
        var dropped = 0
        for i in 0..<(6 * fps) {
            let host = base + Double(i) / Double(fps)
            if i == 2 * fps { clock.pause(at: host) }            // paused from 2 s…
            if i == 4 * fps { clock.resume(at: host) }           // …to 4 s
            let pts = CMTime(seconds: host, preferredTimescale: 1_000_000_000)
            if let shift = clock.shift(for: pts) { _ = feed(screen, frame(shade: UInt8(min(250, i + 20)), pts: pts), shift: shift) } else { dropped += 1 }
            while Double(audioFrame) / 48000 < Double(i + 1) / Double(fps) {
                let apts = CMTimeAdd(t0, CMTime(value: audioFrame, timescale: 48000))
                if let shift = clock.shift(for: apts) { _ = feed(mic, tone(pts: apts, startFrame: audioFrame), shift: shift) }
                audioFrame += 1024
            }
        }
        #expect(dropped == 2 * fps)
        let end = clock.collapse(CMTime(seconds: base + 6, preferredTimescale: 1_000_000_000))
        #expect(abs(end.seconds - (base + 4)) < 1e-6)
        await screen.finish(at: end)
        await mic.finish(at: end)
        #expect(screen.writer.status == .completed && mic.writer.status == .completed)

        let movie = AVURLAsset(url: dir.appendingPathComponent("screen.mov"))
        #expect(abs(try await movie.load(.duration).seconds - 4) < 0.1)
        let audio = AVURLAsset(url: dir.appendingPathComponent("mic.m4a"))
        #expect(abs(try await audio.load(.duration).seconds - 4) < 0.1)
        // Frames are evenly spaced (no gap at the cut), and the frame at the cut is the one taken at 4 s.
        let track = try #require(try await movie.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        var shadeAfterCut: Int?
        while let sb = output.copyNextSampleBuffer() {
            let t = sb.presentationTimeStamp.seconds
            if shadeAfterCut == nil, t >= 2 - 1e-6, let px = CMSampleBufferGetImageBuffer(sb) {
                CVPixelBufferLockBaseAddress(px, .readOnly)
                let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
                shadeAfterCut = Int(p[CVPixelBufferGetBytesPerRow(px) * (height / 2) + (width / 2) * 4 + 1])
                CVPixelBufferUnlockBaseAddress(px, .readOnly)
            }
            times.append(t)
        }
        #expect(abs(times.count - 4 * fps) <= 1)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 > 0 && $0 < 1.5 / Double(fps) }, "largest gap \(gaps.max() ?? 0)")
        // Before the pause shades run 20…79; the first frame after the cut was taken at 4 s (shade 140).
        let shade = try #require(shadeAfterCut)
        #expect(abs(shade - 140) < 12, "frame at the cut has shade \(shade)")
    }

    /// Preflight finds problems before anything is recorded, and starting refuses on a hard failure.
    @Test func preflightReportsAndBlocksHardFailures() async throws {
        let service = GlintService()
        var o = RecordingOptions()
        o.directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-preflight-\(UUID().uuidString.prefix(6))").path
        o.maxDuration = 30
        defer { try? FileManager.default.removeItem(atPath: o.directory!) }
        let r = await service.preflight(o)
        #expect(Set(r.checks.map(\.id)).isSuperset(of: ["screen_recording", "source", "folder", "disk"]))
        #expect(r.checks.first { $0.id == "folder" }?.verdict == .pass)
        #expect(r.estimatedBytesPerMinute > 0 && r.estimatedBytes != nil)
        if !Sources.hasScreenRecordingPermission { #expect(!r.ok && r.failures.contains { $0.id == "screen_recording" && $0.fix != nil }) }

        var bad = o
        bad.directory = "/System/glint-preflight-test"            // not writable
        bad.camera = true; bad.cameraID = "no-such-camera"
        let rb = await service.preflight(bad)
        #expect(!rb.ok)
        #expect(rb.checks.first { $0.id == "folder" }?.verdict == .fail)
        #expect(rb.checks.first { $0.id == "camera" }?.verdict == .fail)
        // record_start runs the same checks first: nothing is recorded, and the reason and fix come back.
        let refused = await #expect(throws: ServiceError.self) {
            _ = try await service.startRecording(options: bad, author: .app, approvalID: nil)
        }
        #expect(refused.map { "\($0)".contains("Can't start recording") && "\($0)".contains("Projects folder") } == true)
        let tool = try await ToolRegistry.call("glint_record_preflight", arguments: .object(["directory": .string(bad.directory!)]),
                                               context: ToolContext(author: Author(.agent, "test"), service: service))
        #expect(tool.json.flag("ok") == false)
    }

    @Test func pauseAndResumeNeedALiveTake() async throws {
        let service = GlintService()
        #expect(throws: ServiceError.self) { try service.pauseRecording(nil) }
        let ctx = ToolContext(author: Author(.agent, "test"), service: service)
        await #expect(throws: ServiceError.self) { _ = try await ToolRegistry.call("glint_record_pause", arguments: .object([:]), context: ctx) }
        await #expect(throws: ServiceError.self) { _ = try await ToolRegistry.call("glint_record_resume", arguments: .object([:]), context: ctx) }
        #expect(CaptureBroker.forwardedTools.isSuperset(of: ["glint_record_pause", "glint_record_resume", "glint_record_preflight"]))
        #expect(ToolRegistry.find("glint_recover_recordings")?.risk == .reversible)
        #expect(ToolRegistry.find("record_preflight")?.risk == .read)
    }
}
