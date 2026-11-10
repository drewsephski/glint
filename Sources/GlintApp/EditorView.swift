import SwiftUI
import AVKit
import GlintCore
import GlintRender
import GlintAgent

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.allowsPictureInPicturePlayback = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

enum SidebarTab: String, CaseIterable {
    case style = "Style", media = "Media", captions = "Captions", voice = "Voice", recipe = "Recipe", chat = "Chat", agent = "Activity"
    var systemImage: String {
        switch self {
        case .style: "paintpalette"
        case .media: "film.stack"
        case .captions: "captions.bubble"
        case .voice: "waveform"
        case .recipe: "checklist"
        case .chat: "bubble.left.and.bubble.right"
        case .agent: "clock.arrow.circlepath"
        }
    }
}

struct EditorView: View {
    let app: AppModel
    @Bindable var model: EditorModel
    // "Agent" is what the Activity tab used to be called.
    @State private var tab: SidebarTab = { let v = UserDefaults.standard.string(forKey: "GlintSidebarTab") ?? ""; return SidebarTab(rawValue: v == "Agent" ? "Activity" : v) ?? .style }()
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !model.fitNotes.isEmpty {
                HStack(alignment: .top) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.fitNotes.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.textSelection(.enabled)
                    }.frame(maxHeight: 110)
                    Button("Dismiss") { model.fitNotes = [] }.buttonStyle(GhostButtonStyle())
                }.padding(12).background(Theme.raised)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview
                    transport
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.hairline)
                sidebar.frame(width: tab == .chat ? 380 : 320)
            }
            Divider().overlay(Theme.hairline)
            TimelineEditor(model: model).frame(height: min(360, TimelineEditor.preferredHeight(model.doc)))
        }
        .background(Theme.canvas)
        // Single-key shortcuts for this window (Space, Delete, S, I, O, tools, Esc). See ShortcutsHelp.swift.
        .background(EditorKeys(model: model))
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsHelp() }
        .sheet(isPresented: $model.showVoicePurchase) { VoicePurchaseSheet() }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Button { app.closeEditor() } label: { Image(systemName: "chevron.left") }.buttonStyle(IconButtonStyle()).help("All projects")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.doc.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("rev \(model.doc.revision) · \(Theme.time(model.outputDuration)) of \(Theme.time(model.doc.duration)) · \(model.doc.media.width)×\(model.doc.media.height)")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                Button("Cancel") { model.cancelOperation() }.buttonStyle(GhostButtonStyle())
            }
            if let banner = model.banner {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    Text(banner).font(.system(size: 11.5)).lineLimit(1)
                    Button { model.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Theme.raised))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .frame(maxWidth: 380)
            }
            Spacer()
            Group {
                Button { model.autoZoom() } label: { Label("Auto Zoom", systemImage: "plus.magnifyingglass") }
                Button { model.tighten() } label: { Label("Tighten", systemImage: "scissors") }
                Button { model.captions() } label: { Label("Captions", systemImage: "captions.bubble") }
            }.buttonStyle(GhostButtonStyle()).disabled(model.busy != nil)
            Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 16).padding(.horizontal, 2)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(IconButtonStyle()).disabled(!model.canUndo).help("Undo ⌘Z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(IconButtonStyle()).disabled(!model.canRedo).help("Redo ⇧⌘Z")
            Button { model.showShortcuts = true } label: { Image(systemName: "keyboard") }.buttonStyle(IconButtonStyle())
                .help("Keyboard shortcuts ⌘/").accessibilityLabel("Keyboard shortcuts")
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.leading, 78).padding(.trailing, 14).padding(.vertical, 9)
        .background(WindowHeader())
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    var preview: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
            PlayerSurface(player: model.player)
                .aspectRatio(CGFloat(RenderPlan.outputSize(document: model.previewDocument).0) / CGFloat(RenderPlan.outputSize(document: model.previewDocument).1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                // Callout and redaction editing, drawing tools and the facecam, over the exact rendered frame.
                .overlay { OverlayCanvas(model: model) }
                .overlay(alignment: .topTrailing) {
                    if model.previewSlow {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Updating preview").font(.system(size: 11)) }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.raised.opacity(0.92))).overlay(Capsule().strokeBorder(Theme.hairline))
                            .padding(10).allowsHitTesting(false)
                    }
                }
                .padding(24)
            previewHint
            if let pid = model.previewProposal, let p = model.proposals.first(where: { $0.id == pid }) {
                HStack(spacing: 10) {
                    Image(systemName: "eye").foregroundStyle(Theme.accent)
                    Text("Previewing “\(p.title)” by \(p.author.name)").font(.system(size: 12, weight: .semibold))
                    Button("Apply") { model.acceptProposal(pid) }.buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { model.previewProposal = nil }.buttonStyle(GhostButtonStyle())
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised).shadow(color: .black.opacity(0.4), radius: 14, y: 6))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairlineStrong)).padding(.top, 10)
            }
        }
    }

    /// One line under the frame about what the preview is ready for: the active tool, or how to edit the selection.
    @ViewBuilder var previewHint: some View {
        let text: String? = {
            if let tool = model.overlayTool { return "\(tool.hint). Esc puts the tool away." }
            let src = model.sourceTime
            switch model.selection {
            case .annotation(let id):
                guard let a = model.doc.timeline.annotations.first(where: { $0.id == id }) else { return nil }
                if model.isPlaying { return "Pause to move or resize the callout on the preview." }
                if !(src >= a.start && src < a.end) { return "This callout shows from \(Theme.time(a.start, precise: true)) to \(Theme.time(a.end, precise: true))." }
                return nil
            case .redaction(let id):
                guard let r = model.doc.timeline.redactions.first(where: { $0.id == id }) else { return nil }
                if model.isPlaying { return "Pause to move or resize the redaction on the preview." }
                if !(src >= r.start && src < r.end) { return "This redaction shows from \(Theme.time(r.start, precise: true)) to \(Theme.time(r.end, precise: true))." }
                return nil
            default: return nil
            }
        }()
        if let text {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    if let span = offscreenSelectionSpan {
                        Button("Go there") { model.seek(source: min(span.1 - 0.02, span.0 + min(0.3, (span.1 - span.0) / 2))) }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 28)
                .background(Capsule().fill(Theme.raised.opacity(0.95))).overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(.bottom, 4)
            }
        }
    }

    /// The selected overlay's time span when the playhead is outside it (paused).
    var offscreenSelectionSpan: (Double, Double)? {
        guard !model.isPlaying, model.overlayTool == nil else { return nil }
        let src = model.sourceTime
        let span: (Double, Double)?
        switch model.selection {
        case .annotation(let id): span = model.doc.timeline.annotations.first(where: { $0.id == id }).map { ($0.start, $0.end) }
        case .redaction(let id): span = model.doc.timeline.redactions.first(where: { $0.id == id }).map { ($0.start, $0.end) }
        default: span = nil
        }
        guard let s = span, !(src >= s.0 && src < s.1) else { return nil }
        return s
    }

    var transport: some View {
        HStack(spacing: 14) {
            Button { model.seek(output: 0) } label: { Image(systemName: "backward.end.fill") }.buttonStyle(IconButtonStyle()).help("Back to the start")
            Button { model.togglePlay() } label: {
                Hoverable { hover in
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(hover ? 0.18 : 0.1)))
                        .overlay(Circle().strokeBorder(Theme.hairline))
                        .contentShape(Circle())
                }
            }.buttonStyle(.plain).help("Play or pause (Space)")
            HStack(spacing: 5) {
                Text(Theme.time(model.currentTime, precise: true)).foregroundStyle(Theme.text)
                Text("/").foregroundStyle(Theme.text3)
                Text(Theme.time(model.outputDuration, precise: true)).foregroundStyle(Theme.text2)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            Spacer()
            OverlayToolbar(model: model)
            Segmented(items: [Aspect.landscape, .square, .portrait, .classic, .auto].map { ($0, $0 == .auto ? "Source" : $0.rawValue) },
                      selection: Binding(get: { model.doc.style.canvas.aspect }, set: { model.style("canvas.aspect", .string($0.rawValue)) }), compact: true)
                .frame(width: 300)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .foregroundStyle(.white)
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            SidebarTabBar(selection: $tab, badges: model.proposals.contains(where: { $0.status == .pending }) ? [.agent] : [])
            .padding(12)
            .onChange(of: tab) { _, t in UserDefaults.standard.set(t.rawValue, forKey: "GlintSidebarTab") }
            if tab == .chat {
                ChatPanel(model: model, chat: model.chat)
            } else {
                ScrollView {
                    Group {
                        switch tab {
                        case .style: InspectorView(model: model)
                        case .media: MediaPanel(model: model)
                        case .captions: CaptionsPanel(model: model)
                        case .voice: VoicePanel(model: model)
                        case .recipe: RecipePanel(model: model)
                        case .agent, .chat: AgentPanel(model: model)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 16)
                }
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Inspector

struct InspectorView: View {
    let model: EditorModel
    var style: Style { model.doc.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sel = model.selection { SelectionCard(model: model, selection: sel) }
            StylePresetsSection(model: model)
            SectionHeader(title: "Background", systemImage: "paintpalette")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundPresets.all, id: \.name) { p in
                    let active = style.background.kind == .gradient && style.background.preset == p.name && style.background.colors.isEmpty
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: p.colors.map(Theme.color), startPoint: .bottomLeading, endPoint: .topTrailing))
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(active ? Color.white : Color.white.opacity(0.1), lineWidth: active ? 2 : 1))
                        .help(p.name)
                        .onTapGesture {
                            model.apply([.style("background.kind", .string("gradient")), .style("background.preset", .string(p.name)), .style("background.colors", .array([]))], label: "Background \(p.name)")
                        }
                }
            }
            Card {
                CommitSlider(label: "Padding", value: style.frame.padding, range: 0...0.2, format: { "\(Int($0 * 100))%" }) { model.style("frame.padding", .number($0)) }
                CommitSlider(label: "Corner radius", value: style.frame.cornerRadius, range: 0...0.06, format: { String(format: "%.1f%%", $0 * 100) }) { model.style("frame.cornerRadius", .number($0)) }
                CommitSlider(label: "Shadow", value: style.frame.shadowOpacity, range: 0...0.9, format: { "\(Int($0 * 100))%" }) { model.style("frame.shadowOpacity", .number($0)) }
            }
            if model.doc.media.camera != nil { facecam }
            SectionHeader(title: "Cursor", systemImage: "cursorarrow")
            Card {
                Toggle("Show cursor", isOn: Binding(get: { style.cursor.visible }, set: { model.style("cursor.visible", .bool($0)) })).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                CommitSlider(label: "Size", value: style.cursor.scale, range: 0.5...4, format: { String(format: "%.1f×", $0) }) { model.style("cursor.scale", .number($0)) }
                CommitSlider(label: "Smoothing", value: style.cursor.smoothing, range: 0...1, format: { "\(Int($0 * 100))%" }) { model.style("cursor.smoothing", .number($0)) }
                CommitSlider(label: "Hide when idle after", value: style.cursor.hideAfterIdle, range: 0...8, format: { $0 == 0 ? "never" : String(format: "%.1fs", $0) }) { model.style("cursor.hideAfterIdle", .number($0)) }
                Toggle("Click ripple", isOn: Binding(get: { style.cursor.clickEffect }, set: { model.style("cursor.clickEffect", .bool($0)) })).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                Picker("Look", selection: Binding(get: { style.cursor.appearance }, set: { model.style("cursor.appearance", .string($0.rawValue)) })) {
                    Text("As recorded").tag(CursorStyle.Appearance.recorded)
                    Text("Glint arrow").tag(CursorStyle.Appearance.arrow)
                }.controlSize(.small)
            }
            SectionHeader(title: "Camera", systemImage: "camera.metering.center.weighted")
            Card {
                Segmented(items: [("smooth", "Smooth"), ("focused", "Focused"), ("snappy", "Snappy")] + (motionPreset == "custom" ? [("custom", "Custom")] : []),
                          selection: Binding(get: { motionPreset }, set: { applyMotion($0) }), compact: true)
                CommitSlider(label: "Motion blur", value: style.zoom.motionBlur, range: 0...1, format: { "\(Int($0 * 100))%" }) { model.style("zoom.motionBlur", .number($0)) }
                CommitSlider(label: "Follow dead zone", value: style.zoom.followDeadZone, range: 0.05...0.8, format: { "\(Int($0 * 100))%" }) { model.style("zoom.followDeadZone", .number($0)) }
            }
            SectionHeader(title: "Captions", systemImage: "captions.bubble")
            Card {
                Toggle("Show captions", isOn: Binding(get: { style.captions.enabled }, set: { model.style("captions.enabled", .bool($0)) })).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                Segmented(items: [(CaptionStyle.Look.highlight, "Highlight"), (.pill, "Pill"), (.plain, "Plain")],
                          selection: Binding(get: { style.captions.look }, set: { model.style("captions.look", .string($0.rawValue)) }), compact: true)
                CommitSlider(label: "Size", value: style.captions.size, range: 0.025...0.07, format: { String(format: "%.1f%%", $0 * 100) }) { model.style("captions.size", .number($0)) }
                Hint(model.doc.timeline.captions.isEmpty ? "No captions yet. Use Captions in the toolbar, or generate a voiceover." : "\(model.doc.timeline.captions.count) caption lines")
            }
            SectionHeader(title: "Audio", systemImage: "speaker.wave.2")
            Card {
                if model.doc.media.microphone != nil {
                    CommitSlider(label: "Microphone", value: style.audio.microphoneGain, range: 0...3, format: { String(format: "%.0f%%", $0 * 100) }) { model.style("audio.microphoneGain", .number($0)) }
                }
                if model.doc.media.systemAudio != nil {
                    CommitSlider(label: "System audio", value: style.audio.systemGain, range: 0...2, format: { String(format: "%.0f%%", $0 * 100) }) { model.style("audio.systemGain", .number($0)) }
                }
                if !model.doc.timeline.voiceover.isEmpty {
                    CommitSlider(label: "Voiceover", value: style.audio.voiceoverGain, range: 0...2, format: { String(format: "%.0f%%", $0 * 100) }) { model.style("audio.voiceoverGain", .number($0)) }
                    Toggle("Duck recorded audio under the voice", isOn: Binding(get: { style.audio.duckUnderVoiceover }, set: { model.style("audio.duckUnderVoiceover", .bool($0)) })).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                    if style.audio.duckUnderVoiceover {
                        CommitSlider(label: "Duck to", value: style.audio.duckLevel, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }) { model.style("audio.duckLevel", .number($0)) }
                    }
                }
                if model.doc.media.microphone == nil && model.doc.media.systemAudio == nil && model.doc.timeline.voiceover.isEmpty { Hint("No audio tracks") }
            }
        }
    }

    @ViewBuilder var facecam: some View {
        let f = style.facecam
        SectionHeader(title: "Facecam", systemImage: "person.crop.circle")
        Card {
            Toggle("Show facecam", isOn: Binding(get: { f.visible }, set: { model.style("facecam.visible", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
            if f.visible {
                Picker("Shape", selection: Binding(get: { f.shape }, set: { model.style("facecam.shape", .string($0.rawValue)) })) {
                    Text("Circle").tag(FacecamStyle.Shape.circle); Text("Square").tag(FacecamStyle.Shape.square); Text("Wide").tag(FacecamStyle.Shape.wide)
                }.pickerStyle(.segmented).controlSize(.small)
                HStack {
                    Text("Corner").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Spacer()
                    CornerPicker(selection: f.position) { model.style("facecam.position", .string($0.rawValue)) }
                }
                CommitSlider(label: "Size", value: f.size, range: 0.1...0.5, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("facecam.size", .number($0)) }
                if f.shape != .circle {
                    CommitSlider(label: "Corner radius", value: f.cornerRadius, range: 0...0.5, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("facecam.cornerRadius", .number($0)) }
                }
                CommitSlider(label: "Crop in", value: f.zoom, range: 1...2.5, format: { String(format: "%.2f×", $0) }) { model.style("facecam.zoom", .number($0)) }
                CommitSlider(label: "Border", value: f.borderWidth, range: 0...0.05, format: { String(format: "%.1f%%", $0 * 100) }) { model.style("facecam.borderWidth", .number($0)) }
                CommitSlider(label: "Shadow", value: f.shadowOpacity, range: 0...0.9, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("facecam.shadowOpacity", .number($0)) }
                CommitSlider(label: "Size while zoomed in", value: f.scaleWhenZoomed, range: 0.4...1, format: { "\(Int(($0 * 100).rounded()))%" }) { model.style("facecam.scaleWhenZoomed", .number($0)) }
                Toggle("Mirror", isOn: Binding(get: { f.mirror }, set: { model.style("facecam.mirror", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    static let motions: [String: (Double, Double, Double)] = ["smooth": (180, 48, 3), "focused": (250, 40, 2.25), "snappy": (420, 52, 1.6)]
    var motionPreset: String {
        let z = style.zoom
        return Self.motions.first { $0.value == (z.stiffness, z.damping, z.mass) }?.key ?? "custom"
    }
    func applyMotion(_ name: String) {
        guard let m = Self.motions[name] else { return }
        model.apply([.style("zoom.stiffness", .number(m.0)), .style("zoom.damping", .number(m.1)), .style("zoom.mass", .number(m.2))], label: "Camera motion: \(name)")
    }
}

struct SelectionCard: View {
    let model: EditorModel
    let selection: Selection
    var body: some View {
        Card {
            switch selection {
            case .zoom(let id):
                if let z = model.doc.timeline.zooms.first(where: { $0.id == id }) {
                    HStack { Label("Zoom", systemImage: "plus.magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.zoom); Spacer(); origin(z.origin) }
                    if let r = z.reason { Text(r).font(.system(size: 11)).foregroundStyle(Theme.text3) }
                    CommitSlider(label: "Scale", value: z.scale, range: 1.1...4, step: 0.05, format: { String(format: "%.2f×", $0) }) { model.apply([EditOperation(.updateZoom, id: id, scale: $0)]) }
                    Picker("Focus", selection: Binding(get: { z.focus == .followCursor ? 0 : 1 }, set: { v in
                        let f: JSONValue = v == 0 ? .string("cursor") : .object(["x": .number(model.cursorFocusGuess(z).x), "y": .number(model.cursorFocusGuess(z).y)])
                        model.apply([EditOperation(.updateZoom, id: id, focus: f)])
                    })) { Text("Follow cursor").tag(0); Text("Fixed").tag(1) }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
                    Text(String(format: "%.2fs – %.2fs", z.start, z.end)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                }
            case .cut(let id):
                if let c = model.doc.timeline.cuts.first(where: { $0.id == id }) {
                    Label("Cut", systemImage: "scissors").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.cut)
                    Text("\(String(format: "%.2fs – %.2fs", c.start, c.end))\(c.reason.map { " · \($0)" } ?? "")").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            case .speed(let id):
                if let s = model.doc.timeline.speeds.first(where: { $0.id == id }) {
                    Label("Speed", systemImage: "hare").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.speed)
                    CommitSlider(label: "Rate", value: s.rate, range: 0.25...8, step: 0.25, format: { String(format: "%.2f×", $0) }) { model.apply([EditOperation(.updateSpeed, id: id, rate: $0)]) }
                }
            case .caption(let id):
                if let c = model.doc.timeline.captions.first(where: { $0.id == id }) {
                    Label("Caption", systemImage: "captions.bubble").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.caption)
                    CaptionEditor(text: c.text) { model.apply([EditOperation(.updateCaption, id: id, text: $0)]) }
                }
            case .voice(let id):
                if let c = model.doc.timeline.voiceover.first(where: { $0.id == id }) {
                    HStack { Label("Voiceover", systemImage: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.voice); Spacer(); origin(c.origin) }
                    Text(c.text).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(4)
                    Text(String(format: "starts %.2fs · %.1fs · %@", c.start, c.duration, c.voiceName ?? c.voice ?? "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                    CommitSlider(label: "Level", value: c.gain, range: 0...2, format: { String(format: "%.0f%%", $0 * 100) }) { model.apply([EditOperation(.updateVoiceover, id: id, gain: $0)]) }
                    Hint("Drag the clip on the Voice lane to move it, then Re-fit picture in the Voice tab.")
                }
            case .clip, .annotation, .redaction, .transition, .audio:
                // Shots, callouts, masks, transitions and audio bring their own remove action (a shot asks first).
                OverlayInspector(model: model, selection: selection)
            case .range(let a, let b):
                Label(String(format: "Selected %.2fs – %.2fs", a, b), systemImage: "selection.pin.in.out").font(.system(size: 12.5, weight: .semibold))
                HStack {
                    Button("Cut") { model.apply([EditOperation(.addCut, start: a, end: b, reason: "cut in editor")]); model.selection = nil }
                    Button("Zoom") { model.apply([EditOperation(.addZoom, start: a, end: b, scale: 2)]); model.selection = nil }
                    Menu("Speed") { ForEach([1.5, 2, 3, 4, 8], id: \.self) { r in Button("\(r.formatted())×") { model.apply([EditOperation(.setSpeed, start: a, end: b, rate: r)]); model.selection = nil } } }
                }.buttonStyle(GhostButtonStyle()).controlSize(.small)
            }
            if hasGenericDelete {
                Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(GhostButtonStyle())
            }
        }
    }
    /// Zooms, cuts, speeds, captions and voice clips share one Delete; the item inspectors have their own.
    var hasGenericDelete: Bool {
        switch selection {
        case .zoom, .cut, .speed, .caption, .voice: true
        default: false
        }
    }
    func origin(_ o: Origin) -> some View {
        Text(o == .auto ? "auto" : o == .agent ? "agent" : "manual").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08))).foregroundStyle(Theme.text2)
    }
}

struct CaptionEditor: View {
    @State var text: String
    let onCommit: (String) -> Void
    var body: some View {
        TextField("Caption", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit { onCommit(text) }
    }
}

extension EditorModel {
    func cursorFocusGuess(_ z: ZoomSegment) -> NormPoint {
        let mid = (z.start + z.end) / 2
        return Activity.pointer(at: mid, in: events.pointer) ?? .center
    }
}

// MARK: - Agent panel

struct AgentPanel: View {
    let model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Proposals", systemImage: "tray")
            let pending = model.proposals.filter { $0.status == .pending }.reversed()
            if pending.isEmpty {
                Hint("Edits proposed by agents (from Chat, a connected agent, or `glint plan` without --apply) appear here. Preview them on the player, then apply or reject.")
            }
            ForEach(Array(pending), id: \.id) { p in ProposalCard(model: model, proposal: p) }
            JobsPanel(model: model)
            SectionHeader(title: "History", systemImage: "clock.arrow.circlepath")
            if model.history.isEmpty { Text("No edits yet.").font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            ForEach(model.history.reversed().prefix(60), id: \.id) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.kind == .undo ? "arrow.uturn.backward" : r.kind == .redo ? "arrow.uturn.forward" : r.kind == .revert ? "arrow.counterclockwise" : "pencil")
                        .font(.system(size: 10)).foregroundStyle(Theme.text3).frame(width: 14).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.label).font(.system(size: 11.5)).lineLimit(2)
                        HStack(spacing: 6) {
                            AuthorBadge(author: r.author)
                            Text("r\(r.revision) · \(r.date.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(Theme.text3)
                        }
                    }
                    Spacer()
                    if r.kind == .edit {
                        Button { model.revert(r.id) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text3).help("Revert just this change")
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Export

/// Choose formats, then follow the render as a durable job: live progress, stages, cancel and retry, the files it
/// made and anything that needs a look. The job keeps running if the sheet closes (see Activity).
struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("GlintExportVariants") private var chosenRaw = "landscape"
    @State private var jobID: String?
    @State private var error: String?
    @State private var showProduction = false
    let presets: [(String, String, String)] = [("landscape", "Landscape 1080p", "16:9 · H.264"), ("landscape-4k", "Landscape 4K", "16:9 · HEVC"),
                                               ("square", "Square", "1:1 · follows the cursor"), ("portrait", "Vertical", "9:16 · follows the cursor"),
                                               ("gif", "GIF", "540p · 15 fps")]

    var chosen: Set<String> { Set(chosenRaw.split(separator: ",").map(String.init)).intersection(presets.map(\.0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: "square.and.arrow.up", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    Text(jobID == nil ? "Choose one or more formats. Each renders from the same edit." : "Rendering continues if you close this window. Follow it in Activity.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if let jobID {
                JobDetailView(model: model, jobID: jobID)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                variants
                if model.previewProposal != nil { Hint("Renders the proposal you're previewing, not the saved edit.") }
                DisclosureGroup(isExpanded: $showProduction) {
                    ProductionCheckForm(model: model) { id in jobID = id }.padding(.top, 8)
                } label: {
                    Text("Production check").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                }
            }
            if let error { InlineError(text: error) { self.error = nil } }
            HStack {
                if jobID != nil { Button("Export something else") { jobID = nil }.buttonStyle(LinkButtonStyle()) }
                Spacer()
                Button(jobID == nil ? "Cancel" : "Close") { dismiss() }.buttonStyle(GhostButtonStyle())
                if jobID == nil {
                    Button { start() } label: { Label("Render", systemImage: "film") }.buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty)
                }
            }
        }
        .padding(22).frame(width: 560)
        .background(Theme.panel)
    }

    var variants: some View {
        VStack(spacing: 6) {
            ForEach(presets, id: \.0) { p in
                let on = chosen.contains(p.0)
                HStack(spacing: 11) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 15)).foregroundStyle(on ? Theme.accent : Theme.text3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.1).font(.system(size: 13, weight: .medium))
                        Text(p.2).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accent.opacity(0.1) : Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.35) : Theme.hairline))
                .contentShape(Rectangle())
                .onTapGesture {
                    var c = chosen
                    if on { c.remove(p.0) } else { c.insert(p.0) }
                    chosenRaw = presets.map(\.0).filter(c.contains).joined(separator: ",")
                }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    func start() {
        error = nil
        let names = presets.map(\.0).filter(chosen.contains)
        do {
            let (job, existing) = try JobRunner.createRender(model.service, model.bundle, variants: names, proposal: model.previewProposal,
                                                              idempotencyKey: nil, expectedRevision: nil, inspect: true, author: .app)
            if !existing || job.status == .queued { JobLauncher.shared.start(model.service, model.bundle, job.id) }
            jobID = job.id
        } catch { self.error = "\(error)" }
    }
}
