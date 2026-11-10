import SwiftUI
import AVFoundation
import GlintCore
import GlintCapture
import GlintAgent

struct HomeView: View {
    let app: AppModel
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Projects").font(.system(size: 22, weight: .semibold))
                    Text(app.projects.isEmpty ? "" : "\(app.projects.count)").font(.system(size: 13)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("Demo project") { app.createDemo() }.buttonStyle(GhostButtonStyle()).help("A synthetic recording to try the editor and the agent tools")
                    Button { app.openPanel() } label: { Label("Open", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(IconButtonStyle()).help("Settings")
                    Button { app.showRecordSheet = true } label: { Label("Record", systemImage: "record.circle") }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("r", modifiers: [.command, .shift])
                }
                if app.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No recordings yet").font(.system(size: 14, weight: .semibold))
                        Hint("Press ⇧⌘R to record a display or a window. Glint logs clicks and typing timing while it records, so it can plan zooms, cut pauses and split the take into scenes for narration.")
                    }
                    .padding(18).frame(maxWidth: 520, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(app.projects, id: \.path) { p in
                            ProjectCard(summary: p).onTapGesture { app.open(URL(fileURLWithPath: p.path)) }
                        }
                    }
                }
                AgentsPanel(model: app.agents).frame(maxWidth: 780, alignment: .leading).padding(.top, 10)
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 28)
        }
        .onAppear { app.refresh() }
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    @State private var thumb: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised)
                if let thumb {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous)).padding(10)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Theme.time(summary.outputDuration))
                    if summary.counts["zooms", default: 0] > 0 { Label("\(summary.counts["zooms"]!)", systemImage: "plus.magnifyingglass") }
                    if summary.counts["voiceover", default: 0] > 0 { Label("\(summary.counts["voiceover"]!)", systemImage: "waveform").foregroundStyle(Theme.voice) }
                    if !summary.pendingProposals.isEmpty { Label("\(summary.pendingProposals.count)", systemImage: "tray").foregroundStyle(Theme.accent) }
                    Spacer()
                    Text(summary.createdAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.text3).labelStyle(.titleAndIcon)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.raised : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.hairline))
        .onHover { hover = $0 }
        .task {
            let b = ProjectBundle(url: URL(fileURLWithPath: summary.path))
            guard let doc = try? b.readDocument() else { return }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: b.resolve(doc.media.screen)))
            g.maximumSize = CGSize(width: 520, height: 340)
            thumb = try? await g.image(at: CMTime(seconds: min(1, doc.media.duration / 2), preferredTimescale: 600)).image
        }
    }
}

struct RecordSheet: View {
    let app: AppModel
    @State private var sources: [CaptureSource] = []
    @State private var selected: CaptureSource?
    @State private var mic = false
    @State private var systemAudio = true
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New recording").font(.system(size: 17, weight: .semibold))
            if let loadError {
                Text(loadError).font(.system(size: 12)).foregroundStyle(Theme.cut)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Displays", systemImage: "display")
                    ForEach(sources.filter { $0.kind == .display }, id: \.id) { s in row(s, icon: "display") }
                    SectionHeader(title: "Windows", systemImage: "macwindow")
                    ForEach(sources.filter { $0.kind == .window }, id: \.id) { s in row(s, icon: "macwindow") }
                }
            }
            .frame(height: 300)
            HStack(spacing: 18) {
                Toggle("Microphone", isOn: $mic)
                Toggle("System audio", isOn: $systemAudio)
                Spacer()
            }.toggleStyle(.switch).controlSize(.small)
            Hint("Glint logs pointer, clicks and typing timing (never the keys themselves) to plan zooms and draw a smooth cursor.")
            HStack {
                Spacer()
                Button {
                    var o = RecordingOptions(); o.microphone = mic; o.systemAudio = systemAudio
                    app.pickWithSystemPicker(options: o)
                } label: { Label("System picker", systemImage: "rectangle.dashed") }
                .buttonStyle(GhostButtonStyle())
                .help("Choose with macOS's picker (no extra privacy prompt)")
                Spacer().frame(width: 12)
                Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle())
                Button {
                    var o = RecordingOptions()
                    if let s = selected { if s.kind == .display { o.displayID = s.id } else { o.windowID = s.id } }
                    o.microphone = mic; o.systemAudio = systemAudio
                    app.startRecording(options: o)
                } label: { Label("Record", systemImage: "record.circle.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            do {
                sources = try await Sources.list()
                selected = sources.first { $0.isMain == true } ?? sources.first
            } catch { loadError = "\(error)" }
        }
    }

    func row(_ s: CaptureSource, icon: String) -> some View {
        let isSel = selected == s
        return HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(isSel ? Theme.accent : Theme.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.app.map { "\($0): \(s.name)" } ?? s.name).font(.system(size: 12.5, weight: isSel ? .semibold : .regular)).lineLimit(1)
                Text("\(s.pixelWidth)×\(s.pixelHeight)").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if isSel { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? Theme.accent.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selected = s }
    }
}
