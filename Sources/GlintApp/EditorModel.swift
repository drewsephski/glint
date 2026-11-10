import Foundation
import SwiftUI
import AVFoundation
import Observation
import GlintCore
import GlintRender
import GlintAgent

enum Selection: Hashable {
    case zoom(String), cut(String), speed(String), caption(String), voice(String)
    case range(Double, Double)      // source-time range selected on the video track
}

/// One open project. All edits go through the shared Engine (author: the app), and the model polls the bundle so
/// edits made concurrently by the CLI or an MCP agent appear live.
@MainActor @Observable
final class EditorModel {
    let bundle: ProjectBundle
    let service: GlintService
    /// The agent chat for this project (kept here so a turn survives switching sidebar tabs).
    let chat: ChatModel
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
    /// Scenes, on-screen text and narration lines (analysis/storyboard.json). Polled like the document.
    private(set) var storyboard: Storyboard?
    private(set) var voices: [Voice] = []
    private(set) var voicesError: String?
    private var frameCache: [String: NSImage] = [:]
    private var storyboardModified: Date?
    let previewPlayer = AVPlayer()
    private var lastModified: Date?
    private var poller: Timer?
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var previewRevision = -1

    init(bundle: ProjectBundle, service: GlintService) throws {
        self.bundle = bundle
        self.service = service
        chat = ChatModel(bundle: bundle)
        doc = try bundle.readDocument()
        events = bundle.readEvents()
        transcript = bundle.readTranscript()
        storyboard = bundle.readStoryboard()
        storyboardModified = modDate(bundle.storyboardURL)
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
        chat.stop()
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

    private func modDate(_ url: URL? = nil) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: (url ?? bundle.documentURL).path)[.modificationDate]) as? Date
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
        let sm = modDate(bundle.storyboardURL)
        if sm != storyboardModified { storyboardModified = sm; storyboard = bundle.readStoryboard() }
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
        case .voice(let id): apply([EditOperation(.removeVoiceover, id: id)])
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

    // MARK: Narration (scenes → script → voice)

    var hasAnthropicKey: Bool { Secrets.get(.anthropic) != nil }
    var hasElevenLabsKey: Bool { Secrets.get(.elevenlabs) != nil }

    private func progressSink() -> @Sendable (String) -> Void {
        { msg in Task { @MainActor [weak self] in self?.busy = msg } }
    }

    func analyzeScenes() {
        busy = "Reading scenes…"
        Task {
            defer { busy = nil }
            do {
                storyboard = try await service.analyzeScenes(bundle, progress: progressSink())
                storyboardModified = modDate(bundle.storyboardURL)
                frameCache = [:]
            } catch { banner = "\(error)" }
        }
    }

    func writeNarration(brief: String?, onlyMissing: Bool = false) {
        busy = "Writing the script…"
        Task {
            defer { busy = nil }
            do {
                var o = NarrationOptions()
                o.brief = brief?.isEmpty == false ? brief : storyboard?.brief
                o.onlyMissing = onlyMissing
                if let brief, !brief.isEmpty, storyboard != nil { _ = try service.setNarration(bundle, lines: [:], brief: brief) }
                storyboard = try await service.writeNarration(bundle, options: o, author: .app, approvalID: nil)
                storyboardModified = modDate(bundle.storyboardURL)
            } catch { banner = "\(error)" }
        }
    }

    func setNarration(_ sceneID: String, _ text: String) {
        guard storyboard?.scenes.first(where: { $0.id == sceneID })?.narration ?? "" != text else { return }
        do { storyboard = try service.setNarration(bundle, lines: [sceneID: text]); storyboardModified = modDate(bundle.storyboardURL) }
        catch { banner = "\(error)" }
    }

    func loadVoices() async {
        guard hasElevenLabsKey else { return }
        do { voices = try await service.voices(); voicesError = nil } catch { voicesError = "\(error)" }
    }

    func previewVoice(_ v: Voice) {
        guard let s = v.previewURL, let url = URL(string: s) else { return }
        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        previewPlayer.play()
    }
    func stopVoicePreview() { previewPlayer.pause() }

    func generateVoiceover(voice: Voice?, fit: Bool, captions: Bool) {
        busy = "Generating the voice…"
        Task {
            defer { busy = nil }
            do {
                let r = try await service.voiceover(bundle, voice: voice?.id, fit: fit, captions: captions, author: .app, approvalID: nil, progress: progressSink())
                apply(r.operations, label: "Voiceover: \(r.clips.count) clip\(r.clips.count == 1 ? "" : "s") (\(r.voiceName))")
                if let note = r.fitNotes.first, r.fitNotes.count == 1 { banner = note } else if r.fitNotes.count > 1 { banner = "\(r.fitNotes.count) scenes retimed to the narration" }
            } catch { banner = "\(error)" }
        }
    }

    func fitNarration() {
        do {
            let (ops, notes) = try service.fitToNarration(bundle)
            if ops.isEmpty { banner = "The picture already fits the narration"; return }
            apply(ops, label: "Fit picture to narration")
            banner = notes.first
        } catch { banner = "\(error)" }
    }

    func frameImage(_ scene: GlintCore.Scene) -> NSImage? {
        guard let f = scene.frame else { return nil }
        if let c = frameCache[f] { return c }
        guard let img = NSImage(contentsOf: bundle.resolve(f)) else { return nil }
        frameCache[f] = img
        return img
    }

    /// Where a clip sits on the recording-time timeline: it starts at a source instant and plays at 1× in output time.
    func sourceSpan(of clip: VoiceoverClip) -> TimeRange {
        let m = map
        let o = m.outputClamped(forSource: clip.start)
        return TimeRange(clip.start, max(clip.start + 0.05, m.source(forOutput: o + clip.duration)))
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
