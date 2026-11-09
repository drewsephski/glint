import SwiftUI
import AVFoundation
import GlintCore
import GlintCapture
import GlintAgent

struct HomeView: View {
    let app: AppModel
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Glint").font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                        Text("Record a take. Get a polished demo. Let your agents do the rest.")
                            .font(.system(size: 14)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button { app.openPanel() } label: { Label("Open", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                    Button { app.showRecordSheet = true } label: { Label("New Recording", systemImage: "record.circle") }.buttonStyle(PrimaryButtonStyle())
                }
                AgentConnectCard()
                HStack {
                    SectionHeader(title: "Recent projects", systemImage: "film.stack")
                    Button("Try a demo project") { app.createDemo() }.buttonStyle(.link).font(.system(size: 12))
                }
                if app.projects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 40)).foregroundStyle(Theme.text3)
                        Text("No recordings yet").font(.system(size: 15, weight: .semibold))
                        Text("Press ⇧⌘R to record your screen, or create a demo project.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }.frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(app.projects, id: \.path) { p in
                            ProjectCard(summary: p).onTapGesture { app.open(URL(fileURLWithPath: p.path)) }
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 48).padding(.bottom, 30)
        }
        .onAppear { app.refresh() }
    }
}

struct AgentConnectCard: View {
    @State private var copied = false
    var cliPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/glint").path
        return FileManager.default.fileExists(atPath: bundled) ? bundled : "glint"
    }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Theme.agent)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.agent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent-native").font(.system(size: 13, weight: .semibold))
                Text("Every recording, edit and render is available to AI agents over MCP and the `glint` CLI — with undo, proposals and approvals.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            let cmd = "claude mcp add glint -- \"\(cliPath)\" mcp"
            Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                .frame(maxWidth: 360)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string); copied = true
            }.buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    @State private var thumb: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brand.opacity(0.35))
                if let thumb {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).padding(14)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(Theme.time(summary.outputDuration))
                    if summary.counts["zooms", default: 0] > 0 { Label("\(summary.counts["zooms"]!)", systemImage: "plus.magnifyingglass") }
                    if !summary.pendingProposals.isEmpty { Label("\(summary.pendingProposals.count)", systemImage: "sparkles").foregroundStyle(Theme.agent) }
                    Spacer()
                    Text(summary.createdAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.text3).labelStyle(.titleAndIcon)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.raised : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
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
            Text("New recording").font(.system(size: 20, weight: .bold, design: .rounded))
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
            Text("Glint logs pointer, clicks and typing *timing* (never the keys) so it can plan zooms and draw a smooth cursor.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack {
                Spacer()
                Button {
                    var o = RecordingOptions(); o.microphone = mic; o.systemAudio = systemAudio
                    app.pickWithSystemPicker(options: o)
                } label: { Label("System picker…", systemImage: "rectangle.dashed") }
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
                Text(s.app.map { "\($0) — \(s.name)" } ?? s.name).font(.system(size: 12.5, weight: isSel ? .semibold : .regular)).lineLimit(1)
                Text("\(s.pixelWidth)×\(s.pixelHeight)").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if isSel { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Theme.accent.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selected = s }
    }
}
