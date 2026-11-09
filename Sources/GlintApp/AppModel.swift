import Foundation
import SwiftUI
import AppKit
import Observation
import GlintCore
import GlintCapture
import GlintAgent
import ScreenCaptureKit

@MainActor @Observable
final class AppModel {
    let service = GlintService()
    var projects: [ProjectSummary] = []
    var editor: EditorModel?
    var showRecordSheet = false
    var approvals: [ApprovalRequest] = []
    var agentSessions: [SessionRegistry.Entry] = []
    var recording: RecordingSession?
    var recordingStarted: Date?
    var error: String?
    private var poller: Timer?
    private var hud: NSPanel?

    init() {
        refresh()
        poller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollGlobal() }
        }
        // `Glint -GlintOpenProject path/to/project.glint` opens straight into the editor (scripts, `glint open`).
        if let path = UserDefaults.standard.string(forKey: "GlintOpenProject") {
            open(URL(fileURLWithPath: path))
        }
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
        agentSessions = SessionRegistry.active().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
    }

    func open(_ url: URL) {
        do {
            editor?.close()
            editor = try EditorModel(bundle: ProjectBundle(url: url), service: service)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch { self.error = "Couldn't open \(url.lastPathComponent): \(error)" }
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
                let b = try await SyntheticProject.make(at: url, voice: true)
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

    private func hideHUD() { hud?.orderOut(nil); hud = nil }
}

struct RecordingHUD: View {
    let app: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 12) {
                Circle().fill(Color.red).frame(width: 10, height: 10).shadow(color: .red, radius: 4)
                Text(Theme.time(app.recording?.elapsed ?? 0, precise: false)).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                Spacer()
                Button { app.markMoment() } label: { Image(systemName: "flag.fill") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).help("Drop a marker")
                Button { app.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
                        .padding(8).background(Circle().fill(Color.red))
                }.buttonStyle(.plain).help("Stop recording")
            }
            .padding(.horizontal, 16).frame(width: 230, height: 54)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(.black.opacity(0.82)))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(.white.opacity(0.1)))
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
