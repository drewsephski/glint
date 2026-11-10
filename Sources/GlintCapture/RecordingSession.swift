import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import Darwin
import GlintCore

/// Live state of a take, for status tools, the HUD and the CLI.
public struct RecordingStatus: Codable, Hashable, Sendable {
    public var recording: Bool
    public var paused: Bool
    /// Seconds of take so far, paused time excluded.
    public var elapsed: Double
    public var frames: Int
    public var pauses: [PauseRecord]
    public var warnings: [String]
    /// Why the take ended early, when it did (capture stopped, the screen movie stopped writing).
    public var error: String?
    /// "stopped", "time_limit" or "capture_error" once the take has ended.
    public var endReason: String?
}

/// Records a display or window into a new `.glint` project: screen video, audio tracks, input events and cursor images.
///
/// Reliability:
/// - **Pause/resume**: one `PauseClock` is shared by the screen, audio, camera and input tracks, so a pause cuts all of
///   them at the same instant and the files come out gapless and in sync. Pauses are listed in `events.json`.
/// - **Crash safety**: media is written as fragmented movies (a fragment every 2 s) and `recording.json` plus an events
///   checkpoint are rewritten every 2 s, so an interrupted take can be recovered (`GlintService.recover`).
/// - **Device problems**: a camera that disconnects or fails, or an audio track that stops writing, is a warning and the
///   take goes on; if the screen capture itself stops, what exists is finalized and the error is reported.
public final class RecordingSession: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let options: RecordingOptions
    public let source: CaptureSource
    /// Shared by every track of this take.
    public let clock: PauseClock
    private let recorder: ScreenRecorder
    private let tracker: InputTracker
    private let camera: CameraRecorder?
    public let author: Author
    private let startedAt = Date()
    private let state = NSLock()
    private var _isRecording = false
    private var _warnings: [String] = []
    private var _error: String?
    private var _endReason: String?
    private var firstFrameHost: Double?
    private var startHost: Double = 0
    private var autoStop: Task<Void, Never>?
    private var stopTask: Task<ProjectBundle, Error>?
    private var checkpointTimer: DispatchSourceTimer?
    private let journalQueue = DispatchQueue(label: "glint.capture.journal", qos: .utility)
    private var journal: RecordingJournal?

    public var isRecording: Bool { state.withLock { _isRecording } }
    public var isPaused: Bool { clock.isPaused }
    /// Plain-language problems so far (camera disconnected, an audio track stopped, …). The take itself is intact.
    public var warnings: [String] { state.withLock { _warnings } }
    /// The error that ended the take early, if one did.
    public var error: String? { state.withLock { _error } }
    public var endReason: String? { state.withLock { _endReason } }
    /// The pauses so far, as the finished take will show them.
    public var pauses: [PauseRecord] {
        let tl = clock.snapshot
        let origin = state.withLock { firstFrameHost } ?? tl.collapse(startHost)
        return tl.records(origin: origin)
    }

    /// Called after the take ended on its own (time limit reached, capture stopped), with the finalized project.
    public var onAutoStop: ((Result<ProjectBundle, Error>) -> Void)?
    /// For the owning service: called with the same result as `onAutoStop`, before it.
    public var onEnded: ((Result<ProjectBundle, Error>) -> Void)?
    /// Called on the main queue when the take pauses (true) or resumes (false).
    public var onPauseChange: ((Bool) -> Void)?
    /// The running camera, for a live preview while recording. Nil when the take has no camera.
    public var cameraSession: AVCaptureSession? { camera?.session }

    private static func makeCamera(_ options: RecordingOptions, bundle: ProjectBundle, clock: PauseClock) throws -> CameraRecorder? {
        guard options.camera else { return nil }
        return try CameraRecorder(deviceID: options.cameraID, mediaDirectory: bundle.mediaURL, clock: clock)
    }

    public static func makeProjectURL(name: String?, directory: String?) -> URL {
        let dir = directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? GlintPaths.projects
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = (name?.isEmpty == false ? name! : "Recording \(f.string(from: Date())))").replacingOccurrences(of: "/", with: "-")
        var url = dir.appendingPathComponent(base).appendingPathExtension(ProjectBundle.pathExtension)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(i)").appendingPathExtension(ProjectBundle.pathExtension); i += 1
        }
        return url
    }

    /// Checks the devices a take needs before anything is created, so a missing permission or camera is a clear
    /// error instead of a half-made project. Asks for microphone/camera access the first time.
    public static func checkDevices(_ options: RecordingOptions, askIfNeeded: Bool = true) async throws {
        if options.microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                if askIfNeeded { guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.microphoneDenied } }
            default: throw CaptureError.microphoneDenied
            }
        }
        if options.camera {
            if askIfNeeded { guard await Cameras.requestAccess() else { throw CaptureError.cameraDenied } }
            else if Cameras.isDenied { throw CaptureError.cameraDenied }
            if Cameras.device(id: options.cameraID) == nil { throw CaptureError.cameraNotFound(options.cameraID ?? "") }
        }
    }

    public convenience init(options: RecordingOptions, author: Author) async throws {
        try await Self.checkDevices(options)
        let content = try await Sources.shareable()
        let sources = try await Sources.list()
        let filter: SCContentFilter
        let src: CaptureSource
        if let wid = options.windowID {
            guard let w = content.windows.first(where: { $0.windowID == wid }), let s = sources.first(where: { $0.kind == .window && $0.id == wid }) else {
                throw CaptureError.sourceNotFound("window \(wid)")
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            src = s
        } else {
            let did = options.displayID ?? CGMainDisplayID()
            guard let d = content.displays.first(where: { $0.displayID == did }), let s = sources.first(where: { $0.kind == .display && $0.id == did }) else {
                throw CaptureError.sourceNotFound("display \(did)")
            }
            // Exclude Glint's own windows (recording HUD) from the capture.
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            src = s
        }
        try self.init(filter: filter, source: src, width: src.pixelWidth, height: src.pixelHeight,
                      windowID: options.windowID.map { CGWindowID($0) }, options: options, author: author)
    }

    /// Record content the user chose in the system picker (`SCContentSharingPicker`). Using the picker avoids macOS's
    /// periodic "bypass the private window picker" confirmation for user-initiated recordings.
    public convenience init(filter: SCContentFilter, options: RecordingOptions, author: Author) throws {
        if options.microphone {
            let s = AVCaptureDevice.authorizationStatus(for: .audio)
            if s == .denied || s == .restricted { throw CaptureError.microphoneDenied }
        }
        if options.camera, Cameras.device(id: options.cameraID) == nil { throw CaptureError.cameraNotFound(options.cameraID ?? "") }
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        let kind: CaptureSource.Kind = filter.style == .window ? .window : .display
        let src = CaptureSource(kind: kind, id: 0, name: kind == .window ? "Window" : "Display", app: nil, bundleID: nil,
                                frame: [rect.origin.x, rect.origin.y, rect.width, rect.height], pixelWidth: width, pixelHeight: height, scale: scale, isMain: nil)
        // The picker doesn't say which window was chosen, so its frame can't be followed if it moves.
        try self.init(filter: filter, source: src, width: width, height: height, windowID: nil, options: options, author: author)
    }

    private init(filter: SCContentFilter, source src: CaptureSource, width: Int, height: Int, windowID: CGWindowID?,
                 options: RecordingOptions, author: Author) throws {
        self.options = options
        self.author = author
        self.source = src
        let clock = PauseClock()
        self.clock = clock
        let url = Self.makeProjectURL(name: options.projectName, directory: options.directory)
        let placeholder = ProjectDocument(name: url.deletingPathExtension().lastPathComponent,
                                          media: MediaInfo(screen: "media/screen.mov", width: width, height: height, scale: src.scale, duration: 0, frameRate: Double(options.frameRate)))
        let b = try ProjectBundle.create(at: url, document: placeholder, events: EventLog())
        bundle = b
        do {
            recorder = try ScreenRecorder(filter: filter, pixelWidth: width, pixelHeight: height, options: options, mediaDirectory: b.mediaURL, clock: clock)
            camera = try Self.makeCamera(options, bundle: b, clock: clock)
        } catch {
            try? FileManager.default.removeItem(at: b.url)   // nothing was recorded yet
            throw error
        }
        let region = CGRect(x: src.frame[0], y: src.frame[1], width: src.frame[2], height: src.frame[3])
        tracker = InputTracker(region: region, cursorsDirectory: b.cursorsURL,
                               pointerSource: InputTracker.PointerSource(rawValue: options.pointer) ?? .system, windowID: windowID, clock: clock)
        recorder.onFirstFrame = { [weak self, tracker, camera] t in
            self?.state.withLock { self?.firstFrameHost = t }
            tracker.setOrigin(t)
            camera?.begin(at: CMTime(seconds: t, preferredTimescale: 1_000_000_000))
        }
        recorder.onError = { [weak self] e in self?.captureFailed(e) }
        recorder.onWarning = { [weak self] m in self?.addWarning(m) }
        camera?.onWarning = { [weak self] m in self?.addWarning(m) }
        tracker.onWarning = { [weak self] m in self?.addWarning(m) }
        clock.observe { [weak self] paused in
            DispatchQueue.main.async { self?.onPauseChange?(paused) }
        }
    }

    public func start() async throws {
        // The camera first: it needs a moment to deliver frames, and the screen's first frame sets time 0 for both.
        do { try await camera?.start() } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        startHost = hostSeconds()
        tracker.start()
        do { try await recorder.start() } catch {
            _ = tracker.stop()
            await camera?.stop(at: nil)
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        state.withLock { _isRecording = true }
        beginJournal()
        startCheckpoints()
        if let max = options.maxDuration, max > 0 {
            // Counts recording time, so paused time doesn't use up the limit.
            autoStop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isRecording else { return }
                    if self.elapsed >= max { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let self, self.isRecording, !Task.isCancelled else { return }
                self.endAutomatically(reason: "time_limit")
            }
        }
    }

    /// Seconds of take so far, paused time excluded.
    public var elapsed: Double { tracker.elapsed }
    public var frames: Int { recorder.frameCount }

    public var status: RecordingStatus {
        RecordingStatus(recording: isRecording, paused: isPaused, elapsed: elapsed, frames: frames, pauses: pauses,
                        warnings: warnings, error: error, endReason: endReason)
    }

    @discardableResult
    public func mark(_ note: String) -> Marker { tracker.addMarker(note, author: author) }

    public func report(_ action: InputTracker.AgentAction) { tracker.report(action) }
    public func normalized(global p: CGPoint) -> NormPoint { tracker.normalized(global: p) }

    /// Pause the take: every track stops recording until `resume`. False if not recording or already paused.
    @discardableResult
    public func pause() -> Bool {
        guard isRecording, clock.pause() else { return false }
        updateJournal { j, s in j.paused = true; j.pauses = s.pauses; j.elapsed = s.elapsed }
        return true
    }

    /// Resume a paused take; the files continue without a gap. False if not paused.
    @discardableResult
    public func resume() -> Bool {
        guard isRecording, clock.resume() else { return false }
        updateJournal { j, s in j.paused = false; j.pauses = s.pauses; j.elapsed = s.elapsed }
        return true
    }

    /// Stop and finalize. Safe to call more than once (and while an automatic stop runs): every caller gets the same
    /// result. A take stopped while paused ends where the pause began.
    public func stop() async throws -> ProjectBundle {
        let task: Task<ProjectBundle, Error>? = state.withLock {
            if let t = stopTask { return t }
            guard _isRecording else { return nil }
            _isRecording = false
            if _endReason == nil { _endReason = "stopped" }
            let t = Task { try await self.finalize() }
            stopTask = t
            return t
        }
        guard let task else { return bundle }
        return try await task.value
    }

    private func finalize() async throws -> ProjectBundle {
        autoStop?.cancel()
        checkpointTimer?.cancel(); checkpointTimer = nil
        let duration: Double
        do { duration = try await recorder.stop() } catch {
            let events = withCaptureContent(tracker.stop())
            await camera?.stop(at: nil)
            writeCheckpoint(events)
            markInterrupted(error)
            throw error
        }
        await camera?.stop(at: recorder.endTime)
        let events = withCaptureContent(tracker.stop())
        do {
            // Probe the real media for the document.
            let asset = AVURLAsset(url: recorder.urls.screen)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let assetDuration = try await asset.load(.duration).seconds
            let size = try await track?.load(.naturalSize) ?? CGSize(width: recorder.pixelWidth, height: recorder.pixelHeight)
            func exists(_ u: URL?) -> String? {
                guard let u, let attrs = try? FileManager.default.attributesOfItem(atPath: u.path), (attrs[.size] as? Int ?? 0) > 1000 else { return nil }
                return "media/" + u.lastPathComponent
            }
            var doc = ProjectDocument(name: bundle.url.deletingPathExtension().lastPathComponent,
                                      media: MediaInfo(screen: "media/screen.mov", microphone: exists(recorder.urls.mic), systemAudio: exists(recorder.urls.system), camera: exists(camera?.url),
                                                       width: Int(size.width), height: Int(size.height), scale: source.scale,
                                                       duration: assetDuration.isFinite && assetDuration > 0 ? assetDuration : duration,
                                                       frameRate: Double(options.frameRate)),
                                      recording: recordingInfo)
            doc.timeline.markers = events.markers
            try bundle.writeEvents(events)
            try bundle.writeDocument(doc)
        } catch {
            writeCheckpoint(events)
            markInterrupted(error)
            throw error
        }
        let warnings = self.warnings
        let error = self.error
        journalQueue.sync {
            guard var j = journal else { return }
            j.status = .finalized
            j.paused = false
            j.pauses = events.pauses ?? []
            j.elapsed = duration
            j.warnings = warnings
            j.error = error
            j.updatedAt = Date(); j.finishedAt = Date()
            journal = j
            try? j.write(bundle)
        }
        try? FileManager.default.removeItem(at: RecordingJournal.checkpointURL(in: bundle))
        return bundle
    }

    private var recordingInfo: RecordingInfo {
        RecordingInfo(startedAt: startedAt, source: "\(source.kind.rawValue):\(source.id)", sourceName: source.app ?? source.name,
                      displayFrame: source.frame, recordedBy: author, inputTracking: AXIsProcessTrusted() ? "poll+ax" : "poll")
    }

    // MARK: Ending on its own

    private func endAutomatically(reason: String) {
        state.withLock { if _endReason == nil { _endReason = reason } }
        Task {
            let r: Result<ProjectBundle, Error>
            do { r = .success(try await self.stop()) } catch { r = .failure(error) }
            self.onEnded?(r)
            self.onAutoStop?(r)
        }
    }

    /// The screen capture stopped (ScreenCaptureKit error, display gone, the person clicked Stop in the menu bar) or
    /// the screen movie stopped writing: keep what exists and say why.
    private func captureFailed(_ e: Error) {
        guard isRecording else { return }
        let ns = e as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userStopped.rawValue {
            // The person ended it from the macOS screen sharing menu: a normal stop.
            addWarning("Recording was stopped from the macOS screen sharing menu.")
            endAutomatically(reason: "stopped")
            return
        }
        let message = "Screen capture stopped early: \((e as? CaptureError)?.description ?? ns.localizedDescription). Everything recorded until then was saved."
        state.withLock { if _error == nil { _error = message } }
        addWarning(message)
        endAutomatically(reason: "capture_error")
    }

    private func addWarning(_ m: String) {
        let added = state.withLock { () -> Bool in
            guard !_warnings.contains(m) else { return false }
            _warnings.append(m)
            return true
        }
        if added { updateJournal { j, s in j.warnings = s.warnings } }
    }

    // MARK: Journal and checkpoints

    private func beginJournal() {
        var media = MediaInfo(screen: "media/screen.mov", width: recorder.pixelWidth, height: recorder.pixelHeight, scale: source.scale, duration: 0, frameRate: Double(options.frameRate))
        if let u = recorder.urls.mic { media.microphone = "media/" + u.lastPathComponent }
        if let u = recorder.urls.system { media.systemAudio = "media/" + u.lastPathComponent }
        if let u = camera?.url { media.camera = "media/" + u.lastPathComponent }
        let pid = ProcessInfo.processInfo.processIdentifier
        let j = RecordingJournal(pid: pid, processStartedAt: OwnerProcess.startTime(pid: pid), processName: ProcessInfo.processInfo.processName,
                                 startedAt: startedAt, media: media, recording: recordingInfo, options: try? JSONValue.from(options))
        journalQueue.sync {
            journal = j
            try? j.write(bundle)
        }
    }

    private func updateJournal(_ change: @escaping (inout RecordingJournal, RecordingSession) -> Void) {
        journalQueue.async { [self] in
            guard var j = journal, j.status == .recording else { return }
            change(&j, self)
            j.updatedAt = Date()
            journal = j
            try? j.write(bundle)
        }
    }

    private func startCheckpoints() {
        let t = DispatchSource.makeTimerSource(queue: journalQueue)
        let interval = Int(RecordingJournal.checkpointInterval * 1000)
        t.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.checkpoint() }
        t.resume()
        checkpointTimer = t
    }

    /// Every 2 s (on `journalQueue`): the events so far and a heartbeat, both written atomically.
    private func checkpoint() {
        guard isRecording, var j = journal, j.status == .recording else { return }
        let events = withCaptureContent(tracker.snapshot())
        try? JSONCoding.compactEncoder.encode(events).write(to: RecordingJournal.checkpointURL(in: bundle), options: .atomic)
        j.elapsed = elapsed
        j.paused = isPaused
        j.pauses = events.pauses ?? []
        j.warnings = warnings
        j.updatedAt = Date()
        journal = j
        try? j.write(bundle)
    }

    private func writeCheckpoint(_ events: EventLog) {
        try? JSONCoding.compactEncoder.encode(events).write(to: RecordingJournal.checkpointURL(in: bundle), options: .atomic)
    }

    private func withCaptureContent(_ events: EventLog) -> EventLog {
        var events = events
        let content = recorder.captureContent
        events.captureContent = content.isEmpty ? nil : content
        return events
    }

    private func markInterrupted(_ error: Error) {
        let warnings = self.warnings
        let elapsed = self.elapsed
        journalQueue.sync {
            guard var j = journal else { return }
            j.status = .interrupted
            j.error = (error as? CaptureError)?.description ?? "\(error)"
            j.warnings = warnings
            j.elapsed = elapsed
            j.updatedAt = Date(); j.finishedAt = Date()
            journal = j
            try? j.write(bundle)
        }
    }
}

/// Identifies the process that owns a recording, so a reused PID isn't mistaken for a live recorder.
public enum OwnerProcess {
    /// When `pid` started (seconds since 1970), or nil if there's no such process.
    public static func startTime(pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// Whether the process that wrote a journal is still running (same PID and, when recorded, same start time).
    public static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        guard let startedAt else { return true }
        guard let now = startTime(pid: pid) else { return false }
        return abs(now - startedAt) < 1
    }
}
