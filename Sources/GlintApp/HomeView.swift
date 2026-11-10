import SwiftUI
import AVFoundation
import GlintCore
import GlintCapture
import GlintAgent

struct HomeView: View {
    let app: AppModel
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)]
    @State private var trashCandidate: ProjectSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    GlintMark(size: 26)
                    Text("Projects").font(.system(size: 24, weight: .semibold)).tracking(-0.4).padding(.leading, 2)
                    if !app.projects.isEmpty {
                        Text("\(app.projects.count)").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    Spacer()
                    Button("Demo project") { app.createDemo() }.buttonStyle(GhostButtonStyle()).help("A synthetic recording to try the editor and the agent tools")
                    Button { app.openPanel() } label: { Label("Open", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(IconButtonStyle()).help("Settings")
                    Button { app.showRecordSheet = true } label: { Label("Record", systemImage: "record.circle") }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("r", modifiers: [.command, .shift])
                        .help("New recording ⇧⌘R")
                }
                if app.projects.isEmpty {
                    VStack(spacing: 14) {
                        IconTile(systemName: "record.circle", size: 48, tint: Theme.accent)
                        VStack(spacing: 6) {
                            Text("No recordings yet").font(.system(size: 16, weight: .semibold))
                            Text("Record a display or a window. Glint logs clicks and typing timing while it records, so it can plan zooms, cut pauses and split the take into scenes for narration.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
                        }
                        HStack(spacing: 8) {
                            Button { app.showRecordSheet = true } label: { Label("Record", systemImage: "record.circle") }.buttonStyle(PrimaryButtonStyle())
                            Button("Open the demo project") { app.createDemo() }.buttonStyle(GhostButtonStyle())
                            Keycap("⇧⌘R").padding(.leading, 4)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
                    .surface(radius: 14)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(app.projects, id: \.path) { p in
                            ProjectCard(summary: p, onOpen: { app.open(URL(fileURLWithPath: p.path)) }, onTrash: { trashCandidate = p })
                                .contextMenu {
                                    Button("Open") { app.open(URL(fileURLWithPath: p.path)) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                                    Divider()
                                    Button("Move to Trash…", role: .destructive) { trashCandidate = p }
                                }
                        }
                    }
                }
                AgentsPanel(model: app.agents).padding(.top, 8)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 36).padding(.top, 48).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.refresh() }
        .confirmationDialog("Move \"\(trashCandidate?.name ?? "")\" to the Trash?", isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let p = trashCandidate { app.trash(URL(fileURLWithPath: p.path)) }; trashCandidate = nil }
            Button("Cancel", role: .cancel) { trashCandidate = nil }
        } message: {
            Text("The recording, its edits and its renders move to the Trash. You can put it back from the Trash in Finder.")
        }
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    var onOpen: () -> Void = {}
    var onTrash: () -> Void = {}
    @State private var thumb: CGImage?
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    ZStack {
                        Theme.raised
                        if let thumb {
                            Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                        } else {
                            Image(systemName: "film").font(.system(size: 20)).foregroundStyle(Theme.text3)
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Text(Theme.time(summary.outputDuration)).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.68)))
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Button(action: onTrash) {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.68))).foregroundStyle(.white.opacity(0.92))
                        }
                        .buttonStyle(.plain).padding(8).help("Move to Trash").transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 9) {
                    Text(summary.createdAt.formatted(.relative(presentation: .named)))
                    Spacer(minLength: 4)
                    if summary.camera { Image(systemName: "person.crop.circle").help("Has a facecam") }
                    if summary.counts["zooms", default: 0] > 0 { Label("\(summary.counts["zooms"]!)", systemImage: "plus.magnifyingglass").help("Zooms") }
                    if summary.counts["voiceover", default: 0] > 0 { Label("\(summary.counts["voiceover"]!)", systemImage: "waveform").foregroundStyle(Theme.voice).help("Voiceover clips") }
                    if !summary.pendingProposals.isEmpty { Label("\(summary.pendingProposals.count)", systemImage: "tray").foregroundStyle(Theme.accent).help("Proposals waiting") }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.text3).labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
        }
        .background(hover ? Theme.raised : Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.55) : Theme.hairline))
        .shadow(color: .black.opacity(hover ? 0.4 : 0.2), radius: hover ? 16 : 8, y: hover ? 8 : 3)
        .offset(y: hover ? -2 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .task {
            let b = ProjectBundle(url: URL(fileURLWithPath: summary.path))
            guard let doc = try? b.readDocument() else { return }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: b.resolve(doc.media.screen)))
            g.maximumSize = CGSize(width: 760, height: 480)
            let image = try? await g.image(at: CMTime(seconds: min(1, doc.media.duration / 2), preferredTimescale: 600)).image
            withAnimation(.easeOut(duration: 0.25)) { thumb = image }
        }
    }
}

struct RecordSheet: View {
    let app: AppModel
    @State private var sources: [CaptureSource] = []
    @State private var selected: CaptureSource?
    @State private var mic = false
    @State private var systemAudio = true
    @AppStorage("GlintRecordCamera") private var camera = false
    @AppStorage("GlintRecordCameraID") private var cameraID = ""
    @State private var cameraPreview = CameraPreviewModel()
    @State private var cameraProblem: String?
    @State private var loadError: String?
    @State private var needsPermission = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(systemName: "record.circle", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New recording").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    Text("Choose a display or a window to record.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if needsPermission {
                ScreenPermissionHelp(app: app)
            } else if let loadError {
                Text(loadError).font(.system(size: 12)).foregroundStyle(Theme.cut)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SectionHeader(title: "Displays", systemImage: "display").padding(.horizontal, 6).padding(.bottom, 3)
                    ForEach(sources.filter { $0.kind == .display }, id: \.id) { s in SourceRow(source: s, icon: "display", selected: selected == s) { selected = s } }
                    SectionHeader(title: "Windows", systemImage: "macwindow").padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 3)
                    ForEach(sources.filter { $0.kind == .window }, id: \.id) { s in SourceRow(source: s, icon: "macwindow", selected: selected == s) { selected = s } }
                }
                .padding(8)
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            HStack(spacing: 22) {
                Toggle("Microphone", isOn: $mic)
                Toggle("System audio", isOn: $systemAudio)
                Toggle("Camera", isOn: $camera)
                Spacer()
            }.toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong).font(.system(size: 12.5))
            if camera { cameraRow }
            if let cameraProblem {
                HStack(spacing: 8) {
                    Text(cameraProblem).font(.system(size: 11.5)).foregroundStyle(Theme.speed).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if Cameras.isDenied {
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            Hint("Glint logs pointer, clicks and typing timing (never the keys themselves) to plan zooms and draw a smooth cursor.")
            HStack {
                Spacer()
                Button {
                    app.pickWithSystemPicker(options: options())
                } label: { Label("System picker", systemImage: "rectangle.dashed") }
                .buttonStyle(GhostButtonStyle())
                .help("Choose with macOS's picker (no extra privacy prompt)")
                Spacer().frame(width: 12)
                Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle())
                Button {
                    var o = options()
                    if let s = selected { if s.kind == .display { o.displayID = s.id } else { o.windowID = s.id } }
                    app.startRecording(options: o)
                } label: { Label("Record", systemImage: "record.circle.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.panel)
        .task {
            await loadSources()
        }
        .task { if camera { await enableCamera() } }
        .onChange(of: camera) { _, on in
            if on { Task { await enableCamera() } } else { cameraPreview.stop(); cameraProblem = nil }
        }
        .onChange(of: cameraID) { _, id in if camera { cameraPreview.show(deviceID: cameraPreview.resolved(id)) } }
        .onDisappear { cameraPreview.stop() }
        // Coming back from System Settings: try again (it works once macOS has applied the change).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if loadError != nil { Task { await loadSources() } }
        }
    }

    /// The live picture and, with more than one camera, which one to use.
    var cameraRow: some View {
        HStack(spacing: 12) {
            CameraPreview(session: cameraPreview.session)
                .id(cameraPreview.generation)
                .frame(width: 56, height: 56)
                .background(Theme.well)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.hairlineStrong))
            VStack(alignment: .leading, spacing: 5) {
                if cameraPreview.devices.count > 1 {
                    Picker("Camera", selection: Binding(get: { cameraPreview.resolved(cameraID) ?? cameraPreview.devices.first?.id ?? "" }, set: { cameraID = $0 })) {
                        ForEach(cameraPreview.devices, id: \.id) { d in Text(d.name).tag(d.id) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 260, alignment: .leading)
                } else if let d = cameraPreview.devices.first {
                    Text(d.name).font(.system(size: 12.5, weight: .medium))
                }
                Hint("Recorded as its own track and shown as a bubble over the screen. Move, resize or hide it in the editor.")
            }
            Spacer(minLength: 0)
        }
    }

    func options() -> RecordingOptions {
        var o = RecordingOptions()
        o.microphone = mic; o.systemAudio = systemAudio
        o.camera = camera && !cameraPreview.devices.isEmpty
        o.cameraID = cameraPreview.resolved(cameraID)
        // The recording opens the camera itself.
        cameraPreview.stop()
        return o
    }

    /// Asks for the camera the first time, then shows its picture. Turns the switch back off when there is nothing to record.
    func enableCamera() async {
        guard await Cameras.requestAccess() else {
            camera = false
            cameraProblem = "Glint isn't allowed to use the camera. Turn on Glint in System Settings › Privacy & Security › Camera."
            return
        }
        cameraPreview.refreshDevices()
        guard !cameraPreview.devices.isEmpty else {
            camera = false
            cameraProblem = "No camera found."
            return
        }
        cameraProblem = nil
        cameraPreview.show(deviceID: cameraPreview.resolved(cameraID))
    }

    func loadSources() async {
        do {
            sources = try await Sources.list()
            if selected == nil || !sources.contains(where: { $0.id == selected?.id && $0.kind == selected?.kind }) {
                selected = sources.first { $0.isMain == true } ?? sources.first
            }
            loadError = nil; needsPermission = false
        } catch CaptureError.permissionDenied {
            needsPermission = true; loadError = CaptureError.permissionDenied.description
        } catch { needsPermission = false; loadError = "\(error)" }
    }
}

private struct SourceRow: View {
    let source: CaptureSource
    let icon: String
    let selected: Bool
    let select: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5)).frame(width: 18).foregroundStyle(selected ? Theme.accent : Theme.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.app.map { "\($0): \(source.name)" } ?? source.name).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text("\(source.pixelWidth)×\(source.pixelHeight)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : hover ? Color.white.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What to do when Glint can't list displays and windows. Plain steps, and the two actions that fix it.
struct ScreenPermissionHelp: View {
    let app: AppModel
    @State private var resetMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 13)).foregroundStyle(Theme.speed)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glint needs Screen Recording to list displays and windows").font(.system(size: 12.5, weight: .semibold))
                    Text("Turn on Glint in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Glint: macOS applies the change after a restart. Still refused after reopening, even though Glint shows as on? The entry belongs to another build of Glint; Reset Permission clears it so macOS can ask again. The System picker works either way.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let resetMessage { Text(resetMessage).font(.system(size: 11.5)).foregroundStyle(Theme.text) }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Reset Permission") {
                    resetMessage = AppModel.resetScreenRecordingPermission()
                        ? "Reset. Allow Glint in the macOS prompt (or in System Settings), then quit and reopen Glint."
                        : "Couldn't reset the permission. Remove Glint from the list in System Settings, then add it again."
                }.buttonStyle(GhostButtonStyle())
                Button("Open System Settings") { AppModel.openScreenRecordingSettings() }.buttonStyle(GhostButtonStyle())
                Button("Quit & Reopen Glint") { AppModel.relaunch() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.speed.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.speed.opacity(0.22)))
    }
}
