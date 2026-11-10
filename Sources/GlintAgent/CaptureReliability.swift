import Foundation
import AVFoundation
import CoreGraphics
import Darwin
import GlintCore
import GlintCapture

// Capture reliability on the service: preflight checks, recovery of interrupted takes, and pause/resume requests from
// other processes. The live pause/resume and stop logic is in Service.swift (Recording) and RecordingSession.

// MARK: - Preflight

extension GlintService {
    /// Checks everything a take needs before it starts: Screen Recording permission, the source, microphone and
    /// camera access when asked for, free disk space for the take, and write access to the projects folder. Each check
    /// passes, warns or fails with a plain-language fix. Nothing is recorded and no prompt is shown.
    public func preflight(_ o: RecordingOptions) async -> PreflightReport {
        var checks: [PreflightCheck] = []
        // Screen Recording.
        let screenOK = Sources.hasScreenRecordingPermission
        checks.append(screenOK
            ? PreflightCheck(id: "screen_recording", title: "Screen Recording permission", verdict: .pass, detail: "Granted.")
            : PreflightCheck(id: "screen_recording", title: "Screen Recording permission", verdict: .fail,
                             detail: "macOS doesn't allow this process to record the screen yet.", fix: CaptureError.permissionDenied.description))
        // Source.
        var source: CaptureSource?
        if screenOK {
            do {
                let list = try await Sources.list()
                if let wid = o.windowID {
                    source = list.first { $0.kind == .window && $0.id == wid }
                    checks.append(source.map { PreflightCheck(id: "source", title: "Window", verdict: .pass, detail: "\($0.app.map { "\($0): " } ?? "")\($0.name), \($0.pixelWidth)×\($0.pixelHeight).") }
                        ?? PreflightCheck(id: "source", title: "Window", verdict: .fail, detail: "Window \(wid) isn't on screen: it was closed, minimized, or is on another Space.",
                                          fix: "List the current windows (glint_list_sources or `glint sources`) and pass a window_id from there, or bring the window back on screen."))
                } else {
                    let did = o.displayID ?? CGMainDisplayID()
                    source = list.first { $0.kind == .display && $0.id == did }
                    checks.append(source.map { PreflightCheck(id: "source", title: "Display", verdict: .pass, detail: "\($0.name), \($0.pixelWidth)×\($0.pixelHeight).") }
                        ?? PreflightCheck(id: "source", title: "Display", verdict: .fail, detail: "Display \(did) isn't connected.",
                                          fix: "List the displays (glint_list_sources or `glint sources`) and pass a display_id from there, or leave it out to record the main display."))
                }
            } catch {
                checks.append(PreflightCheck(id: "source", title: "Capture source", verdict: .fail, detail: "Couldn't list displays and windows: \(error).",
                                             fix: "Check Screen Recording permission, then try again."))
            }
        } else {
            checks.append(PreflightCheck(id: "source", title: o.windowID == nil ? "Display" : "Window", verdict: .warn,
                                         detail: "Not checked: listing displays and windows needs Screen Recording permission first."))
        }
        // Microphone.
        if o.microphone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied || status == .restricted {
                checks.append(PreflightCheck(id: "microphone", title: "Microphone", verdict: .fail, detail: "Microphone access is turned off for this process.",
                                             fix: CaptureError.microphoneDenied.description))
            } else if AVCaptureDevice.default(for: .audio) == nil {
                checks.append(PreflightCheck(id: "microphone", title: "Microphone", verdict: .fail, detail: "No microphone is connected.",
                                             fix: "Connect a microphone, or record without one (microphone: false)."))
            } else if status == .notDetermined {
                checks.append(PreflightCheck(id: "microphone", title: "Microphone", verdict: .warn, detail: "macOS will ask for microphone access when the take starts.",
                                             fix: "Allow the microphone in the macOS prompt."))
            } else {
                let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input"
                checks.append(PreflightCheck(id: "microphone", title: "Microphone", verdict: .pass, detail: "Allowed (\(name))."))
            }
        }
        // Camera.
        var cameraBits = 0.0
        if o.camera {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .denied || status == .restricted {
                checks.append(PreflightCheck(id: "camera", title: "Camera", verdict: .fail, detail: "Camera access is turned off for this process.", fix: CaptureError.cameraDenied.description))
            } else if let dev = Cameras.device(id: o.cameraID) {
                cameraBits = CameraRecorder.typicalBitrate
                checks.append(status == .notDetermined
                    ? PreflightCheck(id: "camera", title: "Camera", verdict: .warn, detail: "macOS will ask for camera access when the take starts (\(dev.localizedName)).", fix: "Allow the camera in the macOS prompt.")
                    : PreflightCheck(id: "camera", title: "Camera", verdict: .pass, detail: "\(dev.localizedName)."))
            } else {
                checks.append(PreflightCheck(id: "camera", title: "Camera", verdict: .fail, detail: CaptureError.cameraNotFound(o.cameraID ?? "").description,
                                             fix: o.cameraID == nil ? "Connect a camera, or record without one (camera: false)." : "Pass a camera_id from glint_list_sources cameras:true, or leave it out for the default camera."))
            }
        }
        // Folder: exists (or can be made) and is writable.
        let dir = o.directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? GlintPaths.projects
        checks.append(Self.writeCheck(dir))
        // Disk space for the take.
        let (w, h) = source.map { ($0.pixelWidth, $0.pixelHeight) } ?? Self.mainDisplayPixels()
        let video = ScreenRecorder.videoBitrate(pixelWidth: w - w % 2, pixelHeight: h - h % 2, frameRate: o.frameRate)
        var audio: [Double] = []
        if o.systemAudio { audio.append(ScreenRecorder.systemAudioBitrate) }
        if o.microphone { audio.append(ScreenRecorder.microphoneBitrate) }
        let bps = PreflightMath.bytesPerSecond(videoBitsPerSecond: video, audioBitsPerSecond: audio, cameraBitsPerSecond: cameraBits)
        let (free, volume) = Self.freeSpace(at: dir)
        if let free {
            checks.append(PreflightMath.diskCheck(freeBytes: free, bytesPerSecond: bps, maxDuration: o.maxDuration, volume: volume))
        } else {
            checks.append(PreflightCheck(id: "disk", title: "Free disk space", verdict: .warn, detail: "Couldn't read the free space on \(volume)."))
        }
        let total = o.maxDuration.flatMap { $0 > 0 ? bps * $0 : nil }
        return PreflightReport(checks: checks, estimatedBytesPerMinute: bps * 60, estimatedBytes: total, freeBytes: free)
    }

    /// One message for a preflight that failed: what's wrong and how to fix it.
    static func preflightMessage(_ r: PreflightReport) -> String {
        let lines = r.failures.map { c in "• \(c.title): \(c.detail)\(c.fix.map { " Fix: \($0)" } ?? "")" }
        return "Can't start recording:\n" + lines.joined(separator: "\n")
    }

    static func writeCheck(_ dir: URL) -> PreflightCheck {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".glint-write-test-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try? fm.removeItem(at: probe)
            return PreflightCheck(id: "folder", title: "Projects folder", verdict: .pass, detail: "\(dir.path) is writable.")
        } catch {
            return PreflightCheck(id: "folder", title: "Projects folder", verdict: .fail, detail: "Can't write to \(dir.path): \(error.localizedDescription)",
                                  fix: "Choose a folder you can write to (directory), or fix the folder's permissions in Finder (Get Info › Sharing & Permissions).")
        }
    }

    static func freeSpace(at dir: URL) -> (Double?, String) {
        var probe = dir
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeNameKey])
        let free = v?.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? v?.volumeAvailableCapacity.map(Double.init)
        return (free, v?.volumeName.map { "“\($0)”" } ?? probe.path)
    }

    static func mainDisplayPixels() -> (Int, Int) {
        let id = CGMainDisplayID()
        if let m = CGDisplayCopyDisplayMode(id) { return (m.pixelWidth, m.pixelHeight) }
        let b = CGDisplayBounds(id)
        return (Int(b.width * 2), Int(b.height * 2))
    }
}

// MARK: - Recovery

/// A take that didn't finish (its recorder crashed or was killed, or finalizing it failed), found by `recoverableRecordings`.
public struct RecoverableRecording: Codable, Sendable, Hashable {
    public var project: String
    public var name: String
    public var startedAt: Date
    /// When the take last wrote a checkpoint: about when it was interrupted.
    public var lastCheckpoint: Date
    /// "recording" (its process is gone) or "interrupted" (finalizing failed).
    public var status: String
    /// Recording seconds at the last checkpoint (paused time excluded).
    public var elapsed: Double
    public var error: String?
    public var recordedBy: Author
    public var processName: String
    /// Media files on disk and their sizes in bytes.
    public var files: [String: Int]
    public var warnings: [String]
}

/// What `recover` rebuilt.
public struct RecoveryResult: Codable, Sendable {
    public var project: String
    public var duration: Double
    /// Tracks in the recovered project: screen, microphone, system, camera.
    public var tracks: [String]
    /// What was recovered and what was lost, in plain language.
    public var notes: [String]
    public var events: [String: Int]
}

extension GlintService {
    /// Whether a journal's take is still being recorded, by this process or another live one.
    func journalOwnerAlive(_ j: RecordingJournal, bundle: ProjectBundle) -> Bool {
        if j.pid == ProcessInfo.processInfo.processIdentifier {
            return sessionIDs.contains { session($0)?.1.bundle.url.standardizedFileURL == bundle.url.standardizedFileURL }
        }
        return OwnerProcess.isAlive(pid: j.pid, startedAt: j.processStartedAt)
    }

    /// Takes that never finished: in the projects folder, plus takes whose recorder died somewhere else (from the
    /// session registry). A take whose recorder is still running is never listed.
    public func recoverableRecordings(in directory: URL = GlintPaths.projects, includeStale: Bool = true) -> [RecoverableRecording] {
        var urls = listProjectURLs(in: directory)
        if includeStale { _ = SessionRegistry.active() }        // moves entries of recorders that died to the stale list
        for (id, path) in includeStale ? SessionRegistry.staleProjects() : [] {
            let u = URL(fileURLWithPath: path)
            let j = RecordingJournal.read(ProjectBundle(url: u))
            if j?.isUnfinished == true { urls.append(u) } else { SessionRegistry.forgetStale(id: id) }
        }
        var seen = Set<String>()
        var out: [RecoverableRecording] = []
        for u in urls {
            let b = ProjectBundle(url: u)
            guard seen.insert(b.url.path).inserted, let j = RecordingJournal.read(b), j.isRecoverable(ownerAlive: journalOwnerAlive(j, bundle: b)) else { continue }
            var files: [String: Int] = [:]
            for rel in [j.media.screen, j.media.microphone, j.media.systemAudio, j.media.camera].compactMap({ $0 }) {
                if let size = (try? FileManager.default.attributesOfItem(atPath: b.resolve(rel).path))?[.size] as? Int { files[rel] = size }
            }
            out.append(RecoverableRecording(project: b.url.path, name: b.url.deletingPathExtension().lastPathComponent, startedAt: j.startedAt,
                                            lastCheckpoint: j.updatedAt, status: j.status.rawValue, elapsed: j.elapsed, error: j.error,
                                            recordedBy: j.recording.recordedBy, processName: j.processName, files: files, warnings: j.warnings))
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// Rebuilds an interrupted take into a normal project from what reached the disk: the media fragments written
    /// every 2 s (read back with AVFoundation to find how much is playable) and the last events checkpoint, clipped
    /// to the screen movie's length. The media files are not rewritten.
    public func recover(_ b: ProjectBundle) async throws -> RecoveryResult {
        guard let j = RecordingJournal.read(b) else { throw ServiceError.invalid("\(b.url.lastPathComponent) has no recording journal, so it isn't an interrupted take.") }
        guard j.isUnfinished else { throw ServiceError.invalid("\(b.url.lastPathComponent) was already \(j.status == .recovered ? "recovered" : "finished normally"); nothing to recover.") }
        guard j.isRecoverable(ownerAlive: journalOwnerAlive(j, bundle: b)) else {
            throw ServiceError.invalid("\(b.url.lastPathComponent) is still being recorded by \(j.processName) (pid \(j.pid)). Stop it there instead.")
        }
        var notes: [String] = []
        let screen = await Self.probe(b.resolve(j.media.screen), video: true)
        guard let screen, screen.duration > 0.05 else {
            throw ServiceError.invalid("Nothing in \(b.url.lastPathComponent) can be played: the screen movie has no complete fragment (the take was shorter than about \(Int(RecordingJournal.checkpointInterval)) s, or the file is damaged). Discard it.")
        }
        let duration = screen.duration
        notes.append(String(format: "Recovered %.1f s of screen video.", duration))
        if j.elapsed > duration + 0.5 {
            notes.append(String(format: "The last %.1f s before the interruption hadn't reached the disk and are lost (media is saved every %.0f s).",
                                j.elapsed - duration, RecordingJournal.checkpointInterval))
        }
        var tracks = ["screen"]
        var media = MediaInfo(screen: j.media.screen, width: screen.width ?? j.media.width, height: screen.height ?? j.media.height,
                              scale: j.media.scale, duration: duration, frameRate: j.media.frameRate)
        for (label, rel, isVideo) in [("microphone", j.media.microphone, false), ("system audio", j.media.systemAudio, false), ("camera", j.media.camera, true)] {
            guard let rel else { continue }
            if let p = await Self.probe(b.resolve(rel), video: isVideo), p.duration > 0.05 {
                switch label {
                case "microphone": media.microphone = rel; tracks.append("microphone")
                case "system audio": media.systemAudio = rel; tracks.append("system")
                default: media.camera = rel; tracks.append("camera")
                }
                if p.duration < duration - 1 { notes.append(String(format: "The %@ track ends early, at %.1f s.", label, p.duration)) }
            } else {
                notes.append("The \(label) track couldn't be read and was left out.")
            }
        }
        // Events: the last checkpoint, clipped to what the movie shows.
        let checkpointURL = RecordingJournal.checkpointURL(in: b)
        var events = EventLog()
        if let d = try? Data(contentsOf: checkpointURL), let e = try? JSONCoding.decoder.decode(EventLog.self, from: d) {
            events = e.clipped(to: duration)
            notes.append("Input events up to the last checkpoint were kept (\(events.clicks.count) clicks, \(events.keys.count) keys).")
        } else {
            notes.append("No input events were saved (the take ended before its first checkpoint), so automatic zooms have nothing to work from.")
        }
        if let p = events.pauses, !p.isEmpty { notes.append("The take had \(p.count) pause\(p.count == 1 ? "" : "s"); the movie already skips them.") }
        let old = try? b.readDocument()
        var doc = ProjectDocument(id: old?.id ?? IDs.make("p"), name: old?.name ?? b.url.deletingPathExtension().lastPathComponent,
                                  createdAt: old?.createdAt ?? j.startedAt, media: media, recording: j.recording)
        doc.timeline.markers = events.markers
        var final = j
        final.status = .recovered
        final.notes = notes
        final.elapsed = duration
        final.updatedAt = Date(); final.finishedAt = Date()
        let finalEvents = events, finalDoc = doc, journal = final
        try b.withLock {
            try b.writeEvents(finalEvents)
            try b.writeDocument(finalDoc)
            try journal.write(b)
        }
        try? FileManager.default.removeItem(at: checkpointURL)
        for (id, path) in SessionRegistry.staleProjects() where URL(fileURLWithPath: path).standardizedFileURL == b.url.standardizedFileURL { SessionRegistry.forgetStale(id: id) }
        return RecoveryResult(project: b.url.path, duration: duration, tracks: tracks, notes: notes,
                              events: ["pointer": events.pointer.count, "clicks": events.clicks.count, "keys": events.keys.count, "scrolls": events.scrolls.count, "markers": events.markers.count])
    }

    /// Moves an interrupted take to the Trash (destructive → approval, like deleting any project).
    public func discardRecording(_ b: ProjectBundle, author: Author, approvalID: String?, confirmedByUser: Bool = false) throws -> URL? {
        if let j = RecordingJournal.read(b), !j.isRecoverable(ownerAlive: journalOwnerAlive(j, bundle: b)), j.isUnfinished {
            throw ServiceError.invalid("\(b.url.lastPathComponent) is still being recorded by \(j.processName) (pid \(j.pid)).")
        }
        let r = try deleteProject(b, author: author, approvalID: approvalID, confirmedByUser: confirmedByUser)
        for (id, path) in SessionRegistry.staleProjects() where URL(fileURLWithPath: path).standardizedFileURL == b.url.standardizedFileURL { SessionRegistry.forgetStale(id: id) }
        return r
    }

    struct Probe { var duration: Double; var width: Int?; var height: Int? }

    /// How much of a (possibly partial) movie AVFoundation can play.
    static func probe(_ url: URL, video: Bool) async -> Probe? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: video ? .video : .audio), let track = tracks.first,
              let d = try? await asset.load(.duration), d.isNumeric else { return nil }
        let range = try? await track.load(.timeRange)
        let seconds = min(d.seconds, range.map { CMTimeRangeGetEnd($0).seconds } ?? d.seconds)
        guard seconds.isFinite, seconds > 0 else { return nil }
        if video, let size = try? await track.load(.naturalSize), size.width > 0 {
            return Probe(duration: seconds, width: Int(size.width), height: Int(size.height))
        }
        return Probe(duration: seconds, width: nil, height: nil)
    }
}

// MARK: - Pause/resume from another process

/// Lets `glint pause` / `glint resume` in one terminal control a take running in another process (Glint.app, a
/// `glint record`, or `glint mcp` with GLINT_CAPTURE=local). The request is written next to the session's registry
/// entry and the hosting process is woken with SIGUSR1; it applies the request and the take's journal shows the result.
/// Only processes that advertise `control` in their registry entry are ever signalled.
public enum RecordingControl {
    public static let version = 1
    private static let lock = NSLock()
    nonisolated(unsafe) private static var source: DispatchSourceSignal?
    nonisolated(unsafe) private static var services: [WeakService] = []
    private struct WeakService { weak var service: GlintService? }

    struct Request: Codable { var action: String; var by: String; var at: Date }

    static var isInstalled: Bool { lock.withLock { source != nil } }

    static func requestURL(_ id: String) -> URL { SessionRegistry.dir.appendingPathComponent("\(id).control") }

    /// Starts listening (once per process) for requests aimed at `service`'s sessions.
    static func install(service: GlintService) {
        lock.withLock {
            services.removeAll { $0.service == nil }
            if !services.contains(where: { $0.service === service }) { services.append(WeakService(service: service)) }
            guard source == nil else { return }
            signal(SIGUSR1, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .userInitiated))
            s.setEventHandler { handleRequests() }
            s.resume()
            source = s
        }
    }

    static func handleRequests() {
        let live = lock.withLock { services.compactMap(\.service) }
        for service in live {
            for id in service.sessionIDs {
                let u = requestURL(id)
                guard let d = try? Data(contentsOf: u) else { continue }
                try? FileManager.default.removeItem(at: u)
                guard let r = try? JSONCoding.decoder.decode(Request.self, from: d), Date().timeIntervalSince(r.at) < 30 else { continue }
                switch r.action {
                case "pause": _ = try? service.pauseRecording(id)
                case "resume": _ = try? service.resumeRecording(id)
                default: break
                }
            }
        }
    }

    /// From another process: pause or resume the take in `entry` and wait (up to `timeout`) until its journal shows it.
    public static func send(_ action: String, to entry: SessionRegistry.Entry, by: String, timeout: TimeInterval = 3) throws -> RecordingJournal {
        guard action == "pause" || action == "resume" else { throw ServiceError.invalid("action must be pause or resume") }
        guard entry.control != nil else {
            throw ServiceError.invalid("That take is recorded by an older Glint (pid \(entry.pid)) that can't be paused from here. Use its own controls.")
        }
        let bundle = ProjectBundle(url: URL(fileURLWithPath: entry.project))
        let want = action == "pause"
        if let j = RecordingJournal.read(bundle), j.status == .recording, j.paused == want { return j }
        try JSONCoding.encoder.encode(Request(action: action, by: by, at: Date())).write(to: requestURL(entry.id), options: .atomic)
        guard kill(entry.pid, SIGUSR1) == 0 else {
            try? FileManager.default.removeItem(at: requestURL(entry.id))
            throw ServiceError.invalid("The process recording that take (pid \(entry.pid)) isn't running any more.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let j = RecordingJournal.read(bundle) {
                if j.status != .recording { throw ServiceError.invalid("That take has already ended (\(j.status.rawValue)).") }
                if j.paused == want { return j }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? FileManager.default.removeItem(at: requestURL(entry.id))
        throw ServiceError.invalid("The process recording that take (pid \(entry.pid)) didn't answer. Try its own controls.")
    }
}

// MARK: - Tools

/// Tools for pausing a take, checking a take can start, and recovering interrupted takes. Appended to the registry.
enum CaptureReliabilityTools {
    static func status(_ id: String, _ s: RecordingSession) throws -> JSONValue {
        var o: [String: JSONValue] = ["session_id": .string(id), "project": .string(s.bundle.url.path)]
        if case .object(let st) = try JSONValue.from(s.status) { for (k, v) in st { o[k] = v } }
        return .object(o)
    }

    static func options(_ a: JSONValue) -> RecordingOptions {
        var o = RecordingOptions()
        o.displayID = a.num("display_id").map { UInt32($0) }
        o.windowID = a.num("window_id").map { UInt32($0) }
        o.microphone = a.flag("microphone") ?? false
        o.systemAudio = a.flag("system_audio") ?? true
        o.camera = a.flag("camera") ?? false || a.str("camera_id") != nil
        o.cameraID = a.str("camera_id")
        o.maxDuration = a.num("max_duration")
        o.directory = a.str("directory")
        return o
    }

    static let specs: [ToolSpec] = [
        ToolSpec(name: "glint_record_pause", title: "Pause recording", description: "Pause the active take: screen, audio, camera and input stop recording until glint_record_resume. The finished take has no gap (the pause becomes a cut); pauses are listed in the events. Paused time doesn't count towards max_duration.", risk: .reversible,
                 schema: S.obj(["session_id": S.str("Session ID (default: the active recording)")])) { a, c in
            let wasPaused = c.service.session(a.str("session_id"))?.1.isPaused ?? false
            let (id, s) = try c.service.pauseRecording(a.str("session_id"))
            var out = try status(id, s)
            if case .object(var o) = out { o["already_paused"] = .bool(wasPaused); out = .object(o) }
            return ToolOutput(json: out)
        },
        ToolSpec(name: "glint_record_resume", title: "Resume recording", description: "Resume a paused take. Recording continues in the same files, right after the moment it was paused.", risk: .reversible,
                 schema: S.obj(["session_id": S.str("Session ID (default: the active recording)")])) { a, c in
            let wasPaused = c.service.session(a.str("session_id"))?.1.isPaused ?? false
            let (id, s) = try c.service.resumeRecording(a.str("session_id"))
            var out = try status(id, s)
            if case .object(var o) = out { o["was_paused"] = .bool(wasPaused); out = .object(o) }
            return ToolOutput(json: out)
        },
        ToolSpec(name: "glint_record_preflight", title: "Check before recording", description: "Check a take can start, without recording: Screen Recording permission, the display/window exists, microphone and camera access (when asked for), free disk space for the take (estimated from the bitrate × max_duration, or per minute), and write access to the projects folder. Each check is pass/warn/fail with a plain-language fix. glint_record_start runs the same checks and refuses on a fail.", risk: .read,
                 schema: S.obj(["display_id": S.int("Display ID (default main)"), "window_id": S.int("Window ID (from list_sources)"), "microphone": S.bool("Will record the mic (false)"),
                                "system_audio": S.bool("Will record system audio (true)"), "camera": S.bool("Will record the camera (false)"), "camera_id": S.str("Camera ID (implies camera)"),
                                "max_duration": S.num("Planned length in seconds (the disk check covers the whole take)"), "directory": S.str("Folder the project will go in (default ~/Movies/Glint)")])) { a, c in
            try .encode(await c.service.preflight(options(a)))
        },
        ToolSpec(name: "glint_recover_recordings", title: "Recover interrupted recordings", description: "Find and rebuild takes that never finished (Glint or the recording process crashed, was force-quit or lost power, or finalizing failed). action list (default): the interrupted takes. action recover: rebuild one (project) or all of them into normal projects from the media saved every 2 s and the last input-events checkpoint; returns what was recovered and what was lost. action discard: move one to the Trash (destructive: needs the user's approval).", risk: .reversible,
                 schema: S.obj(["action": S.str("list | recover | discard", enumValues: ["list", "recover", "discard"]), "project": S.str("The interrupted project's path (from action list). recover without it recovers every interrupted take."),
                                "approval_id": S.approval])) { a, c in
            switch a.str("action") ?? "list" {
            case "list":
                return try .encode(c.service.recoverableRecordings())
            case "recover":
                let targets = try a.str("project").map { [try c.service.resolveRecoverable($0)] } ?? c.service.recoverableRecordings().map { ProjectBundle(url: URL(fileURLWithPath: $0.project)) }
                if targets.isEmpty { return ToolOutput(json: .object(["recovered": .array([]), "note": .string("No interrupted recordings.")])) }
                var results: [JSONValue] = []
                for b in targets {
                    do { results.append(try JSONValue.from(try await c.service.recover(b))) }
                    catch { results.append(.object(["project": .string(b.url.path), "error": .string("\(error)")])) }
                }
                return ToolOutput(json: .object(["recovered": .array(results)]))
            case "discard":
                guard let p = a.str("project") else { throw ServiceError.invalid("discard needs project (from action list)") }
                let r = try c.service.discardRecording(try c.service.resolveRecoverable(p), author: c.author, approvalID: a.str("approval_id"))
                return ToolOutput(json: .object(["trashed": .string(r?.path ?? p)]))
            default:
                throw ServiceError.invalid("action must be list, recover or discard")
            }
        },
    ]
}

extension GlintService {
    /// An interrupted take by path or project name (it needn't be in the projects folder).
    public func resolveRecoverable(_ ref: String) throws -> ProjectBundle {
        let u = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: RecordingJournal.url(in: ProjectBundle(url: u)).path) { return ProjectBundle(url: u) }
        return try resolve(ref)
    }
}
