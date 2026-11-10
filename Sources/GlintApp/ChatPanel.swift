import SwiftUI
import AppKit
import GlintCore
import GlintAgent

/// The conversation for one open project. Lives on the EditorModel so a turn keeps running while you switch tabs.
@MainActor @Observable
final class ChatModel {
    let bundle: ProjectBundle
    private(set) var transcript: ChatTranscript
    var agent: ChatAgent {
        didSet {
            UserDefaults.standard.set(agent.rawValue, forKey: "GlintChatAgent")
            if oldValue != agent, !transcript.entries.isEmpty, transcript.sessions[agent.rawValue] == nil {
                append(.init(role: .notice, text: "Switched to \(agent.title). It starts fresh and doesn't see the messages above."))
            }
        }
    }
    /// Installed agents and their CLI paths (looked up off the main thread).
    private(set) var available: [ChatAgent: String] = [:]
    private(set) var detected = false
    var draft = ""
    private var run: AgentChatRun?
    private var turn = 0
    var isRunning: Bool { run != nil }

    init(bundle: ProjectBundle) {
        self.bundle = bundle
        transcript = ChatTranscript.load(bundle)
        agent = ChatAgent(rawValue: UserDefaults.standard.string(forKey: "GlintChatAgent") ?? "") ?? .claudeCode
        // Anything left "running" from a previous launch didn't finish.
        for i in transcript.entries.indices where transcript.entries[i].running { transcript.entries[i].running = false }
        detect()
    }

    func detect() {
        Task.detached {
            var found: [ChatAgent: String] = [:]
            for a in ChatAgent.allCases { if let p = a.cliPath { found[a] = p } }
            await MainActor.run {
                self.available = found; self.detected = true
                if found[self.agent] == nil, let other = ChatAgent.allCases.first(where: { found[$0] != nil }) { self.agent = other }
            }
        }
    }

    func send(_ text: String? = nil) {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, run == nil else { return }
        guard let cli = available[agent] else {
            append(.init(role: .error, text: "\(agent.title) isn't installed on this Mac."))
            return
        }
        draft = ""
        append(.init(role: .user, text: message))
        turn += 1
        let turnID = turn
        let agent = agent
        let r = AgentChatRun(agent: agent, cli: cli, project: bundle.url, prompt: message, sessionID: transcript.sessions[agent.rawValue]) { [weak self] e in
            Task { @MainActor in self?.handle(e, agent: agent, turn: turnID) }
        }
        run = r
        do { try r.start() } catch {
            run = nil
            append(.init(role: .error, text: "Couldn't start \(agent.title): \(error)"))
        }
    }

    func stop() { run?.cancel() }

    func newChat() {
        stop()
        transcript = ChatTranscript()
        transcript.save(bundle)
    }

    private func handle(_ e: ChatEvent, agent: ChatAgent, turn: Int) {
        switch e {
        case .session(let id):
            transcript.sessions[agent.rawValue] = id
        case .message(let t):
            append(.init(role: .agent, agent: agent, text: t))
        case .toolStarted(let id, let name, let detail):
            append(.init(id: "\(turn)-\(id)", role: .tool, agent: agent, text: detail, tool: name, running: true))
        case .toolFinished(let id, let name, let outcome, let detail):
            if let i = transcript.entries.lastIndex(where: { $0.id == "\(turn)-\(id)" }) {
                transcript.entries[i].running = false
                transcript.entries[i].toolOutcome = outcome
                if !detail.isEmpty { transcript.entries[i].text = detail }
            } else {
                append(.init(role: .tool, agent: agent, text: detail, tool: name, toolOutcome: outcome))
            }
        case .failure(let msg):
            append(.init(role: msg == "Stopped." ? .notice : .error, text: msg))
        case .finished:
            for i in transcript.entries.indices where transcript.entries[i].running {
                transcript.entries[i].running = false
                if transcript.entries[i].toolOutcome == nil { transcript.entries[i].toolOutcome = .failed }
            }
            run = nil
        }
        transcript.save(bundle)
    }

    private func append(_ e: ChatTranscript.Entry) {
        transcript.entries.append(e)
        transcript.save(bundle)
    }
}

// MARK: - View

struct ChatPanel: View {
    let model: EditorModel
    @Bindable var chat: ChatModel
    @FocusState private var composerFocused: Bool

    static let suggestions = [
        "Tighten the pauses and add zooms on my clicks",
        "Add captions and check they're readable",
        "Make a 30-second vertical version",
        "Review the edit and tell me what to fix",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if chat.detected && chat.available.isEmpty {
                noAgents
            } else {
                transcript
                pendingProposals
                composer
            }
        }
        .onAppear { chat.detect() }
    }

    var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $chat.agent) {
                ForEach(ChatAgent.allCases) { a in
                    Text(chat.available[a] == nil && chat.detected ? "\(a.title) (not installed)" : a.title).tag(a)
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize().disabled(chat.isRunning)
            Spacer()
            Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle()).help("New chat").disabled(chat.transcript.entries.isEmpty && !chat.isRunning)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.transcript.entries.isEmpty { emptyState }
                    ForEach(chat.transcript.entries) { e in ChatRow(entry: e).id(e.id) }
                    if chat.isRunning, !(chat.transcript.entries.last?.running ?? false) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("\(chat.agent.title) is working…").font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }.id("working")
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.transcript.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(chat.isRunning ? "working" : chat.transcript.entries.last?.id, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(chat.transcript.entries.last?.id, anchor: .bottom) }
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask \(chat.agent.title) to work on this video").font(.system(size: 13, weight: .semibold))
            Hint("It uses Glint's tools on this project: planning zooms and cuts, captions, narration, renders and quality checks. Bigger changes come back as proposals you can preview and apply. It uses your own \(chat.agent == .codex ? "ChatGPT" : "Claude") sign-in.")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { chat.send(s) } label: {
                        Text(s).font(.system(size: 11.5)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.text2).disabled(chat.available[chat.agent] == nil)
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder var pendingProposals: some View {
        let pending = model.proposals.filter { $0.status == .pending }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending.suffix(2).reversed(), id: \.id) { p in ProposalCard(model: model, proposal: p, compact: true) }
                if pending.count > 2 { Hint("\(pending.count - 2) more in Activity.") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.canvas.opacity(0.4))
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(chat.agent.title)…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(composerFocused ? Theme.accent.opacity(0.5) : Theme.hairline))
                if chat.isRunning {
                    Button { chat.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(IconButtonStyle()).help("Stop")
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(IconButtonStyle()).help("Send (Return)")
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.available[chat.agent] == nil)
                }
            }
            Hint("Edits appear live in the editor and can be undone. Return sends.")
        }
        .padding(12)
    }

    var noAgents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat needs Claude Code or Codex").font(.system(size: 13, weight: .semibold))
            Hint("Install either one and sign in. Glint runs it in the background with this project's tools attached, using your own account.")
            HStack {
                Button("Get Claude Code") { NSWorkspace.shared.open(AgentsModel.downloadURL(.claudeCode)) }.buttonStyle(GhostButtonStyle())
                Button("Get Codex") { NSWorkspace.shared.open(AgentsModel.downloadURL(.codex)) }.buttonStyle(GhostButtonStyle())
            }
            Button("Check Again") { chat.detect() }.buttonStyle(GhostButtonStyle())
            Spacer()
        }
        .padding(14)
    }
}

private struct ChatRow: View {
    let entry: ChatTranscript.Entry
    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(entry.text).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.16)))
            }
        case .agent:
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.agent?.title ?? "Agent").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                Text(Self.markdown(entry.text)).font(.system(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .tool:
            HStack(alignment: .top, spacing: 7) {
                Group {
                    if entry.running { ProgressView().controlSize(.mini) }
                    else {
                        switch entry.toolOutcome {
                        case .ok: Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                        case .needsApproval: Image(systemName: "hand.raised").foregroundStyle(Theme.speed)
                        default: Image(systemName: "xmark").foregroundStyle(Theme.cut)
                        }
                    }
                }
                .font(.system(size: 9.5, weight: .bold)).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.tool ?? "tool").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                    if entry.toolOutcome == .needsApproval {
                        Text("Waiting for your approval in the banner above.").font(.system(size: 10.5)).foregroundStyle(Theme.speed)
                    } else if !entry.text.isEmpty {
                        Text(entry.text).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 1)
        case .notice:
            Text(entry.text).font(.system(size: 11)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .center)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(Theme.cut)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A pending proposal with Preview / Reject / Apply. Used in Activity and under the chat.
struct ProposalCard: View {
    let model: EditorModel
    let proposal: Proposal
    var compact = false
    var body: some View {
        Card {
            HStack { Text(proposal.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2); Spacer(); AuthorBadge(author: proposal.author) }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(compact ? 2 : 6)
            }
            if !compact {
                Text("\(proposal.operations.count) operation\(proposal.operations.count == 1 ? "" : "s") · \(proposal.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            HStack {
                Button(model.previewProposal == proposal.id ? "Previewing" : "Preview") { model.previewProposal = model.previewProposal == proposal.id ? nil : proposal.id }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Reject") { model.rejectProposal(proposal.id) }.buttonStyle(GhostButtonStyle())
                Button("Apply") { model.acceptProposal(proposal.id) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
