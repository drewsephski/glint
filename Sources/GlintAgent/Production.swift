import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import GlintCore
import GlintRender
import GlintAnalysis

/// Facts about a media file probed on import.
public struct MediaProbe: Codable, Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var hasVideo: Bool
    public var hasAudio: Bool
}

// MARK: - Importing shots, audio and takes

extension GlintService {
    public func probe(_ url: URL) async throws -> MediaProbe {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ServiceError.invalid("No such file: \(url.path)") }
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let d = try await a.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw ServiceError.invalid("\(url.lastPathComponent) has no playable duration") }
        var w = 0, h = 0
        let v = try await a.loadTracks(withMediaType: .video).first
        if let v {
            let size = try await v.load(.naturalSize)
            let t = try await v.load(.preferredTransform)
            let r = CGRect(origin: .zero, size: size).applying(t)
            w = Int(abs(r.width).rounded()); h = Int(abs(r.height).rounded())
        }
        let audio = !(try await a.loadTracks(withMediaType: .audio)).isEmpty
        return MediaProbe(duration: d, width: w, height: h, hasVideo: v != nil, hasAudio: audio)
    }

    /// Copy a file into the bundle under `folder`, keeping an existing identical copy. Returns the relative path.
    func copyIn(_ src: URL, to folder: URL, bundle b: ProjectBundle) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension.lowercased()
        var dest = folder.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            if let a = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int, let b2 = try? fm.attributesOfItem(atPath: src.path)[.size] as? Int, a == b2,
               fm.contentsEqual(atPath: dest.path, andPath: src.path) { break }
            dest = folder.appendingPathComponent("\(base) \(i).\(ext)"); i += 1
        }
        if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
        return String(dest.path.dropFirst(b.url.path.count + 1))
    }

    /// An operation that inserts a movie as a new shot (copied into `media/clips/`). `at` is a program time
    /// (nil = append). Media is never modified; the original file is left where it was.
    public func importClip(_ b: ProjectBundle, file: URL, at: Double?, name: String?, scene: String?, start: Double? = nil, end: Double? = nil) async throws -> (EditOperation, MediaClip) {
        let p = try await probe(file)
        guard p.hasVideo, p.width > 0, p.height > 0 else { throw ServiceError.invalid("\(file.lastPathComponent) has no video track; import it as audio instead") }
        let rel = try copyIn(file, to: b.clipsURL, bundle: b)
        let s = max(0, start ?? 0), e = min(p.duration, end ?? p.duration)
        guard e - s >= 0.1 else { throw ServiceError.invalid("The clip range is shorter than 0.1s") }
        let clip = MediaClip(name: name ?? file.deletingPathExtension().lastPathComponent, path: rel, mediaStart: s, mediaEnd: e,
                             audio: p.hasAudio ? [rel] : [], scene: scene, width: p.width, height: p.height, fileDuration: p.duration, origin: .manual)
        return (EditOperation(.insertClip, time: at, shot: clip), clip)
    }

    /// An operation that adds a music bed, a recorded voiceover or a sound effect (copied into `media/audio/`).
    public func importAudio(_ b: ProjectBundle, file: URL, kind: AudioClip.Kind, at: Double, name: String?, gain: Double? = nil, loop: Bool? = nil) async throws -> (EditOperation, AudioClip) {
        let p = try await probe(file)
        guard p.hasAudio else { throw ServiceError.invalid("\(file.lastPathComponent) has no audio track") }
        let rel = try copyIn(file, to: b.mediaURL.appendingPathComponent("audio", isDirectory: true), bundle: b)
        let clip = AudioClip(kind: kind, name: name ?? file.deletingPathExtension().lastPathComponent, path: rel, start: max(0, at),
                             fileDuration: p.duration, gain: gain, loop: loop)
        return (EditOperation.add(.addAudio, clip), clip)
    }

    public struct TakeRef: Codable, Sendable {
        public var take: String
        public var name: String
        public var screen: String
        public var audio: [String]
        public var events: String?
        public var duration: Double
        public var width: Int
        public var height: Int
        public var markers: [Marker]
        public var evidence: [EvidenceRecord]
    }

    /// Bring another Glint recording into this project as a take (`media/takes/<take id>/`): its movie, audio,
    /// input events (cursor images renamed so they can't collide) and the evidence recorded with it.
    public func importTake(_ take: ProjectBundle, into b: ProjectBundle) throws -> TakeRef {
        let fm = FileManager.default
        let td = try take.readDocument()
        guard take.url != b.url else { throw ServiceError.invalid("A project can't be a take of itself") }
        let dir = b.takesURL.appendingPathComponent(td.id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func bring(_ rel: String?) throws -> String? {
            guard let rel else { return nil }
            let src = take.resolve(rel)
            guard fm.fileExists(atPath: src.path) else { return nil }
            let dest = dir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
            return String(dest.path.dropFirst(b.url.path.count + 1))
        }
        guard let screen = try bring(td.media.screen) else { throw RenderError.missingMedia(take.resolve(td.media.screen).path) }
        let audio = try [td.media.microphone, td.media.systemAudio].compactMap { try bring($0) }
        // Events with cursor images renamed under the take's ID.
        var ev = take.readEvents()
        let prefix = "\(td.id)-"
        try fm.createDirectory(at: b.cursorsURL, withIntermediateDirectories: true)
        for c in ev.cursors {
            let src = take.cursorsURL.appendingPathComponent("\(c.id).png"), dest = b.cursorsURL.appendingPathComponent("\(prefix)\(c.id).png")
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
        }
        ev.cursors = ev.cursors.map { var x = $0; x.id = prefix + $0.id; return x }
        ev.cursorChanges = ev.cursorChanges.map { var x = $0; x.cursorID = prefix + $0.cursorID; return x }
        let evURL = dir.appendingPathComponent("events.json")
        try JSONCoding.compactEncoder.encode(ev).write(to: evURL, options: .atomic)
        let evidence = take.readEvidence().records.map { r -> EvidenceRecord in var x = r; x.take = td.id; return x }
        return TakeRef(take: td.id, name: td.name, screen: screen, audio: audio, events: String(evURL.path.dropFirst(b.url.path.count + 1)),
                       duration: td.media.duration, width: td.media.width, height: td.media.height,
                       markers: (td.timeline.markers + ev.markers).sorted { $0.time < $1.time }, evidence: evidence)
    }
}

// MARK: - Captions: subtitles and transcript edits

extension GlintService {
    /// SRT/VTT for the edited output (times match the rendered video). Written to `renders/subtitles/`.
    public func exportSubtitles(_ b: ProjectBundle, format: Subtitles.Format, proposal: String? = nil) throws -> (URL, Int) {
        let doc = try document(b, proposal: proposal)
        let cues = Subtitles.cues(document: doc)
        guard !cues.isEmpty else { throw ServiceError.invalid("There are no visible captions to export. Generate or import captions first.") }
        let dir = b.rendersURL.appendingPathComponent("subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(doc.name.replacingOccurrences(of: "/", with: "-")).\(format.rawValue)")
        try Subtitles.format(cues, as: format).write(to: url, atomically: true, encoding: .utf8)
        return (url, cues.count)
    }

    /// set_captions from an SRT/VTT file (times are the output timeline unless time_base is "source").
    public func importSubtitles(_ b: ProjectBundle, file: URL, timeBase: String = "output") throws -> [EditOperation] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw ServiceError.invalid("Can't read \(file.path) as UTF-8 text") }
        let doc = try b.readDocument()
        let cues = try Subtitles.parse(text)
        let segs = Subtitles.captions(from: cues, document: doc, timeBase: timeBase)
        guard !segs.isEmpty else { throw ServiceError.invalid("None of the cues fall inside the edit") }
        return [EditOperation(.setCaptions, items: segs), .style("captions.enabled", .bool(true))]
    }

    /// Cuts that delete transcript words, by index ranges or by phrase. Returns the cuts and the removed text.
    public func transcriptCuts(_ b: ProjectBundle, ranges: [(Int, Int)], phrase: String?) throws -> (ops: [EditOperation], removed: [String]) {
        let doc = try b.readDocument()
        guard let t = b.programTranscript(for: doc), !t.words.isEmpty else { throw ServiceError.invalid("No transcript yet — run transcribe first.") }
        var rs = ranges
        if let phrase, !phrase.isEmpty {
            let found = TranscriptEdit.find(phrase, in: t.words)
            guard !found.isEmpty else { throw ServiceError.invalid("“\(phrase)” isn't in the transcript") }
            rs += found
        }
        guard !rs.isEmpty else { throw ServiceError.invalid("Pass word ranges or a phrase to remove") }
        let cuts = try TranscriptEdit.cuts(words: t.words, ranges: rs)
        let removed = rs.map { r in t.words[min(r.0, r.1)...max(r.0, r.1)].map(\.text).joined(separator: " ") }
        return (cuts.map { EditOperation(.addCut, start: $0.start, end: $0.end, reason: "transcript edit", origin: "manual") }, removed)
    }
}

// MARK: - Style presets

extension GlintService {
    static var presetsURL: URL { GlintPaths.support.appendingPathComponent("presets", isDirectory: true) }

    public func presets() -> [StylePreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.presetsURL, includingPropertiesForKeys: nil)) ?? []
        let saved = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONCoding.decoder.decode(StylePreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
        return StylePreset.builtIns + saved.filter { s in !StylePreset.builtIns.contains { $0.name == s.name } }
    }

    public func preset(_ name: String) throws -> StylePreset {
        guard let p = presets().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ServiceError.invalid("No preset \(name). Presets: \(presets().map(\.name).joined(separator: ", "))")
        }
        return p
    }

    /// Save a project's look (selected style sections) as a reusable preset.
    public func savePreset(name: String, summary: String?, from b: ProjectBundle, sections: [String]? = nil) throws -> StylePreset {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _\-]{0,40}$"#, options: .regularExpression) != nil else { throw ServiceError.invalid("Preset names are 1–41 letters, digits, spaces, _ or -") }
        guard !StylePreset.builtIns.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { throw ServiceError.invalid("\(n) is a built-in preset name") }
        let style = try JSONValue.from(try b.readDocument().style)
        // Narration voice and per-project audio levels aren't a "look": leave them out unless asked.
        let keys = sections ?? ["background", "frame", "cursor", "zoom", "captions", "canvas", "facecam"]
        var o: [String: JSONValue] = [:]
        for k in keys { guard let v = style[k] else { throw ServiceError.invalid("Unknown style section \(k)") }; o[k] = v }
        let p = StylePreset(name: n, summary: summary ?? "Saved from \(b.url.deletingPathExtension().lastPathComponent)", style: .object(o))
        try FileManager.default.createDirectory(at: Self.presetsURL, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(p).write(to: Self.presetsURL.appendingPathComponent("\(n).json"), options: .atomic)
        return p
    }

    public func deletePreset(name: String) throws {
        let p = try preset(name)
        guard !p.builtIn else { throw ServiceError.invalid("Built-in presets can't be deleted") }
        try FileManager.default.removeItem(at: Self.presetsURL.appendingPathComponent("\(p.name).json"))
    }
}

// MARK: - Recipes and evidence

public struct SceneRefreshResult: Codable, Sendable {
    public var scene: String
    public var take: String
    public var range: TimeRange
    public var operation: EditOperation
    public var applied: EditResult?
    public var proposalID: String?
    public var dropped: [String]
    public var retimedProportionally: [String]
    public var importedEvidence: Int
    public var notes: [String]
}

extension GlintService {
    public func saveRecipe(_ b: ProjectBundle, _ recipe: DemoRecipe) throws -> DemoRecipe {
        try recipe.validate()
        return try b.withLock {
            let r = recipe.revised(from: b.readRecipe())
            try b.writeRecipe(r)
            return r
        }
    }

    public func recipe(_ b: ProjectBundle) throws -> DemoRecipe {
        guard let r = b.readRecipe() else { throw ServiceError.invalid("This project has no recipe yet. Save one with glint_recipe_save.") }
        return r
    }

    /// Operations that split the recording into one shot per recipe scene, from `scene:<id>` markers.
    public func recipeBindOps(_ b: ProjectBundle) throws -> (ops: [EditOperation], ranges: [(scene: String, range: TimeRange)]) {
        let r = try recipe(b)
        let doc = try b.readDocument()
        guard doc.isSingleRecording, doc.effectiveClips.count == 1 else {
            throw ServiceError.invalid("Scenes can only be bound on a project that is still one recording. Refresh scenes with glint_recipe_refresh_scene instead.")
        }
        let markers = (doc.timeline.markers + b.readEvents().markers)
        let ranges = RecipeBinding.ranges(recipe: r, markers: markers, end: doc.duration)
        guard !ranges.isEmpty else {
            throw ServiceError.invalid("No scene markers found. While recording, mark each scene's start with glint_record_mark note \"scene:<id>\" (ids: \(r.scenes.map(\.id).joined(separator: ", "))).")
        }
        var ops: [EditOperation] = []
        var firstID = MediaClip.primaryID
        var used = Set<String>([MediaClip.primaryID])
        for (i, x) in ranges.enumerated() {
            if x.range.start > 0.05 {
                var id = "clip_\(x.scene)"
                while used.contains(id) { id += "_" }
                used.insert(id)
                ops.append(EditOperation(.splitClip, id: id, time: x.range.start))
                if i == 0 { firstID = id }
                ops.append(EditOperation(.updateClip, id: id, text: r.scene(x.scene)?.title, scene: x.scene))
            } else {
                ops.append(EditOperation(.updateClip, id: firstID, text: r.scene(x.scene)?.title, scene: x.scene))
            }
        }
        return (ops, ranges)
    }

    /// Replace a scene's shots with the same scene from another recording (a take). Manual edits elsewhere stay on
    /// their content; manual items inside the scene are carried proportionally; automatic ones are dropped.
    public func refreshScene(_ b: ProjectBundle, scene: String, take tb: ProjectBundle, range: TimeRange?, author: Author,
                             expectedRevision: Int?, apply: Bool) throws -> SceneRefreshResult {
        let r = try recipe(b)
        guard let rs = r.scene(scene) else { throw ServiceError.invalid("Scene \(scene) isn't in the recipe (\(r.scenes.map(\.id).joined(separator: ", ")))") }
        let doc = try b.readDocument()
        if let e = expectedRevision, e != doc.revision { throw EditError.staleRevision(expected: e, actual: doc.revision) }
        guard doc.effectiveClips.contains(where: { $0.scene == scene }) else {
            throw ServiceError.invalid("Scene \(scene) has no shot in this edit yet. Bind scenes first (glint_recipe_build).")
        }
        let td = try tb.readDocument()
        var sceneRange = range
        if sceneRange == nil {
            let markers = td.timeline.markers + tb.readEvents().markers
            sceneRange = RecipeBinding.ranges(recipe: r, markers: markers, end: td.media.duration).first { $0.scene == scene }?.range
        }
        guard let span = sceneRange else {
            throw ServiceError.invalid("The take has no “scene:\(scene)” marker. Pass start/end, or mark the scene while recording.")
        }
        guard span.start >= 0, span.end <= td.media.duration + 0.01, span.duration >= 0.1 else { throw ServiceError.invalid("The scene range is outside the take (0–\(td.media.duration)s)") }
        let ref = try importTake(tb, into: b)
        let shot = MediaClip(name: rs.title, path: ref.screen, mediaStart: span.start, mediaEnd: min(span.end, ref.duration), audio: ref.audio, events: ref.events,
                             scene: scene, take: ref.take, width: ref.width, height: ref.height, fileDuration: ref.duration, origin: .agent,
                             reason: "refreshed from \(ref.name)")
        let op = EditOperation(.replaceClip, shot: shot, scene: scene)
        let (replacement, report) = try ClipEditor.preview(op, on: doc)
        // Bring the take's evidence for this scene.
        let originalEvidence = tb.readEvidence()
        let incoming = ref.evidence.filter { $0.scene == scene }.map { imported in
            // Only transfer the context of an actually checked, matching recipe. Legacy/unbound evidence remains
            // visible in the log but cannot silently certify a new edit. OCR must examine the refreshed output.
            guard imported.source != .ocr,
                  let original = originalEvidence.records.first(where: { $0.id == imported.id }),
                  original.isCurrent(recipe: r, document: td) else { return imported }
            return imported.bound(to: r, document: replacement)
        }
        if !incoming.isEmpty {
            try b.withLock {
                var log = b.readEvidence()
                for e in incoming where !log.records.contains(where: { $0.id == e.id }) { log.records.append(e.normalized()) }
                try b.writeEvidence(log)
            }
        }
        var notes = ["Re-verify scene \(scene): evidence from the previous take no longer counts."]
        if doc.timeline.voiceover.contains(where: { $0.scene == scene }) { notes.append("Narration for this scene was kept; run glint_fit_narration so the picture fits it again.") }
        if !report.retimedProportionally.isEmpty { notes.append("\(report.retimedProportionally.count) manual item(s) inside the scene were placed proportionally — check them.") }
        var result = SceneRefreshResult(scene: scene, take: ref.take, range: span, operation: op, applied: nil, proposalID: nil, dropped: report.dropped,
                                        retimedProportionally: report.retimedProportionally, importedEvidence: incoming.count, notes: notes)
        let e = engine(b)
        if apply {
            result.applied = try e.apply([op], label: "Refresh scene “\(rs.title)” from \(ref.name)", author: author, expectedRevision: expectedRevision ?? doc.revision)
        } else {
            result.proposalID = try e.propose(title: "Refresh scene “\(rs.title)”", rationale: notes.joined(separator: "\n"), operations: [op], author: author).id
        }
        return result
    }

    /// Record evidence reported by a driver or a person. Rules from `EvidenceRecord.normalized` apply.
    public func recordEvidence(_ b: ProjectBundle, _ input: EvidenceRecord) throws -> EvidenceRecord {
        try b.withLock {
            let r = try recipe(b)
            guard let scene = r.scene(input.scene) else { throw ServiceError.invalid("Scene \(input.scene) isn't in the recipe") }
            guard scene.expectations.contains(where: { $0.id == input.expectation }) else {
                throw ServiceError.invalid("Scene \(scene.id) has no expectation \(input.expectation)")
            }
            let doc = try b.readDocument()
            var rec = input
            if rec.take == nil {
                let takes = Set(doc.effectiveClips.filter { $0.scene == scene.id }.map { $0.take ?? "primary" })
                rec.take = takes.count == 1 ? takes.first! : "primary"
            }
            rec = rec.normalized().bound(to: r, document: doc)
            var log = b.readEvidence()
            log.records.append(rec)
            try b.writeEvidence(log)
            return rec
        }
    }

    /// OCR uses a kept frame of the rendered edit, including masks and overlays. Optional snapshots let production
    /// jobs verify the exact document/recipe they exported even when the live project changes during the render.
    public func verifyRecipe(_ b: ProjectBundle, author: Author, ocr: Bool = true, document: ProjectDocument? = nil,
                             recipe snapshotRecipe: DemoRecipe? = nil, renderedURL: URL? = nil) async throws -> RecipeReport {
        let r = try snapshotRecipe ?? recipe(b)
        let doc = try document ?? b.readDocument()
        var outputEvidence = Set<String>()
        if ocr {
            let layout = ClipLayout(document: doc)
            let map = TimeMap(document: doc)
            var new: [EvidenceRecord] = []
            let existing = b.readEvidence()
            var composition: EditComposition?
            for scene in r.scenes {
                let kept = layout.segments.filter { $0.clip.scene == scene.id }.flatMap { segment in
                    map.pieces.compactMap { piece -> (ClipLayout.Segment, TimeRange)? in
                        guard let range = segment.range.clamped(to: piece.source), range.duration > 1e-6 else { return nil }
                        return (segment, range)
                    }
                }
                guard let (last, range) = kept.last else { continue }
                let take = last.clip.take ?? "primary"
                for expectation in scene.expectations where expectation.kind == .visibleText {
                    guard let want = expectation.text else { continue }
                    if renderedURL == nil, existing.records.contains(where: {
                        $0.scene == scene.id && $0.expectation == expectation.id && $0.take == take && $0.source == .ocr
                            && $0.isCurrent(recipe: r, document: doc)
                    }) { continue }
                    let t = max(range.start, range.end - 0.35)
                    guard let outputTime = map.output(forSource: t) else { continue }
                    let img: CGImage
                    if let renderedURL {
                        guard let frame = await Self.evidenceFrame(renderedURL, at: outputTime) else { continue }
                        img = frame
                    } else {
                        if composition == nil {
                            let (w, h) = RenderPlan.outputSize(document: doc)
                            composition = try await EditComposition.build(bundle: b, document: doc, width: w, height: h)
                        }
                        guard let composition, let frame = try? await Frames.image(composition, at: outputTime) else { continue }
                        img = frame
                    }
                    let lines = SceneAnalyzer.recognizeText(img, maxLines: 120)
                    // File names never contain an untrusted take ID, and distinct snapshots keep their own evidence.
                    let recordID = IDs.make("ev")
                    outputEvidence.insert(recordID)
                    let rel = "evidence/\(recordID).jpg"
                    try? FileManager.default.createDirectory(at: b.evidenceFramesURL, withIntermediateDirectories: true)
                    try? Frames.writeJPEG(img, to: b.resolve(rel))
                    let hit = lines.first { $0.localizedCaseInsensitiveContains(want) }
                    new.append(EvidenceRecord(id: recordID, scene: scene.id, expectation: expectation.id,
                                              status: hit != nil ? .verified : .needsReview, source: .ocr,
                                              detail: hit != nil ? "on-screen text “\(want)” found at the end of the scene" : "OCR didn't find “\(want)” at the end of the scene",
                                              observed: hit, time: t, frames: [rel], take: take, author: author).normalized().bound(to: r, document: doc))
                }
            }
            if !new.isEmpty {
                try b.withLock {
                    var log = b.readEvidence()
                    log.records += new
                    try b.writeEvidence(log)
                }
            }
        }
        var evidence = b.readEvidence()
        if renderedURL != nil {
            // A low-resolution deliverable may obscure text readable in the editor or another variant. Only OCR
            // performed on this actual output can certify it; missing/failed decoding must not reuse older proof.
            evidence.records.removeAll { $0.source == .ocr && !outputEvidence.contains($0.id) }
        }
        let report = RecipeReport.evaluate(recipe: r, document: doc, evidence: evidence)
        try? JSONCoding.encoder.encode(report).write(to: b.analysisURL.appendingPathComponent("recipe-report.json"), options: .atomic)
        return report
    }
    private static func evidenceFrame(_ url: URL, at time: Double) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return nil }
            var elapsed = 0.0
            for index in 0..<count {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                elapsed += max(0.01, delay)
                if time < elapsed || index == count - 1 { return CGImageSourceCreateImageAtIndex(source, index, nil) }
            }
            return nil
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

}
