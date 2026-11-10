import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import GlintCore

/// Records a display or window into a new `.glint` project: screen video, audio tracks, input events and cursor images.
public final class RecordingSession: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let options: RecordingOptions
    public let source: CaptureSource
    private let recorder: ScreenRecorder
    private let tracker: InputTracker
    private let camera: CameraRecorder?
    public let author: Author
    private let startedAt = Date()
    public private(set) var isRecording = false
    private var autoStop: Task<Void, Never>?
    public var onAutoStop: ((Result<ProjectBundle, Error>) -> Void)?
    /// The running camera, for a live preview while recording. Nil when the take has no camera.
    public var cameraSession: AVCaptureSession? { camera?.session }

    private static func makeCamera(_ options: RecordingOptions, bundle: ProjectBundle) throws -> CameraRecorder? {
        guard options.camera else { return nil }
        do { return try CameraRecorder(deviceID: options.cameraID, mediaDirectory: bundle.mediaURL) } catch {
            try? FileManager.default.removeItem(at: bundle.url)   // nothing was recorded yet
            throw error
        }
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

    public init(options: RecordingOptions, author: Author) async throws {
        self.options = options
        self.author = author
        if options.camera, !(await Cameras.requestAccess()) { throw CaptureError.cameraDenied }
        let content = try await Sources.shareable()
        let sources = try await Sources.list()
        let filter: SCContentFilter
        let src: CaptureSource
        var width: Int, height: Int
        if let wid = options.windowID {
            guard let w = content.windows.first(where: { $0.windowID == wid }), let s = sources.first(where: { $0.kind == .window && $0.id == wid }) else {
                throw CaptureError.sourceNotFound("window \(wid)")
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            src = s
            width = s.pixelWidth; height = s.pixelHeight
        } else {
            let did = options.displayID ?? CGMainDisplayID()
            guard let d = content.displays.first(where: { $0.displayID == did }), let s = sources.first(where: { $0.kind == .display && $0.id == did }) else {
                throw CaptureError.sourceNotFound("display \(did)")
            }
            // Exclude Glint's own windows (recording HUD) from the capture.
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            src = s
            width = s.pixelWidth; height = s.pixelHeight
        }
        source = src
        let url = Self.makeProjectURL(name: options.projectName, directory: options.directory)
        let placeholder = ProjectDocument(name: url.deletingPathExtension().lastPathComponent,
                                          media: MediaInfo(screen: "media/screen.mov", width: width, height: height, scale: src.scale, duration: 0, frameRate: Double(options.frameRate)))
        bundle = try ProjectBundle.create(at: url, document: placeholder, events: EventLog())
        recorder = try ScreenRecorder(filter: filter, pixelWidth: width, pixelHeight: height, options: options, mediaDirectory: bundle.mediaURL)
        let region = CGRect(x: src.frame[0], y: src.frame[1], width: src.frame[2], height: src.frame[3])
        tracker = InputTracker(region: region, cursorsDirectory: bundle.cursorsURL,
                               pointerSource: InputTracker.PointerSource(rawValue: options.pointer) ?? .system)
        camera = try Self.makeCamera(options, bundle: bundle)
        recorder.onFirstFrame = { [tracker, camera] t in
            tracker.setOrigin(t)
            camera?.begin(at: CMTime(seconds: t, preferredTimescale: 1_000_000_000))
        }
    }

    /// Record content the user chose in the system picker (`SCContentSharingPicker`). Using the picker avoids macOS's
    /// periodic "bypass the private window picker" confirmation for user-initiated recordings.
    public init(filter: SCContentFilter, options: RecordingOptions, author: Author) throws {
        self.options = options
        self.author = author
        let rect = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        let kind: CaptureSource.Kind = filter.style == .window ? .window : .display
        source = CaptureSource(kind: kind, id: 0, name: kind == .window ? "Window" : "Display", app: nil, bundleID: nil,
                               frame: [rect.origin.x, rect.origin.y, rect.width, rect.height], pixelWidth: width, pixelHeight: height, scale: scale, isMain: nil)
        let url = Self.makeProjectURL(name: options.projectName, directory: options.directory)
        let placeholder = ProjectDocument(name: url.deletingPathExtension().lastPathComponent,
                                          media: MediaInfo(screen: "media/screen.mov", width: width, height: height, scale: scale, duration: 0, frameRate: Double(options.frameRate)))
        bundle = try ProjectBundle.create(at: url, document: placeholder, events: EventLog())
        recorder = try ScreenRecorder(filter: filter, pixelWidth: width, pixelHeight: height, options: options, mediaDirectory: bundle.mediaURL)
        tracker = InputTracker(region: rect, cursorsDirectory: bundle.cursorsURL, pointerSource: InputTracker.PointerSource(rawValue: options.pointer) ?? .system)
        camera = try Self.makeCamera(options, bundle: bundle)
        recorder.onFirstFrame = { [tracker, camera] t in
            tracker.setOrigin(t)
            camera?.begin(at: CMTime(seconds: t, preferredTimescale: 1_000_000_000))
        }
    }

    public func start() async throws {
        // The camera first: it needs a moment to deliver frames, and the screen's first frame sets time 0 for both.
        do { try await camera?.start() } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        tracker.start()
        do { try await recorder.start() } catch {
            _ = tracker.stop()
            await camera?.stop(at: nil)
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        isRecording = true
        if let max = options.maxDuration, max > 0 {
            autoStop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max * 1e9))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                let r: Result<ProjectBundle, Error>
                do { r = .success(try await self.stop()) } catch { r = .failure(error) }
                self.onAutoStop?(r)
            }
        }
    }

    public var elapsed: Double { tracker.elapsed }
    public var frames: Int { recorder.frameCount }

    @discardableResult
    public func mark(_ note: String) -> Marker { tracker.addMarker(note, author: author) }

    public func report(_ action: InputTracker.AgentAction) { tracker.report(action) }
    public func normalized(global p: CGPoint) -> NormPoint { tracker.normalized(global: p) }

    public func stop() async throws -> ProjectBundle {
        guard isRecording else { return bundle }
        isRecording = false
        autoStop?.cancel()
        let duration: Double
        do { duration = try await recorder.stop() } catch {
            _ = tracker.stop()
            await camera?.stop(at: nil)
            throw error
        }
        await camera?.stop(at: recorder.endTime)
        let events = tracker.stop()
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
                                  recording: RecordingInfo(startedAt: startedAt, source: "\(source.kind.rawValue):\(source.id)", sourceName: source.app ?? source.name,
                                                           displayFrame: source.frame, recordedBy: author,
                                                           inputTracking: AXIsProcessTrusted() ? "poll+ax" : "poll"))
        doc.timeline.markers = events.markers
        try bundle.writeEvents(events)
        try bundle.writeDocument(doc)
        return bundle
    }
}
