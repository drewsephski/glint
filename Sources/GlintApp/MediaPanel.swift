import SwiftUI
import UniformTypeIdentifiers
import GlintCore
import GlintAgent

/// Shots in program order, music and sounds, transitions, and callouts/masks. Movies can be dropped onto the panel.
struct MediaPanel: View {
    let model: EditorModel
    @State private var working: String?
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var transitionKind: GlintCore.Transition.Kind = .dipBlack
    @State private var transitionLength = 0.6
    @State private var recipe: DemoRecipe?

    var layout: ClipLayout { model.clipLayout }
    var audio: [AudioClip] { model.doc.timeline.audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let working { WorkingRow(text: working) }
            if let error { InlineError(text: error) { self.error = nil } }
            shots
            transitions
            OverlayList(model: model)
            audioSection
        }
        .padding(.top, 2)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.06)))
                    .overlay(alignment: .top) {
                        Label("Drop to add as shots at the end", systemImage: "film").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.top, 14)
                    }
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let movies = urls.filter(FilePick.isMovie)
            guard !movies.isEmpty else { error = "Only movie files can be dropped here. Add music and sounds with the Add menu under Audio."; return false }
            importClips(movies, atPlayhead: false)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { recipe = model.bundle.readRecipe() }
    }

    // MARK: Shots

    var shots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Shots", systemImage: "film.stack")
                Menu {
                    Button("Insert at playhead…") { pickClips(atPlayhead: true) }
                    Button("Add at the end…") { pickClips(atPlayhead: false) }
                } label: { MenuChip(title: "Import clip", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(working != nil)
            }
            ForEach(layout.segments, id: \.clip.id) { seg in
                let sel = model.selection == .clip(seg.clip.id)
                ListRow(selected: sel) {
                    if sel { model.selection = nil } else { model.selection = .clip(seg.clip.id); model.seek(source: seg.start) }
                } content: { shotRow(seg) }
                if sel { Card { ClipInspector(model: model, id: seg.clip.id) } }
            }
            Hint(layout.segments.count == 1
                 ? "The video is one shot. Import movies, or drop them here, to add more; split at the playhead to rearrange parts."
                 : "Shots play top to bottom. Zooms, captions and callouts stay on the moments they belong to when shots move or are trimmed.")
        }
    }

    func shotRow(_ seg: ClipLayout.Segment) -> some View {
        let c = seg.clip
        return HStack(spacing: 9) {
            MovieThumb(url: model.bundle.resolve(c.path), time: c.mediaStart + min(1, c.duration / 2), width: 56, height: 35)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if c.name != ShotKind(c).short { Tag(ShotKind(c).short, tint: c.primary ? Theme.text2 : Theme.accent) }
                    if let s = c.scene { Tag(recipe?.scene(s)?.title ?? s, tint: Theme.caption) }
                }
                .help(c.take.map { "From recording \($0)" } ?? c.path)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1fs", c.duration)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text2)
                Text(Theme.time(seg.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.text3)
            }
        }
    }

    func pickClips(atPlayhead: Bool) {
        let urls = FilePick.open(FilePick.movieTypes, multiple: true, message: atPlayhead ? "Choose movies to insert at the playhead" : "Choose movies to add at the end")
        guard !urls.isEmpty else { return }
        importClips(urls, atPlayhead: atPlayhead)
    }

    /// Copy movies into the project and insert them as shots, one undoable edit each.
    func importClips(_ urls: [URL], atPlayhead: Bool) {
        error = nil
        let m = model
        m.runOperation("Importing movies…") {
            defer { working = nil }
            let progress = m.progressSink()
            var at: Double? = atPlayhead ? snappedInsertTime() : nil
            var failures: [String] = []
            for (i, u) in urls.enumerated() {
                working = urls.count == 1 ? "Importing \(u.lastPathComponent)…" : "Importing \(i + 1) of \(urls.count): \(u.lastPathComponent)…"
                try Task.checkCancellation()
                progress(working ?? "Importing…")
                do {
                    let (op, clip) = try await m.service.importClip(m.bundle, file: u, at: at, name: nil, scene: nil)
                    try Task.checkCancellation()
                    m.apply([op], label: "Import “\(clip.name)”")
                    if m.doc.effectiveClips.contains(where: { $0.id == clip.id }) {
                        m.selection = .clip(clip.id)
                        if let a = at { at = a + clip.duration }
                    }
                } catch { try Task.checkCancellation(); failures.append("\(u.lastPathComponent): \(error)") }
            }
            working = nil
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    /// The playhead, moved onto a shot edge when it is within 0.05 s of one (a shot can't be split that close).
    func snappedInsertTime() -> Double {
        let t = model.sourceTime
        for s in layout.segments {
            if abs(t - s.start) < 0.06 { return s.start }
            if abs(t - s.end) < 0.06 { return s.end }
        }
        return t
    }

    // MARK: Transitions

    var transitions: some View {
        let joins = layout.segments.dropFirst().map(\.start)
        let existing = model.doc.timeline.transitions
        let missing = joins.filter { j in !existing.contains { abs($0.time - j) < 0.1 } }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Transitions", systemImage: "square.on.square.dashed")
            Card {
                Segmented(items: [(GlintCore.Transition.Kind.dipBlack, "Dip to black"), (.dipWhite, "Dip to white")], selection: $transitionKind, compact: true)
                Stepper(value: $transitionLength, in: 0.1...4, step: 0.1) {
                    HStack {
                        Text("Length").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        Spacer()
                        Text(String(format: "%.1fs", transitionLength)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    Button("At playhead") { addTransition(at: [model.sourceTime]) }
                    Button(missing.count > 1 ? "At all \(missing.count) shot joins" : "At every shot join") { addTransition(at: missing) }
                        .disabled(missing.isEmpty)
                        .help(joins.isEmpty ? "There's only one shot, so there are no joins" : missing.isEmpty ? "Every join already has a transition" : "Add a dip where each shot meets the next")
                    Spacer(minLength: 0)
                }
                .buttonStyle(GhostButtonStyle()).controlSize(.small)
                if joins.isEmpty { Hint("A dip at the very start or end of the video becomes a fade in or out.") }
            }
            ForEach(existing) { t in
                let sel = model.selection == .transition(t.id)
                ListRow(selected: sel) {
                    if sel { model.selection = nil } else { model.selection = .transition(t.id); model.seek(source: max(0, t.time - t.duration)) }
                } content: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.on.square.dashed").font(.system(size: 11)).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(t.kind == .dipBlack ? "Dip to black" : "Dip to white").font(.system(size: 12))
                        Spacer()
                        Text("\(Theme.time(t.time, precise: true)) · \(String(format: "%.1fs", t.duration))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                if sel { Card { TransitionInspector(model: model, id: t.id) } }
            }
        }
    }

    func addTransition(at times: [Double]) {
        guard !times.isEmpty else { return }
        let ts = times.map { GlintCore.Transition(time: min(max(0, $0), model.doc.duration), kind: transitionKind, duration: transitionLength) }
        model.apply(ts.map { EditOperation.add(.addTransition, $0) }, label: ts.count == 1 ? "Add transition" : "Add \(ts.count) transitions")
        if ts.count == 1, model.doc.timeline.transitions.contains(where: { $0.id == ts[0].id }) { model.selection = .transition(ts[0].id) }
    }

    // MARK: Audio

    var audioSection: some View {
        let s = model.doc.style.audio
        let hasMusic = audio.contains { $0.kind == .music }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Audio", systemImage: "music.note")
                Menu {
                    Button { pickAudio(.music) } label: { Label("Add music…", systemImage: "music.note") }
                    Button { pickAudio(.voice) } label: { Label("Add voiceover…", systemImage: "mic") }
                    Button { pickAudio(.effect) } label: { Label("Add sound…", systemImage: "speaker.wave.2") }
                } label: { MenuChip(title: "Add", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(working != nil)
            }
            if audio.isEmpty {
                Hint("Music starts at the beginning, repeats to fill the video and gets quieter under narration. A voiceover or sound starts at the playhead.")
            }
            ForEach(audio) { a in
                let sel = model.selection == .audio(a.id)
                ListRow(selected: sel, tint: Theme.voice) {
                    if sel { model.selection = nil } else { model.selection = .audio(a.id); model.seek(source: a.start) }
                } content: {
                    HStack(spacing: 8) {
                        Image(systemName: AudioKindText.icon(a.kind)).font(.system(size: 11)).foregroundStyle(Theme.voice).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Text("\(AudioKindText.title(a.kind)) · \(Int((a.gain * 100).rounded()))%\(a.loop ? " · repeats" : "")\(a.duckUnderVoice ? " · ducks" : "")")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Theme.time(a.start)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                if sel { Card { AudioInspector(model: model, id: a.id) } }
            }
            if hasMusic {
                Card {
                    Text("All music").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    Toggle("Mute music", isOn: Binding(get: { s.muteMusic }, set: { model.style("audio.muteMusic", .bool($0)) }))
                        .toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                    CommitSlider(label: "Music level", value: s.musicGain, range: 0...2, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("audio.musicGain", .number($0)) }
                        .disabled(s.muteMusic)
                    CommitSlider(label: "Under narration, music drops to", value: s.musicDuckLevel, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("audio.musicDuckLevel", .number($0)) }
                        .disabled(s.muteMusic)
                    Hint("Applies to music that has Lower under narration on.")
                }
            }
        }
    }

    func pickAudio(_ kind: AudioClip.Kind) {
        let urls = FilePick.open(FilePick.audioTypes + FilePick.movieTypes, multiple: kind != .music,
                                 message: kind == .music ? "Choose a music file" : kind == .voice ? "Choose a recorded voiceover" : "Choose sound files")
        guard !urls.isEmpty else { return }
        error = nil
        let m = model
        let at = kind == .music ? 0 : m.sourceTime
        m.runOperation("Adding audio…") {
            defer { working = nil }
            let progress = m.progressSink()
            var failures: [String] = []
            for u in urls {
                working = "Adding \(u.lastPathComponent)…"
                try Task.checkCancellation()
                progress(working ?? "Importing…")
                do {
                    let (op, clip) = try await m.service.importAudio(m.bundle, file: u, kind: kind, at: at, name: nil)
                    try Task.checkCancellation()
                    m.apply([op], label: "Add \(AudioKindText.title(kind).lowercased()) “\(clip.name)”")
                    if m.doc.timeline.audio.contains(where: { $0.id == clip.id }) { m.selection = .audio(clip.id) }
                } catch { try Task.checkCancellation(); failures.append("\(u.lastPathComponent): \(error)") }
            }
            working = nil
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
}
