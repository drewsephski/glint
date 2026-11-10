import SwiftUI
import GlintCore
import GlintAnalysis

/// Scenes → script → voice. Each step is visible and editable: the scenes Glint found, the line written for each,
/// the voice that reads them. Generating a voiceover adds clips to the timeline and retimes the picture to fit.
struct VoicePanel: View {
    let model: EditorModel
    @State private var brief = ""
    @State private var voiceID: String?
    @State private var fit = true
    @State private var captions = true
    @State private var playingPreview: String?
    @FocusState private var briefFocused: Bool

    var storyboard: Storyboard? { model.storyboard }
    var clips: [VoiceoverClip] { model.doc.timeline.voiceover }
    var narratedCount: Int { storyboard?.narratedScenes.count ?? 0 }
    var chosenVoice: Voice? {
        let id = voiceID ?? model.doc.style.voice.voiceID
        if let v = model.voices.first(where: { $0.id == id }) { return v }
        if let id, let name = model.doc.style.voice.voiceName { return Voice(id: id, name: name) }
        return model.voices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scenes
            script
            voice
            if !clips.isEmpty { clipList }
        }
        .task(id: model.hasElevenLabsKey) { await model.loadVoices() }
        .onAppear { brief = storyboard?.brief ?? "" }
        .onChange(of: storyboard?.brief) { _, b in if let b, brief.isEmpty { brief = b } }
        .onDisappear { model.stopVoicePreview(); model.saveBrief(brief) }
    }

    // MARK: Scenes

    var scenes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Scenes", systemImage: "rectangle.split.3x1")
                if let sb = storyboard {
                    Button(sb.revision == model.doc.revision ? "Re-analyze" : "Re-analyze (edit changed)") { model.analyzeScenes() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent).disabled(model.busy != nil)
                }
            }
            if let sb = storyboard {
                ForEach(sb.scenes) { s in SceneRow(model: model, scene: s) }
                if sb.scenes.isEmpty { Hint("No scenes found. Record some clicks or typing, or drop markers while recording.") }
            } else {
                Card {
                    Hint("Glint splits the recording into scenes from what you did: click clusters, typing, app switches and markers. Each scene gets a frame and its on-screen text, read on this Mac.")
                    Button { model.analyzeScenes() } label: { Label("Analyze scenes", systemImage: "rectangle.split.3x1") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(model.busy != nil)
                }
            }
        }
    }

    // MARK: Script

    var script: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Script", systemImage: "text.alignleft")
            Card {
                TextField("What is the product, and who is this video for?", text: $brief, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...4)
                    .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    .focused($briefFocused)
                    .onChange(of: briefFocused) { _, f in if !f { model.saveBrief(brief) } }
                    .accessibilityLabel("About the product and audience")
                if model.canWriteNarration {
                    HStack {
                        Button { model.writeNarration(brief: brief) } label: { Label(narratedCount == 0 ? "Write the script" : "Rewrite the script", systemImage: "text.badge.plus") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(model.busy != nil || storyboard == nil)
                        if narratedCount > 0 {
                            Button("Fill missing lines") { model.writeNarration(brief: brief, onlyMissing: true) }.buttonStyle(GhostButtonStyle()).disabled(model.busy != nil)
                        }
                        Spacer()
                        if let w = storyboard?.writer { Text(w).font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                    }
                    Hint(storyboard == nil ? "Analyze scenes first." : "\(model.narrationWriterName ?? "Claude") reads each scene's frame and on-screen text and writes one line per scene, timed to it. Edit any line above before generating the voice.")
                } else if !AccountsModel.shared.loaded {
                    WorkingRow(text: "Checking your account…")
                } else {
                    SignInPrompt(model: AccountsModel.shared,
                                 text: "Sign in with Claude or ChatGPT and it writes the script from your scenes. Or type a line under each scene yourself.")
                }
            }
        }
    }

    // MARK: Voice

    var voice: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Voice", systemImage: "waveform")
            Card {
                if !model.hasElevenLabsKey {
                    Hint("The voice comes from ElevenLabs, which needs its own API key. Add one to turn the script into a voiceover.")
                    SettingsLink { Label("Add ElevenLabs Key", systemImage: "key") }.buttonStyle(GhostButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { SettingsTab.select(.narration) })
                } else {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { chosenVoice?.id ?? "" }, set: { voiceID = $0 })) {
                            if model.voices.isEmpty, let v = chosenVoice { Text(v.name).tag(v.id) }
                            ForEach(model.voices) { v in Text(voiceLabel(v)).tag(v.id) }
                        }
                        .labelsHidden().controlSize(.small)
                        if let v = chosenVoice, v.previewURL != nil {
                            Button {
                                if playingPreview == v.id { model.stopVoicePreview(); playingPreview = nil } else { model.previewVoice(v); playingPreview = v.id }
                            } label: { Image(systemName: playingPreview == v.id ? "stop.fill" : "play.fill") }
                            .buttonStyle(IconButtonStyle()).help("Hear a sample")
                        }
                    }
                    if let e = model.voicesError {
                        InlineError(text: e)
                        Button("Try Again") { Task { await model.loadVoices() } }.buttonStyle(GhostButtonStyle())
                    } else if !model.voicesLoaded {
                        WorkingRow(text: "Loading voices…")
                    } else if model.voices.isEmpty {
                        Hint("Your ElevenLabs account has no voices yet. Add one at elevenlabs.io, then check again.")
                        Button("Check Again") { Task { await model.loadVoices() } }.buttonStyle(GhostButtonStyle())
                    }
                    Toggle("Fit the picture to each line", isOn: $fit).toggleStyle(.switch).controlSize(.small)
                    Toggle("Captions from the voice", isOn: $captions).toggleStyle(.switch).controlSize(.small)
                    HStack {
                        Button { model.generateVoiceover(voice: chosenVoice, fit: fit, captions: captions) } label: {
                            Label(clips.isEmpty ? "Generate voiceover" : "Regenerate voiceover", systemImage: "waveform.badge.plus")
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(model.busy != nil || narratedCount == 0 || chosenVoice == nil)
                        Spacer()
                        Text(narratedCount == 0 ? "No lines yet" : "\(narratedCount) line\(narratedCount == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                    if fit { Hint("Idle stretches are slowed or sped up first so each scene lasts as long as its line. Recorded audio ducks under the voice.") }
                }
            }
        }
    }

    func voiceLabel(_ v: Voice) -> String {
        let tags = ["gender", "accent", "age"].compactMap { v.labels[$0] }
        return tags.isEmpty ? v.name : "\(v.name) · \(tags.joined(separator: ", "))"
    }

    // MARK: Clips

    var clipList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Clips", systemImage: "waveform")
                Button("Re-fit picture") { model.fitNarration() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent).disabled(model.busy != nil)
            }
            ForEach(clips) { c in
                let sel = model.selection == .voice(c.id)
                HStack(alignment: .top, spacing: 8) {
                    Text(Theme.time(c.start)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3).frame(width: 36, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.text).font(.system(size: 11.5)).lineLimit(2)
                        Text(String(format: "%.1fs · %@", c.duration, c.voiceName ?? c.voice ?? "")).font(.system(size: 10)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.voice.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { model.selection = .voice(c.id); model.seek(source: c.start) }
            }
        }
    }
}

struct SceneRow: View {
    let model: EditorModel
    let scene: GlintCore.Scene
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var budget: Int { max(3, Int((scene.end - scene.start) * 2.5)) }
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let img = model.frameImage(scene) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { Theme.raised }
            }
            .frame(width: 72, height: 45).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline))
            .onTapGesture { model.seek(source: scene.frameTime ?? scene.start) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(scene.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Theme.time(scene.start)) – \(Theme.time(scene.end))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3)
                }
                if !scene.actions.isEmpty {
                    Text(scene.actions.prefix(3).joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                TextField("Narration for this scene", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...5)
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Text(text.isEmpty ? "About \(budget) words fit this scene" : "\(words) of about \(budget) words")
                    .font(.system(size: 10)).foregroundStyle(words > Int(Double(budget) * 1.6) ? Theme.speed : Theme.text3)
            }
        }
        .padding(.vertical, 4)
        .onAppear { text = scene.narration ?? "" }
        .onChange(of: scene.narration) { _, n in if !focused { text = n ?? "" } }
    }

    func commit() { model.setNarration(scene.id, text) }
}
