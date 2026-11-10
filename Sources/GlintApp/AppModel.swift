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
    /// Serves agents' recording tools in this process (see CaptureBroker), so Screen Recording is Glint's permission.
    let captureHost: CaptureHost
    var projects: [ProjectSummary] = []
    var editor: EditorModel?
    var showRecordSheet = false
    var confirmTrashOpenProject = false
    var approvals: [ApprovalRequest] = []
    var agentSessions: [SessionRegistry.Entry] = []
    var recording: RecordingSession?
    var recordingStarted: Date?
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
        projects = service.listProjectURLs().prefix(40).compactMap { try? service.summary(ProjectBundle(url: $0)) }
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
            editor?.close()
            editor = try EditorModel(bundle: ProjectBundle(url: url), service: service)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch { self.error = "Couldn't open \(url.lastPathComponent): \(error)" }
    }

    /// Quit and open Glint again, which is what macOS needs before a new Screen Recording grant takes effect.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Clears Glint's Screen Recording entry and asks again. Fixes the case where System Settings shows Glint switched
    /// on but macOS still refuses: the entry belongs to a different build of Glint (same bundle ID, other signature),
    /// for example a development build. Returns false if the reset failed.
    @discardableResult
    static func resetScreenRecordingPermission() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        _ = CGRequestScreenCaptureAccess()      // macOS shows its prompt again now that the old entry is gone
        return true
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
                let (_, s) = try await service.startRecording(options: options, author: .app, approvalID: nil)
                recording = s
                recordingStarted = Date()
                showRecordSheet = false
                showHUD()
                // Glint's own windows are left out of these recordings, so the live picture never ends up in the take.
                // (Content chosen in the system picker can include them, so that path shows no bubble.)
                if let camera = s.cameraSession { showCameraBubble(camera) }
                s.onAutoStop = { [weak self] _ in Task { @MainActor in self?.recordingFinished() } }
            } catch { self.error = "\(error)" }
        }
    }

    // MARK: System picker

    private var pickerObserver: PickerObserver?
    private var pendingPickerOptions = RecordingOptions()

    func pickWithSystemPicker(options: RecordingOptions) {
        pendingPickerOptions = options
        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = [.singleDisplay, .singleWindow]
        cfg.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "dev.glint.Glint"]
        picker.defaultConfiguration = cfg
        let obs = PickerObserver { [weak self] filter in
            Task { @MainActor in
                guard let self else { return }
                SCContentSharingPicker.shared.isActive = false
                do {
                    let (_, s) = try await self.service.startRecording(filter: filter, options: self.pendingPickerOptions)
                    self.recording = s; self.recordingStarted = Date(); self.showRecordSheet = false; self.showHUD()
                } catch { self.error = "\(error)" }
            }
        }
        if let old = pickerObserver { picker.remove(old) }
        picker.add(obs)
        pickerObserver = obs
        picker.isActive = true
        picker.present()
    }

    func stopRecording() {
        Task {
            do {
                let b = try await service.stopRecording(nil)
                hideHUD()
                recording = nil
                refresh()
                open(b.url)
                NSApp.activate(ignoringOtherApps: true)
            } catch { self.error = "\(error)"; hideHUD(); recording = nil }
        }
    }

    private func recordingFinished() {
        hideHUD(); recording = nil; refresh()
        if let latest = service.listProjectURLs().first { open(latest) }
    }

    func markMoment() { _ = recording?.mark("marker") }

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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 54), styleMask: [.nonactivatingPanel, .borderless, .hudWindow], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(app: self))
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 115, y: screen.visibleFrame.maxY - 80)) }
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
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 12) {
                Circle().fill(Theme.cut).frame(width: 9, height: 9)
                Text(Theme.time(app.recording?.elapsed ?? 0, precise: false)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                Spacer()
                Button { app.markMoment() } label: {
                    Image(systemName: "flag.fill").font(.system(size: 12)).frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.1)))
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).help("Drop a marker")
                Button { app.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white).frame(width: 11, height: 11)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.cut))
                }.buttonStyle(.plain).help("Stop recording")
            }
            .padding(.leading, 18).padding(.trailing, 12).frame(width: 230, height: 54)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Theme.canvas.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(Theme.hairlineStrong))
        }
    }
}

final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    let onPick: (SCContentFilter) -> Void
    init(onPick: @escaping (SCContentFilter) -> Void) { self.onPick = onPick }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) { onPick(filter) }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {}
}
