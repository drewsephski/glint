import Foundation
import AVFoundation
import AppKit
import GlintCore
import GlintCapture
import GlintRender
import GlintAnalysis
import ScreenCaptureKit

public enum ServiceError: Error, CustomStringConvertible {
    case projectNotFound(String)
    case invalid(String)
    public var description: String {
        switch self {
        case .projectNotFound(let s): return "Project not found: \(s). Pass a path to a .glint bundle, a project name in \(GlintPaths.projects.path), or \"latest\"."
        case .invalid(let s): return s
        }
    }
}

public struct ProjectSummary: Codable, Sendable {
    public var path: String
    public var name: String
    public var revision: Int
    public var createdAt: Date
    public var sourceDuration: Double
    public var outputDuration: Double
    public var resolution: String
    public var audio: [String]
    public var counts: [String: Int]
    public var transcript: String?
    public var pendingProposals: [String]
    public var canUndo: Bool
    public var canRedo: Bool
    public var lastRender: String?
}

public struct RenderOutput: Codable, Sendable {
    public var variant: String
    public var path: String
    public var width: Int
    public var height: Int
    public var duration: Double
    public var seconds: Double
    public var report: RenderReport?
}

public struct RenderManifest: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var author: Author
    public var revision: Int
    public var proposalID: String?
    public var outputs: [RenderOutput]
}

/// The shared project engine facade: every surface (SwiftUI app, `glint` CLI, MCP server) calls these methods.
public final class GlintService: @unchecked Sendable {
    public let approvals: ApprovalStore
    public init(approvals: ApprovalStore = ApprovalStore()) { self.approvals = approvals }

    // MARK: Projects

    public func resolve(_ ref: String?) throws -> ProjectBundle {
        let fm = FileManager.default
        guard let ref, !ref.isEmpty, ref != "latest" else {
            guard let latest = listProjectURLs().first else { throw ServiceError.projectNotFound(ref ?? "latest") }
            return ProjectBundle(url: latest)
        }
        let expanded = (ref as NSString).expandingTildeInPath
        let candidates = [URL(fileURLWithPath: expanded),
                          URL(fileURLWithPath: expanded + "." + ProjectBundle.pathExtension),
                          GlintPaths.projects.appendingPathComponent(ref),
                          GlintPaths.projects.appendingPathComponent(ref + "." + ProjectBundle.pathExtension)]
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("project.json").path) { return ProjectBundle(url: c) }
        // Match by document id or name prefix.
        for u in listProjectURLs() {
            let b = ProjectBundle(url: u)
            if let d = try? b.readDocument(), d.id == ref || d.name.lowercased().hasPrefix(ref.lowercased()) { return b }
        }
        throw ServiceError.projectNotFound(ref)
    }

    public func listProjectURLs(in dir: URL = GlintPaths.projects) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == ProjectBundle.pathExtension && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .sorted { a, b in
                let da = (try? ProjectBundle(url: a).readDocument().createdAt) ?? .distantPast
                let db = (try? ProjectBundle(url: b).readDocument().createdAt) ?? .distantPast
                return da > db
            }
    }

    public func summary(_ b: ProjectBundle) throws -> ProjectSummary {
        let doc = try b.readDocument()
        let e = Engine(bundle: b)
        let st = e.stacks()
        let tr = b.readTranscript()
        let renders = (try? FileManager.default.contentsOfDirectory(at: b.rendersURL, includingPropertiesForKeys: [.creationDateKey]))?
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first?.lastPathComponent
        let ev = b.readEvents()
        return ProjectSummary(path: b.url.path, name: doc.name, revision: doc.revision, createdAt: doc.createdAt,
                              sourceDuration: doc.media.duration, outputDuration: TimeMap(document: doc).outputDuration,
                              resolution: "\(doc.media.width)×\(doc.media.height)@\(Int(doc.media.frameRate))",
                              audio: [doc.media.microphone.map { _ in "microphone" }, doc.media.systemAudio.map { _ in "system" }].compactMap { $0 },
                              counts: ["zooms": doc.timeline.zooms.count, "cuts": doc.timeline.cuts.count, "speeds": doc.timeline.speeds.count,
                                       "captions": doc.timeline.captions.count, "markers": doc.timeline.markers.count, "voiceover": doc.timeline.voiceover.count,
                                       "clicks": ev.clicks.count, "keys": ev.keys.count, "pointer_samples": ev.pointer.count],
                              transcript: tr.map { "\($0.words.count) words (\($0.engine))" },
                              pendingProposals: e.proposals().filter { $0.status == .pending }.map(\.id),
                              canUndo: !st.undo.isEmpty, canRedo: !st.redo.isEmpty, lastRender: renders)
    }

    /// Import an existing movie (no input events) as a new project.
    public func importMovie(_ url: URL, name: String?, directory: String? = nil) async throws -> ProjectBundle {
        let asset = AVURLAsset(url: url)
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw ServiceError.invalid("\(url.path) has no video track") }
        let size = try await v.load(.naturalSize)
        let fps = Double(try await v.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let dest = RecordingSession.makeProjectURL(name: name ?? url.deletingPathExtension().lastPathComponent, directory: directory)
        let doc = ProjectDocument(name: dest.deletingPathExtension().lastPathComponent,
                                  media: MediaInfo(screen: "media/screen." + url.pathExtension, width: Int(size.width), height: Int(size.height), scale: 2,
                                                   duration: duration, frameRate: fps > 0 ? fps : 30))
        let b = try ProjectBundle.create(at: dest, document: doc, events: EventLog())
        try FileManager.default.copyItem(at: url, to: b.resolve(doc.media.screen))
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
            var d = doc; d.media.systemAudio = doc.media.screen
            try b.writeDocument(d)
        }
        return b
    }

    // MARK: Edits

    public func engine(_ b: ProjectBundle) -> Engine { Engine(bundle: b) }

    /// The document with a pending proposal's operations applied in memory (for previews/renders of proposals).
    public func document(_ b: ProjectBundle, proposal: String?) throws -> ProjectDocument {
        let e = Engine(bundle: b)
        guard let proposal else { return try e.document() }
        return try e.preview(try e.proposal(proposal).operations)
    }

    public func planZooms(_ b: ProjectBundle, options: ZoomPlanOptions, replaceAuto: Bool = true) throws -> (ops: [EditOperation], zooms: [ZoomSegment]) {
        let doc = try b.readDocument()
        let zooms = ZoomPlanner.plan(document: doc, events: b.readEvents(), options: options)
        var ops: [EditOperation] = []
        if replaceAuto && doc.timeline.zooms.contains(where: { $0.origin == .auto }) { ops.append(EditOperation(.clearZooms, origin: "auto")) }
        ops += zooms.map(EditOperation.addZoom)
        return (ops, zooms)
    }

    public func silences(_ b: ProjectBundle) async throws -> [TimeRange]? {
        let doc = try b.readDocument()
        guard let mic = doc.media.microphone else { return nil }
        let x = try await AudioAnalysis.decodeMono(url: b.resolve(mic), sampleRate: 16000)
        return AudioAnalysis.silences(x, sampleRate: 16000, minDuration: 0.6)
    }

    public func planCuts(_ b: ProjectBundle, options: CutPlanOptions) async throws -> (ops: [EditOperation], plan: CutPlan) {
        let doc = try b.readDocument()
        let plan = CutPlanner.plan(document: doc, events: b.readEvents(), transcript: b.readTranscript(), silences: try await silences(b), options: options)
        var ops: [EditOperation] = []
        if doc.timeline.cuts.contains(where: { $0.origin == .auto }) { ops.append(EditOperation(.clearCuts, origin: "auto")) }
        if doc.timeline.speeds.contains(where: { $0.origin == .auto }) { ops.append(EditOperation(.clearSpeeds, origin: "auto")) }
        ops += plan.cuts.map(EditOperation.addCut) + plan.speeds.map(EditOperation.setSpeed)
        if plan.inPoint != nil || plan.outPoint != nil { ops.append(EditOperation(.setTrim, start: plan.inPoint ?? doc.timeline.inPoint, end: plan.outPoint ?? doc.timeline.outPoint)) }
        return (ops, plan)
    }

    public func transcribe(_ b: ProjectBundle, locale: String, engine: Transcriber.Engine, source: String?) async throws -> Transcript {
        let t = try await Transcriber.transcribe(bundle: b, document: try b.readDocument(), locale: locale, engine: engine, source: source)
        try b.writeTranscript(t)
        return t
    }

    public func captionOps(_ b: ProjectBundle) throws -> [EditOperation] {
        guard let t = b.readTranscript() else { throw ServiceError.invalid("No transcript yet — run transcribe first.") }
        let doc = try b.readDocument()
        let segs = CaptionBuilder.segments(from: t.words, maxChars: doc.style.captions.maxCharsPerLine)
        return [EditOperation(.setCaptions, items: segs), .style("captions.enabled", .bool(true))]
    }

    public func quality(_ b: ProjectBundle, proposal: String?, targetDuration: Double?) throws -> QualityReport {
        let doc = try document(b, proposal: proposal)
        let (w, h) = RenderPlan.outputSize(document: doc)
        return EditQuality.report(document: doc, events: b.readEvents(), transcript: b.readTranscript(), targetDuration: targetDuration,
                                  outputWidth: Double(w), outputHeight: Double(h))
    }

    // MARK: Rendering

    func variantDocument(_ doc: ProjectDocument, _ variant: RenderVariant?) throws -> ProjectDocument {
        guard let variant else { return doc }
        var d = try OperationApplier.apply(variant.style, to: doc)
        if let a = variant.aspect { d.style.canvas.aspect = a }
        return d
    }

    public func renderFrame(_ b: ProjectBundle, time: Double, proposal: String?, variant: RenderVariant?, to url: URL? = nil, maxWidth: Int = 1280) async throws -> URL {
        let doc = try variantDocument(try document(b, proposal: proposal), variant)
        var (w, h) = RenderPlan.outputSize(document: doc, height: variant?.size ?? 1080)
        if w > maxWidth { h = Int(Double(h) * Double(maxWidth) / Double(w)); w = maxWidth }
        let comp = try await EditComposition.build(bundle: b, document: doc, width: w, height: h)
        comp.plan.motionSamples = 12   // stills: export-quality motion blur
        let img = try await Frames.image(comp, at: time)
        let out = url ?? b.rendersURL.appendingPathComponent("frames").appendingPathComponent(String(format: "frame-%.2f.png", time))
        try Frames.writePNG(img, to: out)
        return out
    }

    public func contactSheet(_ b: ProjectBundle, count: Int, proposal: String?, variant: RenderVariant?, to url: URL? = nil, times: [Double]? = nil) async throws -> (URL, [Double]) {
        let doc = try variantDocument(try document(b, proposal: proposal), variant)
        var (w, h) = RenderPlan.outputSize(document: doc, height: variant?.size ?? 1080)
        if w > 960 { h = Int(Double(h) * 960 / Double(w)); w = 960 }
        let comp = try await EditComposition.build(bundle: b, document: doc, width: w, height: h)
        comp.plan.motionSamples = 12
        let n = max(1, min(48, count))
        let ts = times ?? (0..<n).map { comp.duration * (Double($0) + 0.5) / Double(n) }
        var imgs: [(Double, CGImage)] = []
        for t in ts { imgs.append((t, try await Frames.image(comp, at: t))) }
        guard let sheet = Frames.contactSheet(images: imgs, columns: min(4, n), cellWidth: 400) else { throw RenderError.failed("contact sheet") }
        let out = url ?? b.rendersURL.appendingPathComponent("frames").appendingPathComponent("contact-\(Int(Date().timeIntervalSince1970)).jpg")
        try Frames.writeJPEG(sheet, to: out)
        return (out, ts)
    }

    public func render(_ b: ProjectBundle, variants: [RenderVariant], proposal: String?, author: Author, inspect: Bool = true,
                       progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> RenderManifest {
        let base = try document(b, proposal: proposal)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let id = "r-" + f.string(from: Date()) + "-" + String(IDs.make("x").suffix(4))
        let dir = b.rendersURL.appendingPathComponent(id, isDirectory: true)
        var outputs: [RenderOutput] = []
        for v in variants {
            let start = Date()
            let url = dir.appendingPathComponent("\(v.name).\(v.format.rawValue)")
            _ = try await Exporter.export(bundle: b, document: base, variant: v, to: url) { p in progress?(v.name, p) }
            let doc = try variantDocument(base, v)
            let (w, h) = RenderPlan.outputSize(document: doc, height: v.size)
            let expected = TimeMap(document: doc).outputDuration
            var report: RenderReport?
            if inspect { report = try await RenderInspector.inspect(url: url, expectedDuration: expected, expectedSize: (w, h)) }
            outputs.append(RenderOutput(variant: v.name, path: url.path, width: w, height: h, duration: report?.duration ?? expected,
                                        seconds: Date().timeIntervalSince(start), report: report))
        }
        let m = RenderManifest(id: id, createdAt: Date(), author: author, revision: base.revision, proposalID: proposal, outputs: outputs)
        try JSONCoding.encoder.encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        return m
    }

    public func renders(_ b: ProjectBundle) -> [RenderManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: b.rendersURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? JSONCoding.decoder.decode(RenderManifest.self, from: Data(contentsOf: $0.appendingPathComponent("manifest.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Gated actions

    /// Copy a rendered file out of the project. Overwriting an existing file is destructive → approval.
    public func export(file: URL, to destination: URL, author: Author, approvalID: String?) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { throw ServiceError.invalid("No such render: \(file.path)") }
        var dest = destination
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue { dest = dest.appendingPathComponent(file.lastPathComponent) }
        if fm.fileExists(atPath: dest.path) {
            try approvals.authorize(action: "export_overwrite", risk: .destructive, summary: "Overwrite \(dest.path) with \(file.lastPathComponent)",
                                    parameters: .object(["file": .string(file.path), "destination": .string(dest.path)]), author: author, approvalID: approvalID)
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: dest)
        return dest
    }

    /// Move a project to the Trash (destructive → approval for agents and users alike).
    public func deleteProject(_ b: ProjectBundle, author: Author, approvalID: String?) throws -> URL? {
        try approvals.authorize(action: "delete_project", risk: .destructive, summary: "Move project \(b.url.lastPathComponent) to the Trash",
                                parameters: .object(["project": .string(b.url.path)]), author: author, approvalID: approvalID)
        var result: NSURL?
        try FileManager.default.trashItem(at: b.url, resultingItemURL: &result)
        return result as URL?
    }

    // MARK: Recording (in-process sessions)

    private var sessions: [String: RecordingSession] = [:]
    private let lock = NSLock()

    public func startRecording(options: RecordingOptions, author: Author, approvalID: String?) async throws -> (id: String, session: RecordingSession) {
        var params: [String: JSONValue] = [:]
        if let d = options.displayID { params["display_id"] = .number(Double(d)) }
        if let w = options.windowID { params["window_id"] = .number(Double(w)) }
        params["microphone"] = .bool(options.microphone)
        params["system_audio"] = .bool(options.systemAudio)
        if let m = options.maxDuration { params["max_duration"] = .number(m) }
        let what = options.windowID.map { "window \($0)" } ?? "display \(options.displayID.map(String.init) ?? "main")"
        try approvals.authorize(action: "record_start", risk: .capture, summary: "Record \(what)\(options.microphone ? " with microphone" : "")",
                                parameters: .object(params), author: author, approvalID: approvalID)
        let s = try await RecordingSession(options: options, author: author)
        try await s.start()
        let id = IDs.make("rec")
        lock.withLock { sessions[id] = s }
        SessionRegistry.register(id: id, project: s.bundle.url.path, author: author)
        return (id, s)
    }

    /// Start a recording from a filter the user picked in the system picker (always user-initiated: no approval).
    public func startRecording(filter: SCContentFilter, options: RecordingOptions) async throws -> (id: String, session: RecordingSession) {
        let s = try RecordingSession(filter: filter, options: options, author: .app)
        try await s.start()
        let id = IDs.make("rec")
        lock.withLock { sessions[id] = s }
        SessionRegistry.register(id: id, project: s.bundle.url.path, author: .app)
        return (id, s)
    }

    public func session(_ id: String?) -> (String, RecordingSession)? {
        lock.withLock {
            if let id { return sessions[id].map { (id, $0) } }
            return sessions.first(where: { $0.value.isRecording }).map { ($0.key, $0.value) }
        }
    }

    public func stopRecording(_ id: String?) async throws -> ProjectBundle {
        guard let (sid, s) = session(id) else { throw ServiceError.invalid("No active recording\(id.map { " \($0)" } ?? "")") }
        let b = try await s.stop()
        lock.withLock { _ = sessions.removeValue(forKey: sid) }
        SessionRegistry.unregister(id: sid)
        return b
    }
}

/// Visible record of who is recording right now (the app shows it), across processes.
public enum SessionRegistry {
    public struct Entry: Codable, Sendable { public var id: String; public var pid: Int32; public var project: String; public var author: Author; public var startedAt: Date }
    static var dir: URL { GlintPaths.support.appendingPathComponent("sessions", isDirectory: true) }
    public static func register(id: String, project: String, author: Author) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = Entry(id: id, pid: ProcessInfo.processInfo.processIdentifier, project: project, author: author, startedAt: Date())
        try? JSONCoding.encoder.encode(e).write(to: dir.appendingPathComponent("\(id).json"))
    }
    public static func unregister(id: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json")) }
    public static func active() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { u -> Entry? in
            guard let e = try? JSONCoding.decoder.decode(Entry.self, from: Data(contentsOf: u)) else { return nil }
            if kill(e.pid, 0) != 0 { try? FileManager.default.removeItem(at: u); return nil }   // stale
            return e
        }
    }
}
