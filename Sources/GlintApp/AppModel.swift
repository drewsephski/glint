import Foundation
import SwiftUI
import AppKit
import Observation
import GlintCore
import GlintCapture
import GlintAgent
import ScreenCaptureKit
import AVFoundation

@MainActor @Observable
final class AppModel {
    let service = GlintService()
    let agents = AgentsModel()
    /// The person's Claude and ChatGPT sign-ins, shared with every editor.
    let accounts = AccountsModel.shared
    /// Serves agents' recording tools in this process (see CaptureBroker), so Screen Recording is Glint's permission.
    let captureHost: CaptureHost
    var projects: [ProjectSummary] = []
    private(set) var projectCount = 0
    var showAllProjects = false
    var editor: EditorModel?
    var showRecordSheet = false
    var confirmTrashOpenProject = false
    var approvals: [ApprovalRequest] = []
    var agentSessions: [SessionRegistry.Entry] = []
    var recording: RecordingSession?
    /// The service's ID for `recording`, so Stop ends this take even while an agent records too.
    var recordingID: String?
    var recordingStarted: Date?
    /// The app's own take is paused (mirrors `recording.isPaused` for the menu bar and HUD).
    var recordingPaused = false
    /// Takes that never finished (Glint or the recorder crashed, was force-quit, lost power): offered for recovery on Home.
    var recoverable: [RecoverableRecording] = []
    var error: String?
    /// First-run setup covers Home until it's finished or skipped (see OnboardingView).
    var showOnboarding = false
    private var poller: Timer?
    private var hud: NSPanel?
    private var cameraBubble: NSPanel?

    init() {
        captureHost = CaptureHost(service: service)
        do { try captureHost.start() } catch { NSLog("Glint: not serving agent capture: \(error)") }
        agents.repairMovedEntries()
        refresh()
        poller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollGlobal() }
        }
        // `Glint -GlintOpenProject path/to/project.glint` opens straight into the editor (scripts, `glint open`).
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "GlintOpenProject") {
            open(URL(fileURLWithPath: path))
        }
        // Not when a script or an agent opened Glint for something specific.
        showOnboarding = !defaults.bool(forKey: Self.onboardedKey) && defaults.string(forKey: "GlintOpenProject") == nil
            && !defaults.bool(forKey: "GlintBackground")
    }

    static let onboardedKey = "GlintOnboarded"

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        UserDefaults.standard.removeObject(forKey: OnboardingView.stepKey)
        withAnimation(.smooth(duration: 0.35)) { showOnboarding = false }
    }

    /// Help › Welcome to Glint: run setup again from the first step.
    func replayOnboarding() {
        UserDefaults.standard.removeObject(forKey: OnboardingView.stepKey)
        closeEditor()
        withAnimation(.smooth(duration: 0.35)) { showOnboarding = true }
    }

    func refresh() {
        recoverable = service.recoverableRecordings()
        // Interrupted takes are offered in the recovery banner, not as (empty) projects.
        let interrupted = Set(recoverable.map(\.project))
        let urls = service.listProjectURLs().filter { !interrupted.contains($0.path) }
        projectCount = urls.count
        projects = urls.prefix(showAllProjects ? urls.count : 40).compactMap { try? service.summary(ProjectBundle(url: $0)) }
    }

    private func pollGlobal() {
        let a = service.approvals.pending()
        if a.map(\.id) != approvals.map(\.id) {
            approvals = a
            if !a.isEmpty { NSApp.requestUserAttention(.informationalRequest) }
        }
        // Agents' recordings run in this process now (forwarded by `glint mcp`); recordings started elsewhere, such as
        // `glint record` in a terminal, live in other processes. The app's own recording has its own HUD.
        let me = ProcessInfo.processInfo.processIdentifier
        let active = SessionRegistry.active().filter { $0.pid != me || $0.author.kind == .agent }
        // A recording that ended (an agent stopped it, or it hit its time limit) is now a project on Home.
        if !Set(agentSessions.map(\.id)).subtracting(active.map(\.id)).isEmpty { refresh() }
        agentSessions = active
    }

    func open(_ url: URL) {
        do {
            // Build the new editor first: if the project can't be read, the one that's open keeps working.
            let next = try EditorModel(bundle: ProjectBundle(url: url), service: service)
            editor?.close()
            editor = next
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch { self.error = "Couldn't open \(url.lastPathComponent): \(error)" }
    }

    private static var relaunchProcess: Process?

    /// Reopen this copy if macOS hasn't applied a changed grant. One bounded helper, even if Quit is cancelled.
    static func relaunch() {
        guard relaunchProcess?.isRunning != true else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            attempt=0
            while kill -0 "$1" 2>/dev/null; do
                attempt=$((attempt + 1))
                [ "$attempt" -lt 150 ] || exit 1
                sleep 0.2
            done
            exec /usr/bin/open "$2"
            """, "glint-relaunch", String(pid), Bundle.main.bundleURL.path]
        do { try p.run(); relaunchProcess = p }
        catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't reopen Glint"
            alert.informativeText = "\(error.localizedDescription) Quit and open this copy manually."
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Move a project to the Trash (Finder's Put Back restores it). Closes it first if it's open.
    func trash(_ url: URL) {
        if editor?.bundle.url.standardizedFileURL == url.standardizedFileURL { closeEditor() }
        do {
            _ = try service.deleteProject(ProjectBundle(url: url), author: .app, approvalID: nil, confirmedByUser: true)
            // Clear any request the app itself left waiting for this project (older versions asked for approval here).
            for r in service.approvals.pending() where r.requestedBy == .app && r.action == "delete_project" && r.parameters["project"]?.stringValue == url.path {
                _ = try? service.approvals.decide(r.id, approve: false, by: NSUserName())
            }
            approvals = service.approvals.pending()
            refresh()
        } catch { self.error = "Couldn't move \(url.deletingPathExtension().lastPathComponent) to the Trash: \(error)" }
    }

    func closeEditor() { editor?.close(); editor = nil; refresh() }

    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowedContentTypes = []
        p.directoryURL = GlintPaths.projects
        p.message = "Choose a .glint project"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func createDemo() {
        Task {
            do {
                let url = RecordingSession.makeProjectURL(name: "Glint Demo", directory: nil)
                let b = try await SyntheticProject.make(at: url, voice: false, narration: true)
                refresh(); open(b.url)
            } catch { self.error = "\(error)" }
        }
    }

    func decide(_ r: ApprovalRequest, approve: Bool) {
        do { _ = try service.approvals.decide(r.id, approve: approve, by: NSUserName()); approvals = service.approvals.pending() }
        catch { self.error = "\(error)" }
    }

    // MARK: Recording

    func startRecording(options: RecordingOptions) {
        Task {
            do {
                let (id, s) = try await service.startRecording(options: options, author: .app, approvalID: nil)
                adoptRecording(s, id: id)
                // Glint's own windows are left out of these recordings, so the live picture never ends up in the take.
                // (Content chosen in the system picker can include them, so that path shows no bubble.)
                if let camera = s.cameraSession { showCameraBubble(camera) }
            } catch { self.error = "\(error)" }
        }
    }

    /// The app's own take started: HUD, pause state, and what to do when it ends on its own.
    private func adoptRecording(_ s: RecordingSession, id: String) {
        recording = s
        recordingID = id
        recordingStarted = Date()
        recordingPaused = false
        showRecordSheet = false
        showHUD()
        s.onPauseChange = { [weak self] paused in MainActor.assumeIsolated { self?.recordingPaused = paused } }
        s.onAutoStop = { [weak self, weak s] r in
            let warnings = s?.warnings ?? []
            Task { @MainActor in self?.recordingFinished(r, warnings: warnings) }
        }
    }

    // MARK: System picker

    private var pickerObserver: PickerObserver?
    private var pickerRequestID: UUID?
    var choosingCaptureSource = false

    func pickWithSystemPicker(options: RecordingOptions) {
        guard !choosingCaptureSource, recording == nil else { return }
        choosingCaptureSource = true
        let requestID = UUID()
        pickerRequestID = requestID
        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = [.singleDisplay, .singleWindow]
        cfg.allowsChangingSelectedContent = false
        cfg.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "dev.glint.Glint"]
        picker.defaultConfiguration = cfg
        let obs = PickerObserver(onPick: { [weak self] filter in
            Task { @MainActor in
                guard let self, self.pickerRequestID == requestID else { return }
                self.pickerRequestID = nil  // Ignore duplicate selection callbacks while capture starts.
                do {
                    // Keep the picker active for the lifetime of its authorized stream.
                    let (id, s) = try await self.service.startRecording(filter: filter, options: options)
                    self.choosingCaptureSource = false
                    self.adoptRecording(s, id: id)
                } catch { self.endSystemPicker(); self.error = "\(error)" }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.pickerRequestID == requestID else { return }
                self.endSystemPicker()
            }
        }, onError: { [weak self] error in
            Task { @MainActor in
                guard let self, self.pickerRequestID == requestID else { return }
                self.endSystemPicker()
                self.error = "Couldn't open the System picker: \(error.localizedDescription)"
            }
        })
        if let old = pickerObserver { picker.remove(old) }
        picker.add(obs)
        pickerObserver = obs
        picker.isActive = true
        picker.present()
    }

    private func endSystemPicker() {
        let picker = SCContentSharingPicker.shared
        if let observer = pickerObserver { picker.remove(observer) }
        pickerObserver = nil
        pickerRequestID = nil
        choosingCaptureSource = false
        picker.isActive = false
    }

    func stopRecording() {
        Task {
            let session = recording
            do {
                let b = try await service.stopRecording(recordingID)
                endSystemPicker()
                hideHUD()
                recording = nil; recordingPaused = false
                refresh()
                open(b.url)
                NSApp.activate(ignoringOtherApps: true)
                showWarnings(session?.warnings ?? [])
            } catch { self.error = "\(error)"; endSystemPicker(); hideHUD(); recording = nil; recordingPaused = false; refresh() }
        }
    }

    /// The take ended on its own: its time limit, or the capture stopped (the error is among the warnings).
    private func recordingFinished(_ result: Result<ProjectBundle, Error>, warnings: [String]) {
        endSystemPicker()
        hideHUD(); recording = nil; recordingPaused = false; refresh()
        switch result {
        case .success(let b):
            open(b.url)
            showWarnings(warnings)
        case .failure(let e):
            error = "The recording couldn't be finished: \(e). It's listed under Interrupted recordings on Home, where you can recover it."
        }
    }

    private func showWarnings(_ warnings: [String]) {
        let unique = warnings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return }
        error = "The recording was saved, with \(unique.count == 1 ? "a warning" : "warnings"):\n" + unique.map { "• \($0)" }.joined(separator: "\n")
    }

    func markMoment() { _ = recording?.mark("marker") }

    /// Pause or resume the app's own take (HUD button, menu bar).
    func togglePause() {
        guard let s = recording, s.isRecording else { return }
        if s.isPaused { s.resume() } else { s.pause() }
        recordingPaused = s.isPaused
    }

    // MARK: Recovery

    func recover(_ r: RecoverableRecording) {
        Task {
            do {
                let result = try await service.recover(ProjectBundle(url: URL(fileURLWithPath: r.project)))
                refresh()
                open(URL(fileURLWithPath: result.project))
                error = "Recovered “\(r.name)”:\n" + result.notes.map { "• \($0)" }.joined(separator: "\n")
            } catch { self.error = "Couldn't recover “\(r.name)”: \(error)"; refresh() }
        }
    }

    /// Move an interrupted take to the Trash (the person confirmed in the dialog).
    func discard(_ r: RecoverableRecording) {
        do {
            _ = try service.discardRecording(ProjectBundle(url: URL(fileURLWithPath: r.project)), author: .app, approvalID: nil, confirmedByUser: true)
            refresh()
        } catch { self.error = "Couldn't move “\(r.name)” to the Trash: \(error)" }
    }

    /// Whether this app can stop a session (it runs here) rather than only show it.
    func ownsSession(_ id: String) -> Bool { service.session(id) != nil }

    /// Stop an agent's recording from the banner; the agent's next call sees the finished project.
    func stopAgentSession(_ id: String) {
        Task {
            do { _ = try await service.stopRecording(id, by: .app); refresh(); agentSessions.removeAll { $0.id == id } }
            catch { self.error = "\(error)" }
        }
    }

    func showHUD() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: RecordingHUD.width, height: 54), styleMask: [.nonactivatingPanel, .borderless, .hudWindow], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(app: self))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - RecordingHUD.width / 2, y: screen.visibleFrame.maxY - 80)) }
        panel.orderFrontRegardless()
        hud = panel
    }

    private func hideHUD() {
        hud?.orderOut(nil); hud = nil
        cameraBubble?.orderOut(nil); cameraBubble = nil
    }

    /// A floating, draggable picture of the camera while recording, to keep yourself in frame.
    private func showCameraBubble(_ session: AVCaptureSession) {
        let d: CGFloat = 164
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NSHostingView(rootView:
            CameraPreview(session: session)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                .padding(4)
                .frame(width: d, height: d)
                .help("Your camera. Drag to move it; it isn't part of the screen recording."))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - d - 24, y: screen.visibleFrame.minY + 24)) }
        panel.orderFrontRegardless()
        cameraBubble = panel
    }
}

struct RecordingHUD: View {
    let app: AppModel
    static let width: CGFloat = 268
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let paused = app.recordingPaused
            HStack(spacing: 10) {
                Group {
                    if paused { Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2) }
                    else { Circle().fill(Theme.cut) }
                }
                .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Theme.time(app.recording?.elapsed ?? 0, precise: false)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(paused ? Theme.text2 : .white)
                    if paused { Text("Paused").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text3) }
                }
                Spacer()
                Button { app.markMoment() } label: {
                    Image(systemName: "flag.fill").font(.system(size: 12)).frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.1)))
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).help("Drop a marker")
                Button { app.togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 12)).frame(width: 30, height: 30)
                        .background(Circle().fill(paused ? Theme.accent.opacity(0.28) : .white.opacity(0.1)))
                }.buttonStyle(.plain).foregroundStyle(paused ? Theme.accent : .white.opacity(0.85))
                    .help(paused ? "Resume recording" : "Pause recording (the pause becomes a cut)")
                    .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
                Button { app.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white).frame(width: 11, height: 11)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.cut))
                }.buttonStyle(.plain).help("Stop recording").accessibilityLabel("Stop recording")
            }
            .padding(.leading, 18).padding(.trailing, 12).frame(width: Self.width, height: 54)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Theme.canvas.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(Theme.hairlineStrong))
        }
    }
}

final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    let onPick: (SCContentFilter) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void
    init(onPick: @escaping (SCContentFilter) -> Void, onCancel: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.onPick = onPick; self.onCancel = onCancel; self.onError = onError
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        if stream == nil { onPick(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { onCancel() }
    func contentSharingPickerStartDidFailWithError(_ error: any Error) { onError(error) }
}
