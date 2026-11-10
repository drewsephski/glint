import SwiftUI
import AppKit
import CoreGraphics
import GlintCore
import GlintAgent
import GlintCapture

/// Mac permissions and the optional command-line helper. External app connections remain CLI-only.
@MainActor @Observable
final class AgentsModel {
    var cliLink: AgentSetup.CLILinkState = .missing
    var cliOnPath = true
    var cliMessage: Message?
    var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    var screenRecordingMessage: String?
    private var requestedScreenRecording = false
    let helper = AgentSetup.helperPath()

    struct Message: Equatable { var text: String; var isError: Bool }
    var locationProblem: String? { AgentSetup.locationProblem(helper) }

    func refresh() {
        let helper = helper
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        Task.detached {
            let link = AgentSetup.cliLinkState(helper: helper)
            let onPath = AgentSetup.cliLinkDirectoryOnPath()
            await MainActor.run { self.cliLink = link; self.cliOnPath = onPath }
        }
    }

    /// Preserve previously configured CLI integrations when the app moves.
    func repairMovedEntries() {
        guard AgentSetup.location(of: helper) == .installed else { return }
        let helper = helper
        Task.detached {
            for status in AgentSetup.statusAll(helper: helper) {
                guard case .otherCopy(let old) = status.state, old.hasSuffix("/Contents/Helpers/glint"),
                      !FileManager.default.fileExists(atPath: old) else { continue }
                _ = try? AgentSetup.connect(status.client, helper: helper)
            }
        }
    }

    func installCLI() {
        do {
            try AgentSetup.installCLILink(helper: helper)
            cliMessage = cliOnPath ? Message(text: "Open a new terminal and run glint.", isError: false)
                                   : Message(text: "Add ~/.local/bin to your PATH to run it by name.", isError: false)
        } catch { cliMessage = Message(text: "\(error)", isError: true) }
        cliLink = AgentSetup.cliLinkState(helper: helper)
    }

    func removeCLI() {
        do { try AgentSetup.removeCLILink(); cliMessage = nil } catch { cliMessage = Message(text: "\(error)", isError: true) }
        cliLink = AgentSetup.cliLinkState(helper: helper)
    }

    func requestScreenRecording() {
        screenRecordingAllowed = Sources.hasScreenRecordingPermission
        guard !screenRecordingAllowed else { screenRecordingMessage = nil; return }
        if requestedScreenRecording {
            AppModel.openScreenRecordingSettings()
            return
        }
        requestedScreenRecording = true
        // Don't open Settings on top of the OS prompt. Subsequent requests navigate there explicitly.
        _ = CGRequestScreenCaptureAccess()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        screenRecordingMessage = screenRecordingAllowed ? nil : "Allow access in the macOS prompt, then return to Glint. If access still isn't available, reopen this copy."
    }

}

/// Optional permission and command-line details, tucked below the account choices.
struct MacSetupPanel: View {
    @Bindable var model: AgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ScreenRecordingRow(model: model)
            }
            .surface(radius: 14)
            DisclosureGroup("Command line") { CLIRow(model: model).padding(.top, 8) }
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

private struct ScreenRecordingRow: View {
    let model: AgentsModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: "rectangle.dashed.badge.record")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Screen Recording").font(.system(size: 13, weight: .semibold))
                    StatusPill(text: model.screenRecordingAllowed ? "Allowed" : "Not allowed yet", tint: model.screenRecordingAllowed ? Theme.ok : Theme.text3)
                }
                Text("Allow Glint to capture your screen.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                if !model.screenRecordingAllowed {
                    Text(CaptureError.permissionDenied.description)
                        .font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let m = model.screenRecordingMessage { Text(m).font(.system(size: 11)).foregroundStyle(Theme.text) }
                }
            }
            Spacer(minLength: 12)
            if !model.screenRecordingAllowed {
                Menu {
                    Button("Ask for Permission") { model.requestScreenRecording() }
                    Button("Open System Settings") { AppModel.openScreenRecordingSettings() }
                } label: {
                    MenuChip(title: "Fix…")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button("Reopen") { AppModel.relaunch() }.buttonStyle(GhostButtonStyle()).help("Quit and reopen Glint")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }
}

private struct CLIRow: View {
    let model: AgentsModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: "chevron.forward.square")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Command line").font(.system(size: 13, weight: .semibold))
                    StatusPill(text: label, tint: model.cliLink == .linked ? Theme.ok : model.cliLink == .missing ? Theme.text3 : Theme.speed)
                }
                Text("Run glint from any terminal: glint connect, glint record, glint autopilot. Installs a link in ~/.local/bin.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                if model.cliLink == .linked && !model.cliOnPath {
                    Text("~/.local/bin isn't on your PATH. Add  export PATH=\"$HOME/.local/bin:$PATH\"  to ~/.zshrc.")
                        .font(.system(size: 11)).foregroundStyle(Theme.speed).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let m = model.cliMessage {
                    Text(m.text).font(.system(size: 11)).foregroundStyle(m.isError ? Theme.cut : Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            switch model.cliLink {
            case .linked: Button("Remove") { model.removeCLI() }.buttonStyle(GhostButtonStyle())
            case .otherCopy: Button("Use this copy") { model.installCLI() }.buttonStyle(GhostButtonStyle()).disabled(model.locationProblem != nil)
            case .missing: Button("Install") { model.installCLI() }.buttonStyle(GhostButtonStyle()).disabled(model.locationProblem != nil)
            case .notALink: EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    var label: String {
        switch model.cliLink {
        case .linked: "Installed"
        case .missing: "Not installed"
        case .otherCopy: "Links to another copy"
        case .notALink: "~/.local/bin/glint is another file"
        }
    }
}

struct Notice: View {
    let text: String
    let systemImage: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 11.5)).foregroundStyle(tint)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.2)))
    }
}
