import SwiftUI
import AppKit
import GlintCore
import GlintAgent
import GlintAnalysis

/// Captions line by line, how they look, SRT/VTT in and out, and editing the video by deleting transcript words.
struct CaptionsPanel: View {
    let model: EditorModel
    @State private var error: String?
    @State private var working: String?
    @State private var exported: (url: URL, saved: URL?)?
    @State private var pendingImport: (ops: [EditOperation], count: Int)?

    var captions: [CaptionSegment] { model.doc.timeline.captions }
    var style: CaptionStyle { model.doc.style.captions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let working { WorkingRow(text: working) }
            if let error { InlineError(text: error) { self.error = nil } }
            TranscriptionOptions(model: model)
            lines
            look
            TranscriptSection(model: model)
        }
        .confirmationDialog("Replace the \(captions.count) caption\(captions.count == 1 ? "" : "s")?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace with \(pendingImport?.count ?? 0) from the file") {
                if let p = pendingImport { model.apply(p.ops, label: "Import captions (\(p.count) lines)") }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text("The file's captions replace the current ones. You can undo this.") }
    }

    // MARK: Lines

    var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Captions", systemImage: "captions.bubble")
                Menu {
                    Button("Generate with these settings") { model.captions() }.disabled(model.busy != nil)
                    Divider()
                    Button("Import SRT or VTT…") { importSubtitles() }
                    Divider()
                    Button("Export SRT…") { export(.srt) }.disabled(captions.isEmpty)
                    Button("Export VTT…") { export(.vtt) }.disabled(captions.isEmpty)
                } label: { MenuChip(title: "More", systemImage: "ellipsis") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if let e = exported {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 11))
                    Text(e.saved.map { "Saved \($0.lastPathComponent)" } ?? "Written to the project's renders folder").font(.system(size: 11.5)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Show in Finder") { FilePick.reveal(e.saved ?? e.url) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    Button { exported = nil } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            if captions.isEmpty {
                Card {
                    Hint("Captions come from what's said in the recording, read on this Mac, or from a voiceover. You can also bring in an SRT or VTT file.")
                    HStack(spacing: 8) {
                        Button { model.captions() } label: { Label("Generate captions", systemImage: "captions.bubble") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(model.busy != nil)
                        Button("Import file…") { importSubtitles() }.buttonStyle(GhostButtonStyle())
                    }
                    if model.doc.media.microphone == nil && model.doc.media.systemAudio == nil {
                        Hint("This recording has no audio to transcribe. Generate a voiceover in the Voice tab, or import a subtitle file.")
                    }
                }
            } else {
                Toggle("Show captions in the video", isOn: Binding(get: { style.enabled }, set: { model.style("captions.enabled", .bool($0)) }))
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(captions) { c in CaptionRow(model: model, caption: c) }
                }
                Hint("Click a line to jump to it. Hidden lines stay in the project but don't show or export.")
            }
        }
    }

    func importSubtitles() {
        guard let u = FilePick.open(FilePick.subtitleTypes, message: "Choose an SRT or WebVTT file").first else { return }
        error = nil
        do {
            let ops = try model.service.importSubtitles(model.bundle, file: u)
            let n = ops.first?.items?.count ?? 0
            if captions.isEmpty { model.apply(ops, label: "Import captions (\(n) lines)") } else { pendingImport = (ops, n) }
        } catch { self.error = "\(error)" }
    }

    func export(_ f: Subtitles.Format) {
        error = nil
        do {
            let (url, _) = try model.service.exportSubtitles(model.bundle, format: f, proposal: model.previewProposal)
            exported = (url, nil)
            guard let dest = FilePick.save(suggestedName: url.lastPathComponent) else { return }
            // The save panel already asked about replacing an existing file.
            let saved = try model.service.export(file: url, to: dest, author: .app, approvalID: nil, confirmedByUser: true)
            exported = (url, saved)
        } catch { self.error = "\(error)" }
    }

    // MARK: Look

    var look: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Look", systemImage: "textformat")
            Card {
                Segmented(items: [(CaptionStyle.Look.highlight, "Highlight"), (.pill, "Pill"), (.plain, "Plain")],
                          selection: Binding(get: { style.look }, set: { model.style("captions.look", .string($0.rawValue)) }), compact: true)
                Hint(style.look == .highlight ? "Each word lights up as it's spoken." : style.look == .pill ? "Text on a rounded background." : "Text with a soft shadow, no background.")
                Segmented(items: [("system", "System"), ("rounded", "Rounded"), ("serif", "Serif"), ("mono", "Mono")],
                          selection: Binding(get: { style.font }, set: { model.style("captions.font", .string($0)) }), compact: true)
                Picker("Weight", selection: Binding(get: { style.weight }, set: { model.style("captions.weight", .string($0)) })) {
                    ForEach(["regular", "medium", "semibold", "bold", "heavy"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .controlSize(.small)
                CommitSlider(label: "Size", value: style.size, range: 0.025...0.07, format: { String(format: "%.1f%%", $0 * 100) }) { model.style("captions.size", .number($0)) }
                HStack {
                    Text("Position").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Spacer()
                    Segmented(items: [("bottom", "Bottom"), ("top", "Top")], selection: Binding(get: { style.position }, set: { model.style("captions.position", .string($0)) }), compact: true)
                        .frame(width: 150)
                }
                ColorField(label: "Text", color: style.textColor) { model.style("captions.textColor", .string($0)) }
                if style.look == .highlight {
                    ColorField(label: "Spoken word", color: style.highlightColor) { model.style("captions.highlightColor", .string($0)) }
                }
                if style.look != .plain {
                    ColorField(label: "Background", color: style.backgroundColor, supportsOpacity: true) { model.style("captions.backgroundColor", .string($0)) }
                }
            }
        }
    }
}

/// One caption: click to jump, edit the text in place; the selected line also gets timing nudges.
struct CaptionRow: View {
    let model: EditorModel
    let caption: CaptionSegment

    var body: some View {
        let c = caption
        let sel = model.selection == .caption(c.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(Theme.time(c.start)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3).frame(width: 30, alignment: .leading).padding(.top, 5)
                CommitTextField(placeholder: "Caption", value: c.text, axis: .vertical, lineLimit: 1...4) { t in
                    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.isEmpty { model.apply([EditOperation(.removeCaption, id: c.id)], label: "Remove caption") }
                    else { model.apply([EditOperation(.updateCaption, id: c.id, text: s)], label: "Edit caption") }
                }
                .opacity(c.hidden ? 0.5 : 1)
                Button {
                    model.apply([EditOperation(.updateCaption, id: c.id, hidden: !c.hidden)], label: c.hidden ? "Show caption" : "Hide caption")
                } label: { Image(systemName: c.hidden ? "eye.slash" : "eye").font(.system(size: 10.5)) }
                .buttonStyle(MiniButtonStyle()).padding(.top, 3).help(c.hidden ? "Show this line" : "Hide this line")
            }
            if sel {
                VStack(alignment: .leading, spacing: 6) {
                    TimeStepper(label: "Starts", value: c.start, range: 0...max(0, c.end - 0.2)) { v in
                        model.apply([EditOperation(.updateCaption, id: c.id, start: v)], label: "Retime caption")
                    }
                    TimeStepper(label: "Ends", value: c.end, range: min(model.doc.duration, c.start + 0.2)...model.doc.duration) { v in
                        model.apply([EditOperation(.updateCaption, id: c.id, end: v)], label: "Retime caption")
                    }
                    HStack {
                        Text(String(format: "%.1fs on screen", c.end - c.start)).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        Spacer()
                        Button(role: .destructive) {
                            model.apply([EditOperation(.removeCaption, id: c.id)], label: "Remove caption")
                            model.selection = nil
                        } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(sel ? Theme.caption.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(sel ? Theme.caption.opacity(0.3) : Color.clear))
        .contentShape(Rectangle())
        // Selects (never deselects): a click that lands in the text field must not close the row being edited.
        .onTapGesture { if !sel { model.selection = .caption(c.id); model.seek(source: c.start) } }
    }
}

// MARK: - Transcript

/// The words Glint heard. Select words (shift-click for a range) to cut them from the video, or find a phrase and
/// cut every occurrence.
struct TranscriptSection: View {
    let model: EditorModel
    @State private var anchor: Int?
    @State private var selected: ClosedRange<Int>?
    @State private var query = ""
    @State private var error: String?
    @FocusState private var focusedWord: Int?
    @State private var pending: (ops: [EditOperation], removed: [String], contexts: [String])?

    var transcript: Transcript? { model.transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Transcript", systemImage: "text.quote")
            if let error { InlineError(text: error) { self.error = nil } }
            if let t = transcript, !t.words.isEmpty {
                words(t)
                find(t)
            } else if transcript != nil {
                Hint("No speech was found in the recording.")
            } else {
                Card {
                    Hint("Turn what's said into text, on this Mac. Then delete words here to cut them from the video.")
                    Button { model.transcribe() } label: { Label("Transcribe", systemImage: "text.quote") }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(model.busy != nil || (model.doc.media.microphone == nil && model.doc.media.systemAudio == nil))
                    if model.doc.media.microphone == nil && model.doc.media.systemAudio == nil { Hint("This recording has no audio.") }
                }
            }
        }
        .onChange(of: focusedWord) { _, word in model.transcriptHasFocus = word != nil }
        .onDisappear { model.transcriptHasFocus = false }
        .onChange(of: transcript) { _, _ in selected = nil; anchor = nil; focusedWord = nil }
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Cut from the video", role: .destructive) {
                if let p = pending { model.apply(p.ops, label: "Cut “\(p.removed.first ?? "")”\(p.removed.count > 1 ? " ×\(p.removed.count)" : "")") }
                pending = nil
                query = ""
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(pendingMessage) }
    }

    var pendingTitle: String {
        guard let p = pending else { return "" }
        return p.removed.count == 1 ? "Cut 1 place?" : "Cut \(p.removed.count) places?"
    }

    var pendingMessage: String {
        guard let p = pending else { return "" }
        var lines = Array(p.contexts.prefix(8))
        if p.contexts.count > 8 { lines.append("…and \(p.contexts.count - 8) more") }
        return lines.joined(separator: "\n") + "\n\nYou can undo this."
    }

    func isCut(_ w: CaptionWord) -> Bool {
        let mid = (w.start + w.end) / 2
        let kept = model.doc.keptRange
        return mid < kept.start || mid > kept.end || model.doc.timeline.cuts.contains { mid >= $0.start && mid <= $0.end }
    }

    @ViewBuilder func words(_ t: Transcript) -> some View {
        Card {
            FlowLayout(spacing: 2, lineSpacing: 2) {
                ForEach(Array(t.words.enumerated()), id: \.offset) { i, w in
                    wordButton(i, word: w, transcript: t)
                }
            }
            if let r = selected, t.words.indices.contains(r.lowerBound), t.words.indices.contains(r.upperBound) {
                let text = t.words[r].map(\.text).joined(separator: " ")
                Text("“\(text.count > 90 ? String(text.prefix(90)) + "…" : text)”").font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2)
                HStack(spacing: 6) {
                    Button(role: .destructive) { cutSelected(r) } label: { Label(r.count == 1 ? "Cut this word" : "Cut \(r.count) words", systemImage: "scissors") }
                        .buttonStyle(GhostButtonStyle())
                    Button("Clear") { selected = nil; anchor = nil }.buttonStyle(LinkButtonStyle())
                    Spacer(minLength: 0)
                }
            } else {
                Hint("Select a word to seek. Use ←/→ to move, Shift to extend the selection, and Delete to cut. Struck-out words are already cut.")
            }
        }
    }

    private func wordButton(_ index: Int, word: CaptionWord, transcript: Transcript) -> some View {
        let selected = selected?.contains(index) ?? false
        let cut = isCut(word)
        let label = Text(word.text)
            .font(.system(size: 12))
            .strikethrough(cut, color: Theme.cut.opacity(0.7))
            .foregroundStyle(selected ? Theme.text : cut ? Theme.text3 : Theme.text2)
            .padding(.horizontal, 3).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.32) : Color.clear))
            .contentShape(Rectangle())
        let button = Button { select(index, word, extending: NSEvent.modifierFlags.contains(.shift)) } label: { label }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedWord, equals: index)
        let accessible = button
            .accessibilityLabel("\(word.text), \(Theme.time(word.start, precise: true))\(cut ? ", already cut" : "")")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Seek to word") { select(index, word, extending: false) }
            .accessibilityAction(named: "Extend selection") { select(index, word, extending: true) }
            .accessibilityAction(named: "Cut word") { cutSelected(index...index) }
            .accessibilityAction(named: "Cut selected words") { cutSelected(self.selected ?? index...index) }
        return accessible
            .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .return, .delete, .escape]) { press in
                handleWordKey(press, index: index, transcript: transcript)
            }
            .help(Theme.time(word.start, precise: true))
    }

    private func handleWordKey(_ press: KeyPress, index: Int, transcript: Transcript) -> KeyPress.Result {
        switch press.key {
        case .leftArrow, .rightArrow:
            if anchor == nil { anchor = index }
            let next = min(transcript.words.count - 1, max(0, index + (press.key == .leftArrow ? -1 : 1)))
            select(next, transcript.words[next], extending: press.modifiers.contains(.shift))
        case .delete: cutSelected(selected ?? index...index)
        case .escape: selected = nil; anchor = nil; focusedWord = nil
        default: select(index, transcript.words[index], extending: press.modifiers.contains(.shift))
        }
        return .handled
    }

    func select(_ i: Int, _ w: CaptionWord, extending: Bool) {
        focusedWord = i
        if extending, let a = anchor {
            selected = min(a, i)...max(a, i)
        } else {
            anchor = i
            selected = i...i
        }
        model.seek(source: w.start)
    }

    func cutSelected(_ r: ClosedRange<Int>) {
        error = nil
        do {
            let (ops, removed) = try model.service.transcriptCuts(model.bundle, ranges: [(r.lowerBound, r.upperBound)], phrase: nil)
            guard !ops.isEmpty else { error = "Those words are too short to cut on their own. Select a few more."; return }
            model.apply(ops, label: "Cut “\(removed.first ?? "")”")
            selected = nil; anchor = nil
        } catch { self.error = "\(error)" }
    }

    @ViewBuilder func find(_ t: Transcript) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? [] : TranscriptEdit.find(q, in: t.words)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.text3)
                TextField("Find a word or phrase", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { if !matches.isEmpty { prepareCutAll(q, t, matches) } }
                if !q.isEmpty {
                    Text(matches.isEmpty ? "No matches" : "\(matches.count) found").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
            if !matches.isEmpty {
                ForEach(Array(matches.prefix(5).enumerated()), id: \.offset) { _, m in
                    Text(context(t, m)).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { anchor = m.0; selected = m.0...m.1; model.seek(source: t.words[m.0].start) }
                }
                if matches.count > 5 { Hint("…and \(matches.count - 5) more") }
                Button(role: .destructive) { prepareCutAll(q, t, matches) } label: {
                    Label(matches.count == 1 ? "Cut it" : "Cut all \(matches.count)…", systemImage: "scissors")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    func context(_ t: Transcript, _ m: (Int, Int)) -> String {
        let lo = max(0, m.0 - 4), hi = min(t.words.count - 1, m.1 + 4)
        let before = t.words[lo..<m.0].map(\.text).joined(separator: " ")
        let hit = t.words[m.0...m.1].map(\.text).joined(separator: " ")
        let after = m.1 < hi ? t.words[(m.1 + 1)...hi].map(\.text).joined(separator: " ") : ""
        return "\(Theme.time(t.words[m.0].start))  …\(before) [\(hit)] \(after)…"
    }

    func prepareCutAll(_ phrase: String, _ t: Transcript, _ matches: [(Int, Int)]) {
        error = nil
        do {
            let (ops, removed) = try model.service.transcriptCuts(model.bundle, ranges: [], phrase: phrase)
            guard !ops.isEmpty else { error = "Nothing long enough to cut."; return }
            pending = (ops, removed, matches.map { context(t, $0) })
        } catch { self.error = "\(error)" }
    }

}

/// Shared by transcript and caption generation; changing these settings invalidates a mismatched transcript.
struct TranscriptionOptions: View {
    @Bindable var model: EditorModel
    @State private var customLanguage = false
    private let languages = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"), ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese (Simplified)"),
    ]
    var body: some View {
        Card {
            Picker("Language", selection: Binding(get: { customLanguage ? "custom" : model.captionLocale }, set: { value in
                customLanguage = value == "custom"
                if !customLanguage { model.captionLocale = value }
            })) {
                ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
                if !languages.contains(where: { $0.0 == model.captionLocale }) {
                    Text(Locale.current.localizedString(forIdentifier: model.captionLocale) ?? model.captionLocale).tag(model.captionLocale)
                }
                Text("Other language…").tag("custom")
            }.controlSize(.small)
            if customLanguage {
                TextField("Language code, for example nl-NL", text: $model.captionLocale)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Caption language code")
            }
            Picker("Audio source", selection: $model.captionSource) {
                Text("Automatic").tag("auto")
                if model.doc.media.microphone != nil { Text("Microphone").tag("microphone") }
                if model.doc.media.systemAudio != nil { Text("System audio").tag("system") }
            }.controlSize(.small)
            Hint("Automatic prefers microphone audio. Available languages depend on the transcription engine on your Mac.")
            if model.transcript != nil {
                Button("Update transcript with these settings") { model.transcribe() }
                    .buttonStyle(GhostButtonStyle()).disabled(model.busy != nil)
            }
        }
    }
}
