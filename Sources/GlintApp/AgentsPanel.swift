import SwiftUI
import AppKit
import CoreGraphics
import GlintCore
import GlintAgent

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
        if !CGRequestScreenCaptureAccess() {
            // Already asked once: macOS only shows the prompt the first time, so send the person to the setting.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
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

/// Connect Glint to Claude Code, Codex and Claude Desktop, with status for each. Used on Home and in Settings.
struct AgentsPanel: View {
    @Bindable var model: AgentsModel
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Agents").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                            if model.loaded && model.installedCount > 0 {
                                StatusPill(text: "\(model.connectedCount) of \(model.installedCount) connected",
                                           tint: model.connectedCount == model.installedCount ? Theme.ok : Theme.text3)
                            }
                        }
                        Text("Agents use Glint's tools to record, edit, narrate and render. They propose changes; recording and anything sent online waits for your approval.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                    }
                    Spacer(minLength: 16)
                    Menu {
                        ForEach(OtherClient.allCases) { o in Button("Copy for \(o.title)") { model.copyConfig(for: o) } }
                    } label: {
                        MenuChip(title: "Other Clients")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Copy setup for Cursor, VS Code, Windsurf, Zed or another MCP client")
                    if model.connectable.count > 1 {
                        Button("Connect All") { model.connectAll() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(!model.busy.isEmpty || model.locationProblem != nil)
                    }
                }
            }
            if let o = model.copiedOther {
                Notice(text: "Copied the \(o.title) config. \(o.destination)", systemImage: "doc.on.clipboard", tint: Theme.accent)
            }
            if let problem = model.locationProblem {
                Notice(text: problem, systemImage: "exclamationmark.triangle", tint: Theme.speed)
            } else if model.isDevelopmentBuild {
                Notice(text: "This is a development build. Agents you connect here will run \(model.helper).", systemImage: "hammer", tint: Theme.text3)
            }
            VStack(spacing: 0) {
                ForEach(Array(AgentClient.allCases.enumerated()), id: \.element) { i, c in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    AgentRow(model: model, client: c, status: model.statuses.first { $0.client == c })
                }
                Divider().overlay(Theme.hairline)
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

private struct AgentRow: View {
    let model: AgentsModel
    let client: AgentClient
    let status: AgentStatus?

    var body: some View {
        let busy = model.busy.contains(client)
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: client.symbol)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(client.title).font(.system(size: 13, weight: .semibold))
                    StateLabel(state: status?.state, loading: !model.loaded)
                }
                Text(client.scope).font(.system(size: 11)).foregroundStyle(Theme.text3)
                if case .otherCopy(let cmd) = status?.state {
                    Text("Runs \(cmd)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                if case .misconfigured(let why) = status?.state { Text("The entry \(why).").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                if case .error(let e) = status?.state { Text(e).font(.system(size: 11)).foregroundStyle(Theme.cut).fixedSize(horizontal: false, vertical: true) }
                ForEach(status?.notes ?? [], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Theme.text3) }
                if let m = model.messages[client] {
                    Label(m.text, systemImage: m.isError ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: 11)).foregroundStyle(m.isError ? Theme.cut : Theme.text2).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                action(busy: busy)
                if let status, status.state != .notInstalled { menu(status) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    @ViewBuilder func action(busy: Bool) -> some View {
        switch status?.state {
        case nil:
            EmptyView()
        case .notInstalled:
            Button("Get \(client == .claudeDesktop ? "Claude" : client.title)") { NSWorkspace.shared.open(AgentsModel.downloadURL(client)) }
                .buttonStyle(GhostButtonStyle())
        case .connected:
            EmptyView()
        case .otherCopy, .disabled:
            rowButton(status?.state == .disabled ? "Turn On" : "Use This Copy", busy: busy)
        case .misconfigured:
            rowButton("Repair", busy: busy)
        case .notConnected:
            rowButton("Connect", busy: busy)
        case .error:
            EmptyView()
        }
    }

    /// One primary action on the panel at a time: rows are secondary when "Connect All" is showing.
    @ViewBuilder func rowButton(_ title: String, busy: Bool) -> some View {
        let disabled = busy || model.locationProblem != nil
        if model.connectable.count > 1 {
            Button(title) { model.connect(client) }.buttonStyle(GhostButtonStyle()).disabled(disabled)
        } else {
            Button(title) { model.connect(client) }.buttonStyle(PrimaryButtonStyle()).disabled(disabled)
        }
    }

    func menu(_ s: AgentStatus) -> some View {
        Menu {
            if s.configuredCommand != nil { Button("Disconnect") { model.disconnect(client) } }
            if s.state == .connected { Button("Reconnect") { model.connect(client) } }
            Button("Copy Manual Setup") { model.copyManual(client) }
            if client != .claudeCode { Button("Show Config File") { model.reveal(s) } }
        } label: {
            MenuChip(systemImage: "ellipsis")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More")
    }
}

private struct StateLabel: View {
    let state: AgentStatus.State?
    let loading: Bool
    var body: some View {
        let (text, color): (String, Color) = {
            if loading { return ("Checking", Theme.text3) }
            switch state {
            case .connected: return ("Connected", Theme.ok)
            case .notConnected: return ("Not connected", Theme.text3)
            case .notInstalled: return ("Not installed", Theme.text3)
            case .otherCopy: return ("Uses another copy of Glint", Theme.speed)
            case .disabled: return ("Turned off", Theme.speed)
            case .misconfigured: return ("Needs repair", Theme.speed)
            case .error: return ("Config error", Theme.cut)
            case nil: return ("", Theme.text3)
            }
        }()
        StatusPill(text: text, tint: color)
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
                Text("Agents record through Glint, so only Glint needs this permission, not your terminal or agent app.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                if !model.screenRecordingAllowed {
                    Text("Turned on in System Settings? Quit and reopen Glint; macOS applies the change after a restart. If it still says not allowed, the entry belongs to another build of Glint: Reset clears it so macOS can ask again.")
                        .font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let m = model.screenRecordingMessage { Text(m).font(.system(size: 11)).foregroundStyle(Theme.text) }
                }
            }
            Spacer(minLength: 12)
            if !model.screenRecordingAllowed {
                Menu {
                    Button("Ask for Permission") { model.requestScreenRecording() }
                    Button("Reset Permission") {
                        model.screenRecordingMessage = AppModel.resetScreenRecordingPermission()
                            ? "Reset. Allow Glint in the macOS prompt, then reopen Glint." : "Couldn't reset. Remove Glint in System Settings and add it again."
                    }
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
