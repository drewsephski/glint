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

enum SidebarTab: String, CaseIterable { case style = "Style", voice = "Voice", agent = "Agent" }

struct EditorView: View {
    let app: AppModel
    @Bindable var model: EditorModel
    @State private var tab: SidebarTab = SidebarTab(rawValue: UserDefaults.standard.string(forKey: "GlintSidebarTab") ?? "") ?? .style
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview
                    transport
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.hairline)
                sidebar.frame(width: 320)
            }
            Divider().overlay(Theme.hairline)
            TimelineEditor(model: model).frame(height: 230)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Button { app.closeEditor() } label: { Image(systemName: "chevron.left") }.buttonStyle(IconButtonStyle()).help("All projects")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.doc.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("rev \(model.doc.revision) · \(Theme.time(model.outputDuration)) of \(Theme.time(model.doc.media.duration)) · \(model.doc.media.width)×\(model.doc.media.height)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            if let banner = model.banner {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    Text(banner).font(.system(size: 11.5)).lineLimit(1)
                    Button { model.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Theme.raised))
                .frame(maxWidth: 380)
            }
            Spacer()
            Group {
                Button { model.autoZoom() } label: { Label("Auto Zoom", systemImage: "plus.magnifyingglass") }
                Button { model.tighten() } label: { Label("Tighten", systemImage: "scissors") }
                Button { model.captions() } label: { Label("Captions", systemImage: "captions.bubble") }
            }.buttonStyle(GhostButtonStyle())
            Divider().frame(height: 18)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(IconButtonStyle()).disabled(!model.canUndo).help("Undo ⌘Z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(IconButtonStyle()).disabled(!model.canRedo).help("Redo ⇧⌘Z")
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.leading, 78).padding(.trailing, 14).padding(.vertical, 9)
        .background(Theme.panel)
    }

    var preview: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
            PlayerSurface(player: model.player)
                .aspectRatio(CGFloat(RenderPlan.outputSize(document: model.previewDocument).0) / CGFloat(RenderPlan.outputSize(document: model.previewDocument).1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding(24)
            if let pid = model.previewProposal, let p = model.proposals.first(where: { $0.id == pid }) {
                HStack(spacing: 10) {
                    Image(systemName: "eye").foregroundStyle(Theme.accent)
                    Text("Previewing “\(p.title)” by \(p.author.name)").font(.system(size: 12, weight: .semibold))
                    Button("Apply") { model.acceptProposal(pid) }.buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { model.previewProposal = nil }.buttonStyle(GhostButtonStyle())
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.ultraThickMaterial)).padding(.top, 10)
            }
        }
    }

    var transport: some View {
        HStack(spacing: 14) {
            Button { model.seek(output: 0) } label: { Image(systemName: "backward.end.fill") }.buttonStyle(.plain)
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16)).frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }.buttonStyle(.plain)
            Text("\(Theme.time(model.currentTime, precise: true)) / \(Theme.time(model.outputDuration, precise: true))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
            Spacer()
            Picker("", selection: Binding(get: { model.doc.style.canvas.aspect }, set: { model.style("canvas.aspect", .string($0.rawValue)) })) {
                ForEach([Aspect.landscape, .square, .portrait, .classic, .auto], id: \.self) { a in Text(a == .auto ? "Source" : a.rawValue).tag(a) }
            }.pickerStyle(.segmented).frame(width: 300).controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SidebarTab.allCases, id: \.self) { t in
                    Text(t == .agent && model.proposals.contains(where: { $0.status == .pending }) ? "Agent •" : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented).padding(12)
            .onChange(of: tab) { _, t in UserDefaults.standard.set(t.rawValue, forKey: "GlintSidebarTab") }
            ScrollView {
                switch tab {
                case .style: InspectorView(model: model).padding(.horizontal, 12).padding(.bottom, 16)
                case .voice: VoicePanel(model: model).padding(.horizontal, 12).padding(.bottom, 16)
                case .agent: AgentPanel(model: model).padding(.horizontal, 12).padding(.bottom, 16)
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
            SectionHeader(title: "Background", systemImage: "paintpalette")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundPresets.all, id: \.name) { p in
                    let active = style.background.kind == .gradient && style.background.preset == p.name && style.background.colors.isEmpty
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: p.colors.map(Theme.color), startPoint: .bottomLeading, endPoint: .topTrailing))
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(active ? Color.white : Color.white.opacity(0.08), lineWidth: active ? 2 : 1))
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
            SectionHeader(title: "Cursor", systemImage: "cursorarrow")
            Card {
                Toggle("Show cursor", isOn: Binding(get: { style.cursor.visible }, set: { model.style("cursor.visible", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
                CommitSlider(label: "Size", value: style.cursor.scale, range: 0.5...4, format: { String(format: "%.1f×", $0) }) { model.style("cursor.scale", .number($0)) }
                CommitSlider(label: "Smoothing", value: style.cursor.smoothing, range: 0...1, format: { "\(Int($0 * 100))%" }) { model.style("cursor.smoothing", .number($0)) }
                CommitSlider(label: "Hide when idle after", value: style.cursor.hideAfterIdle, range: 0...8, format: { $0 == 0 ? "never" : String(format: "%.1fs", $0) }) { model.style("cursor.hideAfterIdle", .number($0)) }
                Toggle("Click ripple", isOn: Binding(get: { style.cursor.clickEffect }, set: { model.style("cursor.clickEffect", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
                Picker("Look", selection: Binding(get: { style.cursor.appearance }, set: { model.style("cursor.appearance", .string($0.rawValue)) })) {
                    Text("As recorded").tag(CursorStyle.Appearance.recorded)
                    Text("Glint arrow").tag(CursorStyle.Appearance.arrow)
                }.controlSize(.small)
            }
            SectionHeader(title: "Camera", systemImage: "camera.metering.center.weighted")
            Card {
                Picker("Motion", selection: Binding(get: { motionPreset }, set: { applyMotion($0) })) {
                    Text("Smooth").tag("smooth"); Text("Focused").tag("focused"); Text("Snappy").tag("snappy")
                    if motionPreset == "custom" { Text("Custom").tag("custom") }
                }.pickerStyle(.segmented).controlSize(.small)
                CommitSlider(label: "Motion blur", value: style.zoom.motionBlur, range: 0...1, format: { "\(Int($0 * 100))%" }) { model.style("zoom.motionBlur", .number($0)) }
                CommitSlider(label: "Follow dead zone", value: style.zoom.followDeadZone, range: 0.05...0.8, format: { "\(Int($0 * 100))%" }) { model.style("zoom.followDeadZone", .number($0)) }
            }
            SectionHeader(title: "Captions", systemImage: "captions.bubble")
            Card {
                Toggle("Show captions", isOn: Binding(get: { style.captions.enabled }, set: { model.style("captions.enabled", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
                Picker("Look", selection: Binding(get: { style.captions.look }, set: { model.style("captions.look", .string($0.rawValue)) })) {
                    Text("Highlight").tag(CaptionStyle.Look.highlight); Text("Pill").tag(CaptionStyle.Look.pill); Text("Plain").tag(CaptionStyle.Look.plain)
                }.pickerStyle(.segmented).controlSize(.small)
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
                    Toggle("Duck recorded audio under the voice", isOn: Binding(get: { style.audio.duckUnderVoiceover }, set: { model.style("audio.duckUnderVoiceover", .bool($0)) })).toggleStyle(.switch).controlSize(.small)
                    if style.audio.duckUnderVoiceover {
                        CommitSlider(label: "Duck to", value: style.audio.duckLevel, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }) { model.style("audio.duckLevel", .number($0)) }
                    }
                }
                if model.doc.media.microphone == nil && model.doc.media.systemAudio == nil && model.doc.timeline.voiceover.isEmpty { Hint("No audio tracks") }
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
                    })) { Text("Follow cursor").tag(0); Text("Fixed").tag(1) }.pickerStyle(.segmented).controlSize(.small)
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
            case .range(let a, let b):
                Label(String(format: "Selected %.2fs – %.2fs", a, b), systemImage: "selection.pin.in.out").font(.system(size: 12.5, weight: .semibold))
                HStack {
                    Button("Cut") { model.apply([EditOperation(.addCut, start: a, end: b, reason: "cut in editor")]); model.selection = nil }
                    Button("Zoom") { model.apply([EditOperation(.addZoom, start: a, end: b, scale: 2)]); model.selection = nil }
                    Menu("Speed") { ForEach([1.5, 2, 3, 4, 8], id: \.self) { r in Button("\(r.formatted())×") { model.apply([EditOperation(.setSpeed, start: a, end: b, rate: r)]); model.selection = nil } } }
                }.buttonStyle(GhostButtonStyle()).controlSize(.small)
            }
            if case .range = selection {} else {
                Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(GhostButtonStyle())
            }
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
                Hint("Edits proposed by agents (or by `glint plan` without --apply) appear here. Preview them on the player, then apply or reject.")
            }
            ForEach(Array(pending), id: \.id) { p in
                Card {
                    HStack { Text(p.title).font(.system(size: 12.5, weight: .semibold)); Spacer(); AuthorBadge(author: p.author) }
                    if !p.rationale.isEmpty {
                        Text(p.rationale).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(6)
                    }
                    Text("\(p.operations.count) operation\(p.operations.count == 1 ? "" : "s") · \(p.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    HStack {
                        Button(model.previewProposal == p.id ? "Previewing" : "Preview") { model.previewProposal = model.previewProposal == p.id ? nil : p.id }
                            .buttonStyle(GhostButtonStyle())
                        Spacer()
                        Button("Reject") { model.rejectProposal(p.id) }.buttonStyle(GhostButtonStyle())
                        Button("Apply") { model.acceptProposal(p.id) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
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

struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = ["landscape"]
    @State private var progress: [String: Double] = [:]
    @State private var manifest: RenderManifest?
    @State private var running = false
    @State private var error: String?
    let presets: [(String, String, String)] = [("landscape", "Landscape 1080p", "16:9 · H.264"), ("landscape-4k", "Landscape 4K", "16:9 · HEVC"),
                                               ("square", "Square", "1:1 · follows the cursor"), ("portrait", "Vertical", "9:16 · follows the cursor"),
                                               ("gif", "GIF", "540p · 15 fps")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 17, weight: .semibold))
            ForEach(presets, id: \.0) { p in
                HStack {
                    Toggle(isOn: Binding(get: { chosen.contains(p.0) }, set: { if $0 { chosen.insert(p.0) } else { chosen.remove(p.0) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.1).font(.system(size: 13, weight: .medium))
                            Text(p.2).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                    }.toggleStyle(.checkbox).disabled(running)
                    Spacer()
                    if let v = progress[p.0] { ProgressView(value: v).frame(width: 140) }
                }
            }
            if let m = manifest {
                Divider()
                ForEach(m.outputs, id: \.path) { o in
                    HStack {
                        Image(systemName: (o.report?.quality.failures.isEmpty ?? true) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle((o.report?.quality.failures.isEmpty ?? true) ? Theme.ok : Theme.speed)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(o.variant) · \(o.width)×\(o.height) · \(String(format: "%.1fs", o.duration))").font(.system(size: 12, weight: .medium))
                            if let q = o.report?.quality {
                                Text("quality \(q.score)/100" + (q.failures.isEmpty ? "" : " · " + q.failures.map(\.message).joined(separator: "; "))).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: o.path)]) }.buttonStyle(GhostButtonStyle())
                        Button("Save…") { save(o) }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.cut) }
            HStack {
                Spacer()
                Button(manifest == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(GhostButtonStyle())
                Button { run() } label: { Label(running ? "Rendering…" : "Render", systemImage: "film") }.buttonStyle(PrimaryButtonStyle()).disabled(running || chosen.isEmpty)
            }
        }
        .padding(22).frame(width: 560)
    }

    func run() {
        running = true; error = nil; manifest = nil
        let variants = presets.map(\.0).filter(chosen.contains).compactMap(RenderVariant.preset)
        let m = model
        Task {
            do {
                let result = try await m.service.render(m.bundle, variants: variants, proposal: m.previewProposal, author: .app) { name, p in
                    Task { @MainActor in progress[name] = p }
                }
                manifest = result
            } catch { self.error = "\(error)" }
            running = false
        }
    }

    func save(_ o: RenderOutput) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.doc.name) \(o.variant).\(URL(fileURLWithPath: o.path).pathExtension)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            // The user confirmed any overwrite in the save panel; remove first so the engine doesn't ask again.
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            _ = try model.service.export(file: URL(fileURLWithPath: o.path), to: dest, author: .app, approvalID: nil)
        } catch { self.error = "\(error)" }
    }
}
