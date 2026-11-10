import SwiftUI
import AppKit
import CoreGraphics
import GlintCore
import GlintAgent
import GlintCapture

/// State behind the Agents panel: which agents are installed and connected, the CLI link, and Screen Recording.
/// Lookups shell out (the `claude` CLI, the login shell), so they run off the main thread.
@MainActor @Observable
final class AgentsModel {
    var statuses: [AgentStatus] = []
    var loaded = false
    var busy: Set<AgentClient> = []
    /// The latest outcome per client: what happened and what to do next.
    var messages: [AgentClient: Message] = [:]
    var cliLink: AgentSetup.CLILinkState = .missing
    var cliOnPath = true
    var cliMessage: Message?
    var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    var screenRecordingMessage: String?
    private var requestedScreenRecording = false
    /// What was last copied for another client, and where it goes.
    var copiedOther: OtherClient?
    /// Bumped by every refresh and every connect/disconnect, so a slow, older refresh can't overwrite newer state.
    private var generation = 0
    let helper = AgentSetup.helperPath()

    struct Message: Equatable { var text: String; var isError: Bool }

    var locationProblem: String? { AgentSetup.locationProblem(helper) }
    var isDevelopmentBuild: Bool { AgentSetup.location(of: helper) == .development }
    var connectedCount: Int { statuses.filter(\.isConnected).count }
    var installedCount: Int { statuses.filter { $0.state != .notInstalled }.count }

    func refresh() {
        let helper = helper
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        generation += 1
        let gen = generation
        Task.detached {
            let s = AgentSetup.statusAll(helper: helper)
            let link = AgentSetup.cliLinkState(helper: helper)
            let onPath = AgentSetup.cliLinkDirectoryOnPath()
            await MainActor.run {
                self.cliLink = link; self.cliOnPath = onPath; self.loaded = true
                // A connect or disconnect started after this refresh owns those rows' state.
                guard gen == self.generation, self.busy.isEmpty else {
                    for st in s where !self.busy.contains(st.client) && !self.statuses.contains(where: { $0.client == st.client }) { self.statuses.append(st) }
                    return
                }
                self.statuses = s
            }
        }
    }

    /// After Glint moves (a new version dragged to another folder, or out of Downloads), entries that point at a Glint
    /// helper that no longer exists are repaired. Entries pointing at a copy that still exists are left for the person.
    func repairMovedEntries() {
        guard AgentSetup.location(of: helper) == .installed else { return }
        let helper = helper
        Task.detached {
            var repaired: [AgentClient] = []
            for s in AgentSetup.statusAll(helper: helper) {
                guard case .otherCopy(let old) = s.state, old.hasSuffix("/Contents/Helpers/glint"),
                      !FileManager.default.fileExists(atPath: old) else { continue }
                if (try? AgentSetup.connect(s.client, helper: helper)) != nil { repaired.append(s.client) }
            }
            let done = repaired
            await MainActor.run {
                for c in done { self.messages[c] = Message(text: "Updated to this copy of Glint after it moved.", isError: false) }
                self.refresh()
            }
        }
    }

    /// Start the server the way the agent will before touching any config, so a failure leaves nothing half done
    /// and "Connected" always means it answers.
    func connect(_ c: AgentClient) {
        run(c) { helper in
            let tools: Int
            do { tools = try AgentSetup.selfTest(helper: helper) }
            catch { throw AgentSetupError("Nothing was changed: Glint's server didn't start (\(error)).") }
            var change = try AgentSetup.connect(c, helper: helper)
            change.followUp = [change.followUp, "Glint answered with \(tools) tools."].compactMap { $0 }.joined(separator: " ")
            return change
        }
    }

    /// Installed agents that aren't using this copy of Glint yet.
    var connectable: [AgentClient] {
        statuses.filter { s in
            switch s.state { case .notConnected, .otherCopy, .disabled, .misconfigured: true; default: false }
        }.map(\.client)
    }

    func connectAll() { for c in connectable { connect(c) } }
    func disconnect(_ c: AgentClient) { run(c) { _ in try AgentSetup.disconnect(c) } }

    private func run(_ c: AgentClient, _ work: @escaping @Sendable (String) throws -> AgentChange) {
        guard !busy.contains(c) else { return }
        busy.insert(c)
        messages[c] = nil
        generation += 1
        let helper = helper
        Task.detached {
            let result: Message
            do {
                let change = try work(helper)
                result = Message(text: change.followUp ?? change.summary, isError: false)
            } catch {
                result = Message(text: "\(error)", isError: true)
            }
            let status = AgentSetup.status(c, helper: helper)
            await MainActor.run {
                self.busy.remove(c)
                self.messages[c] = result
                if let i = self.statuses.firstIndex(where: { $0.client == c }) { self.statuses[i] = status }
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

    func copyConfig(for client: OtherClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.snippet(helper: helper), forType: .string)
        copiedOther = client
    }

    func copyManual(_ c: AgentClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentSetup.manualInstructions(c, helper: helper), forType: .string)
        messages[c] = Message(text: "Copied the manual setup.", isError: false)
    }

    func reveal(_ s: AgentStatus) {
        let path = (s.configLocation as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    static func downloadURL(_ c: AgentClient) -> URL {
        switch c {
        case .claudeCode: URL(string: "https://claude.com/claude-code")!
        case .codex: URL(string: "https://developers.openai.com/codex")!
        case .claudeDesktop: URL(string: "https://claude.ai/download")!
        }
    }
}

/// One switch: let the vendor's own app (Claude Code, the Claude app, Codex) use Glint's tools too. Shown under the
/// account it belongs to, so each of Claude and ChatGPT has a single place in Settings. Hidden when that app isn't
/// installed.
struct AppLinkRow: View {
    let model: AgentsModel
    let client: AgentClient

    var body: some View {
        if let status = model.statuses.first(where: { $0.client == client }), status.state != .notInstalled {
            let busy = model.busy.contains(client)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        Text(note(status)).font(.system(size: 11)).foregroundStyle(warns(status) ? Theme.speed : Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small) }
                    Toggle(title, isOn: Binding(get: { status.isConnected },
                                                set: { on in if on { model.connect(client) } else { model.disconnect(client) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(busy || (!status.isConnected && model.locationProblem != nil))
                    Menu {
                        if status.isConnected { Button("Reconnect") { model.connect(client) } }
                        Button("Copy Manual Setup") { model.copyManual(client) }
                        if client != .claudeCode { Button("Show Config File") { model.reveal(status) } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("More").accessibilityLabel("More options for \(client.title)")
                }
                if let m = model.messages[client], m.isError {
                    Label(m.text, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Theme.cut)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    var title: String {
        switch client {
        case .claudeCode: "Also use Glint inside Claude Code"
        case .claudeDesktop: "Also use Glint inside the Claude app"
        case .codex: "Also use Glint inside Codex and the ChatGPT app"
        }
    }

    func warns(_ s: AgentStatus) -> Bool {
        switch s.state { case .otherCopy, .misconfigured, .error, .disabled: true; default: false }
    }

    func note(_ s: AgentStatus) -> String {
        switch s.state {
        case .connected: "On. Ask it there to record, edit or render with Glint. New sessions pick it up."
        case .notConnected: "Off. Turn on to ask it for recordings and edits from there."
        case .otherCopy: "Set up for another copy of Glint. Turn on to use this one."
        case .disabled: "Switched off in its own settings. Turn on to enable it."
        case .misconfigured: "Needs repair. Turn on to fix it."
        case .error(let e): e
        case .notInstalled: ""
        }
    }
}

extension SubscriptionProvider {
    /// The vendor's apps that can use Glint's tools from outside Glint.
    var linkedApps: [AgentClient] { self == .claude ? [.claudeCode, .claudeDesktop] : [.codex] }
}

/// What Glint needs from this Mac: Screen Recording, the `glint` command, and setup for other tools.
struct MacSetupPanel: View {
    @Bindable var model: AgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This Mac").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                Spacer()
                Menu {
                    ForEach(OtherClient.allCases) { o in Button("Copy Setup for \(o.title)") { model.copyConfig(for: o) } }
                } label: {
                    MenuChip(title: "Other Apps")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Copy setup for Cursor, VS Code, Windsurf, Zed or another app that supports MCP")
            }
            if let o = model.copiedOther {
                Notice(text: "Copied the \(o.title) setup. \(o.destination)", systemImage: "doc.on.clipboard", tint: Theme.accent)
            }
            if let problem = model.locationProblem {
                Notice(text: problem, systemImage: "exclamationmark.triangle", tint: Theme.speed)
            } else if model.isDevelopmentBuild {
                Notice(text: "This is a development build. Apps you turn on here will run \(model.helper).", systemImage: "hammer", tint: Theme.text3)
            }
            VStack(spacing: 0) {
                ScreenRecordingRow(model: model)
                Divider().overlay(Theme.hairline)
                CLIRow(model: model)
            }
            .surface(radius: 14)
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
                Text("Needed to record. Claude and ChatGPT record through Glint, so only Glint needs this permission.")
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
