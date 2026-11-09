import Foundation
import SwiftUI
import AVFoundation
import Observation
import GlintCore
import GlintRender
import GlintAgent

enum Selection: Hashable {
    case zoom(String), cut(String), speed(String), caption(String)
    case range(Double, Double)      // source-time range selected on the video track
}

/// One open project. All edits go through the shared Engine (author: the app), and the model polls the bundle so
/// edits made concurrently by the CLI or an MCP agent appear live.
@MainActor @Observable
final class EditorModel {
    let bundle: ProjectBundle
    let service: GlintService
    private(set) var doc: ProjectDocument
    private(set) var events: EventLog
    private(set) var transcript: Transcript?
    private(set) var history: [HistoryRecord] = []
    private(set) var proposals: [Proposal] = []
    private(set) var renders: [RenderManifest] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    let player = AVPlayer()
    var currentTime: Double = 0        // output seconds
    var isPlaying = false
    var selection: Selection?
    var previewProposal: String? { didSet { if oldValue != previewProposal { schedulePreviewRebuild() } } }
    var banner: String?
    var busy: String?
    private(set) var thumbnails: [(Double, CGImage)] = []
    private(set) var waveform: [Float] = []
    private var lastModified: Date?
    private var poller: Timer?
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var previewRevision = -1

    init(bundle: ProjectBundle, service: GlintService) throws {
        self.bundle = bundle
        self.service = service
        doc = try bundle.readDocument()
        events = bundle.readEvents()
        transcript = bundle.readTranscript()
        refreshSideState()
        lastModified = modDate()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
        poller = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        schedulePreviewRebuild()
        Task { await loadThumbnails() }
        Task { await loadWaveform() }
    }

    func close() {
        poller?.invalidate()
        if let o = timeObserver { player.removeTimeObserver(o) }
        player.pause()
    }

    var map: TimeMap { TimeMap(document: previewDocument) }
    var previewDocument: ProjectDocument {
        if let id = previewProposal, let p = proposals.first(where: { $0.id == id }), let d = try? OperationApplier.apply(p.operations, to: doc) { return d }
        return doc
    }
    var outputDuration: Double { map.outputDuration }
    var sourceTime: Double { map.source(forOutput: currentTime) }

    private func modDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: bundle.documentURL.path)[.modificationDate]) as? Date
    }

    /// Picks up changes from any process (CLI / MCP agent) and new proposals.
    private func poll() {
        let m = modDate()
        if m != lastModified {
            lastModified = m
            if let d = try? bundle.readDocument(), d != doc {
                let external = history.last.map { _ in true } ?? true
                doc = d
                if external, let last = Engine(bundle: bundle).history().last, last.author.kind == .agent {
                    banner = "\(last.author.name): \(last.label)"
                }
                schedulePreviewRebuild()
            }
            transcript = bundle.readTranscript()
            events = bundle.readEvents()
        }
        refreshSideState()
    }

    private func refreshSideState() {
        let e = Engine(bundle: bundle)
        let h = e.history()
        if h.count != history.count { history = h }
        let st = e.stacks(h)
        canUndo = !st.undo.isEmpty; canRedo = !st.redo.isEmpty
        let ps = e.proposals()
        if ps != proposals { proposals = ps }
        if previewProposal != nil, !proposals.contains(where: { $0.id == previewProposal && $0.status == .pending }) { previewProposal = nil }
    }

    // MARK: Edits

    func apply(_ ops: [EditOperation], label: String? = nil) {
        do {
            try Engine(bundle: bundle).apply(ops, label: label, author: .app)
            afterEdit()
        } catch { banner = "\(error)" }
    }

    func style(_ path: String, _ value: JSONValue) { apply([.style(path, value)], label: "Set \(path)") }

    func undo() { do { try Engine(bundle: bundle).undo(author: .app); afterEdit() } catch { banner = "\(error)" } }
    func redo() { do { try Engine(bundle: bundle).redo(author: .app); afterEdit() } catch { banner = "\(error)" } }
    func revert(_ id: String) { do { try Engine(bundle: bundle).revert(id, author: .app); afterEdit() } catch { banner = "\(error)" } }

    func acceptProposal(_ id: String) {
        do { try Engine(bundle: bundle).applyProposal(id, author: .app); previewProposal = nil; afterEdit() } catch { banner = "\(error)" }
    }
    func rejectProposal(_ id: String) {
        do { _ = try Engine(bundle: bundle).rejectProposal(id, author: .app); previewProposal = nil; refreshSideState() } catch { banner = "\(error)" }
    }

    private func afterEdit() {
        if let d = try? bundle.readDocument() { doc = d }
        lastModified = modDate()
        refreshSideState()
        schedulePreviewRebuild()
    }

    func deleteSelection() {
        switch selection {
        case .zoom(let id): apply([EditOperation(.removeZoom, id: id)])
        case .cut(let id): apply([EditOperation(.removeCut, id: id)])
        case .speed(let id): apply([EditOperation(.removeSpeed, id: id)])
        case .caption(let id): apply([EditOperation(.removeCaption, id: id)])
        case .range(let a, let b): apply([EditOperation(.addCut, start: a, end: b, reason: "cut in editor")])
        case nil: return
        }
        selection = nil
    }

    // MARK: Planning (same service calls agents use)

    func autoZoom() {
        do {
            let (ops, zooms) = try service.planZooms(bundle, options: ZoomPlanOptions())
            if zooms.isEmpty { banner = "No clicks or typing to zoom on"; return }
            apply(ops, label: "Auto zoom: \(zooms.count) zooms")
        } catch { banner = "\(error)" }
    }

    func tighten() {
        busy = "Finding pauses…"
        Task {
            defer { busy = nil }
            do {
                let (ops, plan) = try await service.planCuts(bundle, options: CutPlanOptions())
                if ops.isEmpty { banner = "Nothing worth cutting"; return }
                apply(ops, label: "Tighten: \(plan.cuts.count) cuts, \(plan.speeds.count) speed-ups")
            } catch { banner = "\(error)" }
        }
    }

    func captions() {
        busy = "Transcribing on-device…"
        Task {
            defer { busy = nil }
            do {
                if bundle.readTranscript() == nil { transcript = try await service.transcribe(bundle, locale: "en-US", engine: .auto, source: nil) }
                apply(try service.captionOps(bundle), label: "Captions")
            } catch { banner = "\(error)" }
        }
    }

    // MARK: Playback

    func schedulePreviewRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.rebuildPreview()
        }
    }

    private func rebuildPreview() async {
        let d = previewDocument
        let (w, h) = RenderPlan.outputSize(document: d, height: 1080)
        let scale = min(1, 1600.0 / Double(w))
        do {
            let comp = try await EditComposition.build(bundle: bundle, document: d, width: Int(Double(w) * scale), height: Int(Double(h) * scale))
            guard !Task.isCancelled else { return }
            let wasPlaying = player.rate != 0
            let t = min(currentTime, max(0, comp.duration - 0.05))
            player.replaceCurrentItem(with: comp.playerItem())
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch { banner = "Preview: \(error)" }
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else {
            if currentTime >= outputDuration - 0.05 { seek(output: 0) }
            player.play()
        }
    }

    func seek(output t: Double) {
        currentTime = max(0, min(outputDuration, t))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(source t: Double) { seek(output: map.outputClamped(forSource: t)) }

    // MARK: Media summaries for the timeline

    private func loadThumbnails() async {
        let asset = AVURLAsset(url: bundle.resolve(doc.media.screen))
        let g = AVAssetImageGenerator(asset: asset)
        g.maximumSize = CGSize(width: 220, height: 140)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let n = max(4, min(40, Int(doc.media.duration / 1.5)))
        var out: [(Double, CGImage)] = []
        for i in 0..<n {
            let t = doc.media.duration * (Double(i) + 0.5) / Double(n)
            if let img = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append((t, img)) }
        }
        thumbnails = out
    }

    private func loadWaveform() async {
        guard let path = doc.media.microphone ?? doc.media.systemAudio else { return }
        let url = bundle.resolve(path)
        let samples = (try? await GlintAnalysisBridge.decode(url)) ?? []
        guard !samples.isEmpty else { return }
        let buckets = 600
        let per = max(1, samples.count / buckets)
        waveform = stride(from: 0, to: samples.count, by: per).map { i in
            let slice = samples[i..<min(samples.count, i + per)]
            return slice.reduce(0) { max($0, abs($1)) }
        }
    }
}

import GlintAnalysis
enum GlintAnalysisBridge {
    static func decode(_ url: URL) async throws -> [Float] { try await AudioAnalysis.decodeMono(url: url, sampleRate: 8000) }
}
