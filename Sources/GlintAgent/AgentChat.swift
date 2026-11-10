import Foundation
import GlintCore

/// Chat with Claude Code or Codex about one project, from inside Glint.
///
/// Each message runs the agent's own CLI headless (`claude -p … --output-format stream-json`, `codex exec --json`)
/// with Glint's MCP server attached, using the person's existing Claude or ChatGPT sign-in. Follow-ups resume the same
/// session, so the agent remembers the conversation. The agent edits through the same tools and approvals as any
/// other client: its changes show up live in the editor, attributed to it, and anything gated waits for the person.
public enum ChatAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude-code", codex
    public var id: String { rawValue }
    public var title: String { self == .claudeCode ? "Claude Code" : "Codex" }

    /// The CLI to run, or nil when it isn't installed.
    public var cliPath: String? { self == .claudeCode ? ClaudeCLI.find() : CodexCLI.find() }
}

public enum ChatEvent: Equatable, Sendable {
    /// The agent's session/thread ID, for resuming.
    case session(String)
    /// A complete message from the agent.
    case message(String)
    case toolStarted(id: String, name: String, detail: String)
    case toolFinished(id: String, name: String, outcome: ToolOutcome, detail: String)
    case failure(String)
    /// The turn ended. `ok` false when the agent reported an error.
    case finished(ok: Bool)

    public enum ToolOutcome: String, Equatable, Sendable { case ok, failed, needsApproval }
}

// MARK: - Parsing

public enum ChatParser {
    /// `mcp__glint__glint_plan_zooms` / `glint_plan_zooms` → `plan_zooms`.
    public static func toolName(_ raw: String) -> String {
        var n = raw
        if n.hasPrefix("mcp__glint__") { n.removeFirst("mcp__glint__".count) }
        if n.hasPrefix("glint_") { n.removeFirst("glint_".count) }
        return n
    }

    /// The interesting arguments in one short line (the project path is always the same, so it's left out).
    public static func argumentSummary(_ args: JSONValue?) -> String {
        guard case .object(let o)? = args else { return "" }
        let parts = o.filter { $0.key != "project" && $0.key != "approval_id" }.sorted { $0.key < $1.key }.map { k, v -> String in
            switch v {
            case .string(let s): return "\(k): \(s.count > 40 ? String(s.prefix(40)) + "…" : s)"
            case .array(let a): return "\(k): \(a.count) item\(a.count == 1 ? "" : "s")"
            case .object: return "\(k): {…}"
            default: return "\(k): \(v)"
            }
        }
        let s = parts.joined(separator: ", ")
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }

    static func outcome(isError: Bool, text: String) -> ChatEvent.ToolOutcome {
        if text.contains("approval_required") { return .needsApproval }
        return isError ? .failed : .ok
    }

    static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = t.split(separator: "\n").first.map(String.init) ?? t
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }

    /// One line of `claude -p --output-format stream-json --verbose`.
    public static func claude(_ line: Data, toolNames: inout [String: String]) -> [ChatEvent] {
        guard let v = try? JSONCoding.decoder.decode(JSONValue.self, from: line), let type = v["type"]?.stringValue else { return [] }
        switch type {
        case "system":
            if v["subtype"]?.stringValue == "init", let sid = v["session_id"]?.stringValue { return [.session(sid)] }
            return []
        case "assistant":
            var out: [ChatEvent] = []
            for block in v["message"]?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let t = block["text"]?.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.message(t)) }
                case "tool_use":
                    let id = block["id"]?.stringValue ?? UUID().uuidString
                    let name = toolName(block["name"]?.stringValue ?? "tool")
                    toolNames[id] = name
                    out.append(.toolStarted(id: id, name: name, detail: argumentSummary(block["input"])))
                default: break
                }
            }
            return out
        case "user":
            var out: [ChatEvent] = []
            for block in v["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                let id = block["tool_use_id"]?.stringValue ?? ""
                let text: String
                if let s = block["content"]?.stringValue { text = s }
                else { text = (block["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n") }
                let o = outcome(isError: block["is_error"]?.boolValue == true, text: text)
                out.append(.toolFinished(id: id, name: toolNames[id] ?? "tool", outcome: o, detail: o == .ok ? "" : firstLine(text)))
            }
            return out
        case "result":
            var out: [ChatEvent] = []
            if let sid = v["session_id"]?.stringValue { out.append(.session(sid)) }
            let isError = v["is_error"]?.boolValue == true || (v["subtype"]?.stringValue.map { $0 != "success" } ?? false)
            if isError { out.append(.failure(v["result"]?.stringValue.map(firstLine) ?? "Claude Code stopped with an error (\(v["subtype"]?.stringValue ?? "unknown")).")) }
            out.append(.finished(ok: !isError))
            return out
        default:
            return []
        }
    }

    /// One line of `codex exec --json`.
    public static func codex(_ line: Data) -> [ChatEvent] {
        guard let v = try? JSONCoding.decoder.decode(JSONValue.self, from: line), let type = v["type"]?.stringValue else { return [] }
        switch type {
        case "thread.started":
            return v["thread_id"]?.stringValue.map { [.session($0)] } ?? []
        case "item.started", "item.completed":
            guard let item = v["item"] else { return [] }
            let id = item["id"]?.stringValue ?? UUID().uuidString
            switch item["type"]?.stringValue {
            case "agent_message" where type == "item.completed":
                return item["text"]?.stringValue.map { [.message($0)] } ?? []
            case "mcp_tool_call":
                let name = toolName(item["tool"]?.stringValue ?? "tool")
                if type == "item.started" { return [.toolStarted(id: id, name: name, detail: argumentSummary(item["arguments"]))] }
                let resultText = (item["result"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                let errorText = item["error"]?["message"]?.stringValue ?? item["error"]?.stringValue ?? ""
                let failed = item["status"]?.stringValue == "failed" || !errorText.isEmpty || item["result"]?["is_error"]?.boolValue == true
                let o = outcome(isError: failed, text: resultText + errorText)
                return [.toolFinished(id: id, name: name, outcome: o, detail: o == .ok ? "" : firstLine(errorText.isEmpty ? resultText : errorText))]
            default:
                // Codex reports unrelated problems (other MCP servers, feature notices) as error items: not chat content.
                return []
            }
        case "turn.completed":
            return [.finished(ok: true)]
        case "turn.failed":
            return [.failure(v["error"]?["message"]?.stringValue.map(firstLine) ?? "Codex stopped with an error."), .finished(ok: false)]
        case "error":
            return [.failure(v["message"]?.stringValue.map(firstLine) ?? "Codex reported an error.")]
        default:
            return []
        }
    }
}

// MARK: - Running

/// One turn: starts the CLI, streams parsed events to `onEvent` (on a background thread), and ends with `.finished`.
public final class AgentChatRun: @unchecked Sendable {
    public let agent: ChatAgent
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var sawFinish = false

    public static func systemContext(project: URL) -> String {
        """
        You are working inside Glint, a macOS screen-recording editor, on the project at \(project.path). \
        The person is chatting with you from a panel next to the video editor and sees your edits live. \
        Use the glint MCP tools and always pass this project path. Start with glint_project_info if you need the state. \
        For anything beyond a small tweak, create a proposal (glint_plan_zooms, glint_plan_cuts, glint_generate_captions \
        or glint_propose_edits) so the person can preview and apply it in Glint; apply directly only when they ask. \
        Check your work with glint_render_frame, glint_contact_sheet or glint_quality_report. \
        Recording, deleting, exporting over files and anything sent online return approval_required: tell the person \
        to approve it in Glint's banner, then retry with the approval_id. Keep replies short and concrete.
        """
    }

    /// - Parameters:
    ///   - helper: the `glint` CLI to attach as the MCP server (this app's copy).
    ///   - sessionID: resume this conversation when set.
    public init(agent: ChatAgent, cli: String, project: URL, prompt: String, sessionID: String?, helper: String = AgentSetup.helperPath(),
                onEvent: @escaping @Sendable (ChatEvent) -> Void) {
        self.agent = agent
        let env = ProcessInfo.processInfo.environment
        var serverEnv: [String: String] = [:]
        for k in ["GLINT_HOME", "GLINT_PROJECTS"] { if let v = env[k] { serverEnv[k] = v } }
        let context = Self.systemContext(project: project)

        process.executableURL = URL(fileURLWithPath: cli)
        process.currentDirectoryURL = project.deletingLastPathComponent()
        switch agent {
        case .claudeCode:
            var server: [String: Any] = ["type": "stdio", "command": helper, "args": ["mcp"]]
            if !serverEnv.isEmpty { server["env"] = serverEnv }
            let config = (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["glint": server]], options: [.withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                        "--strict-mcp-config", "--mcp-config", config,
                        "--allowedTools", "mcp__glint", "--tools", "",
                        "--append-system-prompt", context]
            if let sessionID { args += ["--resume", sessionID] }
            process.arguments = args
        case .codex:
            var overrides = ["mcp_servers.glint.command=\(CodexTOML.quote(helper))",
                             "mcp_servers.glint.args=[\"mcp\"]",
                             "mcp_servers.glint.enabled=true",
                             "mcp_servers.glint.startup_timeout_sec=\(AgentSetup.codexStartupTimeout)",
                             "mcp_servers.glint.tool_timeout_sec=\(AgentSetup.codexToolTimeout)",
                             "sandbox_mode=\"read-only\""]
            if !serverEnv.isEmpty {
                overrides.append("mcp_servers.glint.env={" + serverEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\(CodexTOML.quote($0.value))" }.joined(separator: ",") + "}")
            }
            var args = ["exec"]
            if let sessionID { args += ["resume", sessionID] }
            args += ["--json", "--skip-git-repo-check"]
            for o in overrides { args += ["-c", o] }
            // Codex has no system-prompt flag: the context leads the first message of a conversation.
            args.append(sessionID == nil ? "\(context)\n\nThe person says:\n\(prompt)" : prompt)
            process.arguments = args
        }
        var runEnv = env
        let dirs = [URL(fileURLWithPath: cli).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] + (LoginShell.path()?.split(separator: ":").map(String.init) ?? [])
        runEnv["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = runEnv
        self.onEvent = onEvent
    }

    private let onEvent: @Sendable (ChatEvent) -> Void

    public func start() throws {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let errBox = StderrTail()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBox.append(d) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Give the reader a moment to drain the last lines before deciding whether the turn ended cleanly.
            Thread.sleep(forTimeInterval: 0.2)
            let (cancelled, finished) = self.lock.withLock { (self.cancelled, self.sawFinish) }
            if cancelled { self.emit(.failure("Stopped.")); self.emit(.finished(ok: false)) }
            else if !finished {
                let tail = errBox.text.split(separator: "\n").suffix(3).joined(separator: " ")
                self.emit(.failure(p.terminationStatus == 0 ? "\(self.agent.title) ended without a reply." :
                    "\(self.agent.title) exited (status \(p.terminationStatus))\(tail.isEmpty ? "." : ": \(tail)")"))
                self.emit(.finished(ok: false))
            }
        }
        try process.run()
        let agent = agent
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            var toolNames: [String: String] = [:]
            let h = out.fileHandleForReading
            while let chunk = readAvailable(h) {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    let events = agent == .claudeCode ? ChatParser.claude(line, toolNames: &toolNames) : ChatParser.codex(line)
                    for e in events { self?.emit(e) }
                }
            }
        }
    }

    private func emit(_ e: ChatEvent) {
        if case .finished = e {
            let first = lock.withLock { () -> Bool in defer { sawFinish = true }; return !sawFinish }
            guard first else { return }
        }
        onEvent(e)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in if process.isRunning { process.terminate() } }
    }

    final class StderrTail: @unchecked Sendable {
        private var data = Data(); private let l = NSLock()
        func append(_ d: Data) { l.withLock { data.append(d); if data.count > 8000 { data = data.suffix(8000) } } }
        var text: String { l.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

// MARK: - Transcript

/// What the chat panel shows and saves with the project (`agent-chat.json`).
public struct ChatTranscript: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public enum Role: String, Codable, Sendable { case user, agent, tool, notice, error }
        public var id: String
        public var role: Role
        public var agent: ChatAgent?
        public var text: String
        public var tool: String?
        public var toolOutcome: ChatEvent.ToolOutcome?
        public var running: Bool
        public var date: Date
        public init(id: String = UUID().uuidString, role: Role, agent: ChatAgent? = nil, text: String, tool: String? = nil,
                    toolOutcome: ChatEvent.ToolOutcome? = nil, running: Bool = false, date: Date = Date()) {
            self.id = id; self.role = role; self.agent = agent; self.text = text; self.tool = tool
            self.toolOutcome = toolOutcome; self.running = running; self.date = date
        }
    }
    public var entries: [Entry] = []
    /// Per agent: the session to resume.
    public var sessions: [String: String] = [:]
    public init() {}

    public static func url(for bundle: ProjectBundle) -> URL { bundle.url.appendingPathComponent("agent-chat.json") }
    public static func load(_ bundle: ProjectBundle) -> ChatTranscript {
        (try? JSONCoding.decoder.decode(ChatTranscript.self, from: Data(contentsOf: url(for: bundle)))) ?? ChatTranscript()
    }
    public func save(_ bundle: ProjectBundle) {
        try? JSONCoding.encoder.encode(self).write(to: Self.url(for: bundle), options: .atomic)
    }
}

extension ChatEvent.ToolOutcome: Codable {}
