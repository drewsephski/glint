import Foundation
import GlintCore

/// Connects Glint's MCP server to the agents people use: Claude Code, Codex (CLI and app share one config) and
/// Claude Desktop. The app's Agents panel and `glint connect` both call this, so they always agree.
///
/// Claude Code is configured through its own CLI (`claude mcp add-json --scope user`): it owns `~/.claude.json`, which
/// running sessions rewrite. Codex and Claude Desktop read small config files that people edit by hand, so Glint edits
/// those directly, touching only its own entry and keeping a backup of the previous file.
public enum AgentClient: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude-code", codex, claudeDesktop = "claude-desktop"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .claudeDesktop: "Claude Desktop"
        }
    }
    /// What this entry covers, in one short phrase.
    public var scope: String {
        switch self {
        case .claudeCode: "Terminal, IDE and desktop sessions, every folder"
        case .codex: "Codex CLI, IDE extension, and the Codex and ChatGPT apps"
        case .claudeDesktop: "The Claude app's chat"
        }
    }
}

public struct AgentStatus: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled
        case notConnected
        case connected
        /// Glint is configured but points at a different copy of the CLI (moved, deleted, or a dev build).
        case otherCopy(String)
        /// Configured but switched off in the client's config.
        case disabled
        /// Points at this copy but won't start the server as an agent needs (wrong arguments or transport).
        case misconfigured(String)
        case error(String)
    }
    public var client: AgentClient
    public var state: State
    /// Where the configuration lives (file path or "claude mcp" scope).
    public var configLocation: String
    /// The command the client currently runs for Glint, if any.
    public var configuredCommand: String?
    /// Extra facts worth showing, e.g. per-folder entries that override the user entry.
    public var notes: [String] = []
    public var id: String { client.rawValue }
    public var isConnected: Bool { state == .connected }
}

public struct AgentSetupError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// The result of connecting or disconnecting one client.
public struct AgentChange: Sendable {
    public var client: AgentClient
    public var summary: String
    /// Something the person has to do for the change to take effect (e.g. restart the app).
    public var followUp: String?
}

public enum AgentSetup {
    public static let serverName = "glint"
    /// Long renders and autopilot runs outlast Codex's 60 s default tool timeout.
    public static let codexToolTimeout = 900
    public static let codexStartupTimeout = 30

    // MARK: Where the CLI lives

    /// The `glint` executable to put in agent configs. Inside the app that's the bundled helper; from the CLI it's the
    /// running executable with symlinks resolved, so a `~/.local/bin/glint` link never ends up in a config.
    public static func helperPath() -> String {
        let main = Bundle.main.bundleURL
        if main.pathExtension == "app" {
            return main.appendingPathComponent("Contents/Helpers/glint").resolvingSymlinksInPath().path
        }
        if let exe = Bundle.main.executableURL { return exe.resolvingSymlinksInPath().path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    /// The Glint.app that contains `helper`, if it is the bundled helper.
    public static func appBundle(containing helper: String) -> URL? {
        let u = URL(fileURLWithPath: helper)
        guard u.lastPathComponent == "glint", u.deletingLastPathComponent().lastPathComponent == "Helpers" else { return nil }
        let app = u.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    public enum Location: Sendable, Equatable {
        case installed          // /Applications or ~/Applications
        case development        // a source build (…/build/Glint.app) or `swift run`
        case diskImage          // running from the mounted DMG
        case translocated       // Gatekeeper's randomized read-only copy
        case other
    }

    public static func location(of helper: String = helperPath()) -> Location {
        if helper.contains("/AppTranslocation/") { return .translocated }
        if helper.hasPrefix("/Volumes/") { return .diskImage }
        let home = AgentSetup.home.path
        if helper.hasPrefix("/Applications/") || helper.hasPrefix(home + "/Applications/") { return .installed }
        if appBundle(containing: helper) == nil || helper.contains("/build/") || helper.contains("/.build/") { return .development }
        return .other
    }

    /// Why connecting from this copy would leave agents with a path that stops working, or nil when it's fine.
    public static func locationProblem(_ helper: String = helperPath()) -> String? {
        switch location(of: helper) {
        case .diskImage: "Glint is running from the disk image. Drag it to Applications, open it from there, then connect."
        case .translocated: "macOS is running Glint from a temporary copy. Move Glint to Applications, open it from there, then connect."
        default: nil
        }
    }

    // MARK: Status

    public static func status(_ client: AgentClient, helper: String = helperPath()) -> AgentStatus {
        switch client {
        case .claudeCode: return claudeCodeStatus(helper: helper)
        case .codex: return codexStatus(helper: helper)
        case .claudeDesktop: return claudeDesktopStatus(helper: helper)
        }
    }

    public static func statusAll(helper: String = helperPath()) -> [AgentStatus] {
        AgentClient.allCases.map { status($0, helper: helper) }
    }

    /// `args` nil means unknown (not checked); `transport` is the client's type field when it has one.
    static func classify(command: String?, args: [String]? = ["mcp"], transport: String? = nil, enabled: Bool = true, helper: String) -> AgentStatus.State {
        guard let command else { return .notConnected }
        if !enabled { return .disabled }
        let resolved = URL(fileURLWithPath: (command as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        guard resolved == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path else { return .otherCopy(command) }
        if let transport, transport != "stdio" { return .misconfigured("uses the \(transport) transport instead of stdio") }
        if args != ["mcp"] { return .misconfigured("runs glint \((args ?? []).joined(separator: " ")) instead of glint mcp") }
        return .connected
    }

    /// A configured command that certainly can't start: an absolute path to a missing file. Bare names (resolved
    /// on PATH by the client) and anything else uncertain count as working.
    static func certainlyMissing(_ command: String?) -> Bool {
        guard let c = command.map({ ($0 as NSString).expandingTildeInPath }), c.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: c)
    }

    // MARK: Connect / disconnect

    public static func connect(_ client: AgentClient, helper: String = helperPath()) throws -> AgentChange {
        if let problem = locationProblem(helper) { throw AgentSetupError(problem) }
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw AgentSetupError("The Glint CLI isn't at \(helper).") }
        switch client {
        case .claudeCode: return try connectClaudeCode(helper: helper)
        case .codex: return try connectCodex(helper: helper)
        case .claudeDesktop: return try connectClaudeDesktop(helper: helper)
        }
    }

    public static func disconnect(_ client: AgentClient) throws -> AgentChange {
        switch client {
        case .claudeCode:
            guard let claude = ClaudeCLI.find() else { throw AgentSetupError("Claude Code isn't installed.") }
            if claudeCodeEntries().user != nil {
                let r = try ClaudeCLI.run(claude, ["mcp", "remove", serverName, "--scope", "user"])
                if claudeCodeEntries().user != nil { throw AgentSetupError("claude mcp remove failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            }
            return AgentChange(client: client, summary: "Removed Glint from Claude Code.", followUp: "Running sessions keep it until they restart.")
        case .codex:
            let path = codexConfigURL
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return AgentChange(client: client, summary: "Codex had no Glint entry.") }
            let updated = try CodexTOML.remove(text)
            if updated != text {
                try checkCodexAccepts(updated, original: text)
                try writeKeepingBackup(updated, to: path)
            }
            return AgentChange(client: client, summary: "Removed Glint from \(display(path)).", followUp: "Start a new Codex session to drop it.")
        case .claudeDesktop:
            let path = claudeDesktopConfigURL
            guard FileManager.default.fileExists(atPath: path.path) else { return AgentChange(client: client, summary: "Claude Desktop had no Glint entry.") }
            let data = try Data(contentsOf: path)
            if let updated = try ClaudeDesktopJSON.remove(data) { try writeKeepingBackup(updated, to: path) }
            return AgentChange(client: client, summary: "Removed Glint from Claude Desktop.", followUp: "Quit and reopen Claude to apply.")
        }
    }

    /// The standard `mcpServers` JSON most MCP clients accept.
    public static func genericJSON(helper: String = helperPath()) -> String { OtherClient.generic.snippet(helper: helper) }

    /// What `connect` would write, for `--dry-run` and the manual-setup instructions.
    public static func manualInstructions(_ client: AgentClient, helper: String = helperPath()) -> String {
        switch client {
        case .claudeCode:
            return "claude mcp add-json --scope user glint '\(claudeCodeJSON(helper: helper))'"
        case .codex:
            return "Add to \(display(codexConfigURL)):\n\n" + CodexTOML.block(command: helper)
        case .claudeDesktop:
            return "Add under \"mcpServers\" in \(display(claudeDesktopConfigURL)):\n\n\"glint\": { \"command\": \"\(jsonEscape(helper))\", \"args\": [\"mcp\"] }"
        }
    }

    // MARK: Self-test

    /// Starts `helper mcp`, performs the MCP handshake and lists tools, the same way an agent will.
    /// Returns the number of tools, or throws with what went wrong (Gatekeeper, a missing file, a crash).
    public static func selfTest(helper: String = helperPath(), timeout: TimeInterval = 15) throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["mcp"]
        var env = ProcessInfo.processInfo.environment
        env["GLINT_CAPTURE"] = "local"          // the handshake never records; don't launch the app for it
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"glint-self-test","version":"1"},"capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        try stdin.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        let box = LineCollector()
        let reader = Thread {
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    box.append(Data(buffer[buffer.startIndex..<nl]))
                    buffer = Data(buffer[buffer.index(after: nl)...])
                }
                if box.has(id: 2) { break }
            }
            box.finish()
        }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while !box.isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try? stdin.fileHandleForWriting.close()
        guard let line = box.line(id: 2) else {
            throw AgentSetupError(p.isRunning ? "The Glint server didn't answer within \(Int(timeout)) s." : "The Glint server exited (status \(p.terminationStatus)) before answering.")
        }
        guard let tools = line["result"]?["tools"]?.arrayValue, !tools.isEmpty else { throw AgentSetupError("The Glint server answered without tools.") }
        return tools.count
    }

    final class LineCollector: @unchecked Sendable {
        private var lines: [JSONValue] = []
        private var done = false
        private let lock = NSLock()
        func append(_ d: Data) { if let v = try? JSONCoding.decoder.decode(JSONValue.self, from: d) { lock.withLock { lines.append(v) } } }
        func has(id: Int) -> Bool { line(id: id) != nil }
        func line(id: Int) -> JSONValue? { lock.withLock { lines.first { $0["id"]?.intValue == id } } }
        func finish() { lock.withLock { done = true } }
        var isFinished: Bool { lock.withLock { done } }
    }

    // MARK: Command-line tool on PATH

    public static var cliLinkURL: URL { AgentSetup.home.appendingPathComponent(".local/bin/glint") }

    public enum CLILinkState: Sendable, Equatable { case missing, linked, otherCopy(String), notALink }

    public static func cliLinkState(helper: String = helperPath()) -> CLILinkState {
        let fm = FileManager.default
        let link = cliLinkURL.path
        guard let attrs = try? fm.attributesOfItem(atPath: link) else { return .missing }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return .notALink }
        let dest = (try? fm.destinationOfSymbolicLink(atPath: link)) ?? ""
        return URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path ? .linked : .otherCopy(dest)
    }

    /// Links `~/.local/bin/glint` to this copy's CLI. Replaces an older link, never a real file.
    @discardableResult
    public static func installCLILink(helper: String = helperPath()) throws -> String {
        if let problem = locationProblem(helper) { throw AgentSetupError(problem) }
        let fm = FileManager.default
        let link = cliLinkURL
        if cliLinkState(helper: helper) == .notALink { throw AgentSetupError("\(display(link)) exists and isn't a link. Remove it first.") }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: helper)
        return link.path
    }

    public static func removeCLILink() throws {
        if case .notALink = cliLinkState() { throw AgentSetupError("\(display(cliLinkURL)) isn't a link Glint made.") }
        try? FileManager.default.removeItem(at: cliLinkURL)
    }

    /// Whether `~/.local/bin` is on the PATH of the person's login shell (what new terminals get).
    public static func cliLinkDirectoryOnPath() -> Bool {
        let dir = cliLinkURL.deletingLastPathComponent().path
        let path = LoginShell.path() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { String($0) == dir || String($0) == "~/.local/bin" }
    }

    // MARK: Files

    /// `$HOME`, like the agents themselves use, so a test or sandboxed HOME sees the same files they do.
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], h.hasPrefix("/") { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func display(_ u: URL) -> String {
        let h = home.path
        return u.path.hasPrefix(h + "/") ? "~" + u.path.dropFirst(h.count) : u.path
    }

    /// Writes atomically, keeps the previous file next to it as `<name>.glint-backup`, and keeps its permissions.
    static func writeKeepingBackup(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var perms: Any?
        if fm.fileExists(atPath: url.path) {
            perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
            let backup = url.appendingPathExtension("glint-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    static func writeKeepingBackup(_ text: String, to url: URL) throws { try writeKeepingBackup(Data(text.utf8), to: url) }

    static func jsonEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

// MARK: - Other MCP clients

/// Clients Glint doesn't configure itself, each with its own config shape and where it goes.
public enum OtherClient: String, CaseIterable, Sendable, Identifiable {
    case cursor, vscode, windsurf, zed, generic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .generic: "Other (mcpServers JSON)"
        }
    }
    /// Where to paste the snippet, in a sentence.
    public var destination: String {
        switch self {
        case .cursor: "Paste into ~/.cursor/mcp.json (merge with any servers already there)."
        case .vscode: "Run \"MCP: Open User Configuration\" in VS Code and merge this into mcp.json."
        case .windsurf: "Paste into ~/.codeium/windsurf/mcp_config.json (merge with any servers already there)."
        case .zed: "Merge into Zed's settings.json (Zed › Settings › Open Settings File)."
        case .generic: "Paste into your client's MCP config. Most clients use this mcpServers shape."
        }
    }

    public func snippet(helper: String) -> String {
        let server: [String: Any]
        let root: [String: Any]
        switch self {
        case .vscode:
            server = ["type": "stdio", "command": helper, "args": ["mcp"]]
            root = ["servers": [AgentSetup.serverName: server]]
        case .zed:
            server = ["command": helper, "args": ["mcp"], "env": [String: String]()]
            root = ["context_servers": [AgentSetup.serverName: server]]
        case .cursor, .windsurf, .generic:
            server = ["command": helper, "args": ["mcp"]]
            root = ["mcpServers": [AgentSetup.serverName: server]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Claude Code

extension AgentSetup {
    /// `$CLAUDE_CONFIG_DIR/.claude.json` when set, else `~/.claude.json`. Read only; writes go through the CLI.
    static var claudeCodeConfigURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        return home.appendingPathComponent(".claude.json")
    }

    static func claudeCodeJSON(helper: String) -> String {
        #"{"type":"stdio","command":"\#(jsonEscape(helper))","args":["mcp"]}"#
    }

    /// Glint entries Claude Code knows about: the user-scope one plus per-folder ("local") ones, which win in their folder.
    static func claudeCodeEntries() -> (user: [String: Any]?, local: [(folder: String, entry: [String: Any])]) {
        guard let data = try? Data(contentsOf: claudeCodeConfigURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, []) }
        let user = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
        var local: [(String, [String: Any])] = []
        for (folder, value) in (root["projects"] as? [String: Any]) ?? [:] {
            if let e = ((value as? [String: Any])?["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] { local.append((folder, e)) }
        }
        return (user, local.sorted { $0.0 < $1.0 })
    }

    static func claudeCodeStatus(helper: String) -> AgentStatus {
        var s = AgentStatus(client: .claudeCode, state: .notInstalled, configLocation: "claude mcp (user scope)")
        guard ClaudeCLI.find() != nil else { return s }
        let (user, local) = claudeCodeEntries()
        s.configuredCommand = user?["command"] as? String
        s.state = classify(command: s.configuredCommand, args: user?["args"] as? [String] ?? [], transport: (user?["type"] as? String) ?? "stdio", helper: helper)
        let broken = local.filter { certainlyMissing($0.entry["command"] as? String) }
        if !broken.isEmpty { s.notes.append("\(broken.count) folder-only \(broken.count == 1 ? "entry points" : "entries point") at a missing Glint. Connect removes \(broken.count == 1 ? "it" : "them").") }
        let others = local.count - broken.count
        if others > 0 { s.notes.append("\(others) folder-only \(others == 1 ? "entry overrides" : "entries override") this in \(others == 1 ? "its folder" : "their folders").") }
        return s
    }

    static func connectClaudeCode(helper: String) throws -> AgentChange {
        guard let claude = ClaudeCLI.find() else {
            throw AgentSetupError("Claude Code isn't installed. Install it from claude.com/claude-code, then connect again.")
        }
        // `add-json` refuses an existing name, so remove first, and put the previous entry back if adding fails.
        let previous = claudeCodeEntries().user
        if previous != nil { _ = try? ClaudeCLI.run(claude, ["mcp", "remove", serverName, "--scope", "user"]) }
        let r = try ClaudeCLI.run(claude, ["mcp", "add-json", "--scope", "user", serverName, claudeCodeJSON(helper: helper)])
        guard r.status == 0 else {
            if let previous, let data = try? JSONSerialization.data(withJSONObject: previous) {
                _ = try? ClaudeCLI.run(claude, ["mcp", "add-json", "--scope", "user", serverName, String(decoding: data, as: UTF8.self)])
            }
            throw AgentSetupError("claude mcp add-json failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Folder-only entries left by older instructions shadow the user entry; drop only the ones that point at a
        // file that no longer exists. Anything that might still work (a bare `glint`, custom env) stays.
        var removed = 0
        for (folder, entry) in claudeCodeEntries().local where certainlyMissing(entry["command"] as? String) {
            if FileManager.default.fileExists(atPath: folder),
               (try? ClaudeCLI.run(claude, ["mcp", "remove", serverName, "--scope", "local"], cwd: folder))?.status == 0 { removed += 1 }
        }
        let after = claudeCodeStatus(helper: helper)
        guard after.state == .connected else { throw AgentSetupError("Claude Code didn't keep the Glint entry (\(after.state)).") }
        return AgentChange(client: .claudeCode,
                           summary: "Connected Claude Code for every folder\(removed > 0 ? "; removed \(removed) broken folder entr\(removed == 1 ? "y" : "ies")" : "").",
                           followUp: "New sessions load it. In a running session, type /mcp to reconnect.")
    }
}

/// Finds and runs the `claude` CLI. A Finder-launched app has a minimal PATH, so look where the installers put it,
/// then ask the login shell.
enum ClaudeCLI {
    nonisolated(unsafe) private static var cached: String??
    private static let lock = NSLock()

    static func find() -> String? {
        if let override = ProcessInfo.processInfo.environment["GLINT_CLAUDE_CLI"] { return override.isEmpty ? nil : override }
        if let override = ProcessInfo.processInfo.environment["GLINT_CLAUDE_CLI"] {
            return override.isEmpty ? nil : override
        }
        // Only a hit is cached: someone may install Claude Code while Glint is open.
        if let c = lock.withLock({ cached }), let c, FileManager.default.isExecutableFile(atPath: c) { return c }
        let found = search()
        if found != nil { lock.withLock { cached = .some(found) } }
        return found
    }

    private static func search() -> String? {
        let fm = FileManager.default
        let h = AgentSetup.home.path
        var candidates = ["\(h)/.local/bin/claude", "\(h)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(h)/.npm-global/bin/claude", "\(h)/.bun/bin/claude", "\(h)/.volta/bin/claude", "\(h)/.yarn/bin/claude"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        if let c = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return c }
        if let p = LoginShell.which("claude"), fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    struct Result { var status: Int32; var output: String }

    static func run(_ claude: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:], timeout: TimeInterval = 45) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        // npm installs are `#!/usr/bin/env node` scripts: give them the directories node usually lives in.
        let dirs = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] + (LoginShell.path()?.split(separator: ":").map(String.init) ?? [])
        env["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env.merge(extra) { $1 }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        try p.run()
        guard let data = collect(out, process: p, timeout: timeout) else {
            throw AgentSetupError("`\(URL(fileURLWithPath: claude).lastPathComponent) \(args.prefix(2).joined(separator: " "))` timed out.")
        }
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Reads a child's output until it exits, within `timeout`. A grandchild that inherits the pipe (a daemon
    /// started by an rc file) can't hold this open: once the child exits, a short grace period is all it gets.
    static func collect(_ pipe: Pipe, process p: Process, timeout: TimeInterval) -> Data? {
        let box = ResultBox()
        Thread { box.set(pipe.fileHandleForReading.readDataToEndOfFile()) }.start()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return nil }
        let grace = Date().addingTimeInterval(1)
        while !box.isSet && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
        return box.isSet ? box.value : nil
    }

    final class ResultBox: @unchecked Sendable {
        private var d: Data?; private let l = NSLock()
        func set(_ v: Data) { l.withLock { d = v } }
        var isSet: Bool { l.withLock { d != nil } }
        var value: Data { l.withLock { d ?? Data() } }
    }
}

/// The person's shell as their terminal sets it up, for finding tools and PATH. Version managers (nvm, asdf, mise,
/// fnm) usually live in `~/.zshrc`, which only interactive shells read, so ask an interactive login shell first and a
/// plain login shell if that fails. Output is fenced with a marker because rc files may print banners. Results are
/// cached briefly; every run is bounded so a slow or prompting rc file can't hang the app.
enum LoginShell {
    nonisolated(unsafe) private static var cachedPath: (value: String?, at: Date)?
    private static let lock = NSLock()
    static let marker = "__GLINT_SHELL__"

    static func path() -> String? {
        if let c = lock.withLock({ cachedPath }), Date().timeIntervalSince(c.at) < 60 { return c.value }
        let p = query("printf '\\n\(marker)%s\\n' \"$PATH\"")
        lock.withLock { cachedPath = (p, Date()) }
        return p
    }

    static func which(_ tool: String) -> String? {
        guard tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return query("printf '\\n\(marker)%s\\n' \"$(command -v \(tool))\"").flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    private static func query(_ script: String) -> String? {
        run(script, flags: ["-i", "-l", "-c"]) ?? run(script, flags: ["-l", "-c"])
    }

    private static func run(_ script: String, flags: [String], timeout: TimeInterval = 5) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + [script]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        guard let data = ClaudeCLI.collect(out, process: p, timeout: timeout) else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix(marker) }
        let value = line.map { String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
        return (value?.isEmpty ?? true) ? nil : value
    }
}

// MARK: - Codex

extension AgentSetup {
    /// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`. The CLI, the IDE extension and the app all read it.
    static var codexConfigURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("config.toml")
        }
        return home.appendingPathComponent(".codex/config.toml")
    }

    /// Apps that bundle Codex and read `~/.codex/config.toml`: the Codex app and the ChatGPT desktop app.
    static var codexAppBundles: [String] {
        let h = home.path
        return ["/Applications/Codex.app", "\(h)/Applications/Codex.app", "/Applications/ChatGPT.app", "\(h)/Applications/ChatGPT.app"]
    }

    static func codexInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: codexConfigURL.deletingLastPathComponent().path) { return true }
        if CodexCLI.bundledCLIs().contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        if fm.fileExists(atPath: "/Applications/Codex.app") || fm.fileExists(atPath: home.appendingPathComponent("Applications/Codex.app").path) { return true }
        return CodexCLI.find() != nil
    }

    static func codexStatus(helper: String) -> AgentStatus {
        var s = AgentStatus(client: .codex, state: .notInstalled, configLocation: display(codexConfigURL))
        guard codexInstalled() else { return s }
        let text = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        do {
            let entry = try CodexTOML.entry(in: text)
            s.configuredCommand = entry?.command
            s.state = classify(command: entry?.command, args: entry?.args ?? [], enabled: entry?.enabled ?? true, helper: helper)
            if let t = entry?.toolTimeout, t < 300, s.state == .connected { s.notes.append("Tool timeout is \(t) s; long renders may be cut off. Connect sets \(codexToolTimeout) s.") }
        } catch {
            s.state = .error("\(error)")
        }
        return s
    }

    /// Refuses an edit the installed Codex can't read, unless Codex couldn't read the file before either.
    static func checkCodexAccepts(_ updated: String, original: String) throws {
        guard let problem = CodexCLI.rejection(of: updated) else { return }
        if !original.isEmpty, CodexCLI.rejection(of: original) != nil { return }
        throw AgentSetupError("Codex wouldn't accept the edited config, so nothing was changed. Codex said: \(problem)")
    }

    static func connectCodex(helper: String) throws -> AgentChange {
        let path = codexConfigURL
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let updated = try CodexTOML.upsert(text, command: helper)
        if updated != text {
            try checkCodexAccepts(updated, original: text)
            try writeKeepingBackup(updated, to: path)
        }
        guard case .connected = codexStatus(helper: helper).state else { throw AgentSetupError("Codex's config didn't keep the Glint entry.") }
        return AgentChange(client: .codex, summary: "Connected Codex (\(display(path))).", followUp: "Start a new Codex session or restart the Codex app to load it.")
    }
}

/// Edits the `[mcp_servers.glint]` table of a Codex `config.toml` without disturbing anything else.
///
/// A small TOML lexer splits the file into statements (headers, key/value pairs that may span lines, comments and
/// blank lines) while tracking strings, comments and brackets, so a `#`, `[` or `"""` inside a string or comment never
/// looks like structure. Edits remove or insert whole statements inside Glint's own table; every byte outside it is
/// kept. Layouts it can't edit safely (inline tables, dotted keys, arrays of tables) are refused, not guessed at.
public enum CodexTOML {
    public struct Entry: Equatable, Sendable {
        public var command: String?
        public var args: [String]?
        public var enabled: Bool
        public var toolTimeout: Int?
    }

    static let ownedKeys: Set<String> = ["command", "args", "startup_timeout_sec", "tool_timeout_sec", "enabled"]

    public static func block(command: String, newline: String = "\n") -> String {
        ["[mcp_servers.glint]",
         "command = \(quote(command))",
         "args = [\"mcp\"]",
         "startup_timeout_sec = \(AgentSetup.codexStartupTimeout)",
         "tool_timeout_sec = \(AgentSetup.codexToolTimeout)", ""].joined(separator: newline)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 || ch.value == 0x7F { out += String(format: "\\u%04X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    // MARK: Lexing

    struct Statement {
        enum Kind: Equatable {
            case trivia
            case header(path: [String], isArray: Bool)
            case keyValue(key: [String], value: String)
        }
        var lines: Range<Int>
        var kind: Kind
    }

    struct Document {
        var lines: [String]            // split on "\n"; a trailing "\r" stays on its line
        var statements: [Statement]
        var newline: String
    }

    static func lex(_ text: String) throws -> Document {
        let lines = text.components(separatedBy: "\n")
        var statements: [Statement] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
            if t.isEmpty || t.hasPrefix("#") {
                statements.append(Statement(lines: i..<(i + 1), kind: .trivia)); i += 1; continue
            }
            if t.hasPrefix("[") {
                let isArray = t.hasPrefix("[[")
                let inner = t.dropFirst(isArray ? 2 : 1)
                guard let path = try? parseKey(inner, terminator: "]") else { throw AgentSetupError("Can't read the table header on line \(i + 1).") }
                statements.append(Statement(lines: i..<(i + 1), kind: .header(path: path.key, isArray: isArray))); i += 1; continue
            }
            // key = value, possibly spanning lines (arrays, inline tables, multi-line strings).
            let start = i
            let joinedFirst = Substring(lines[i])
            guard let (key, rest) = try? parseKey(joinedFirst, terminator: "=") else { throw AgentSetupError("Can't read line \(i + 1).") }
            var value = String(rest)
            var scanner = ValueScanner()
            scanner.feed(String(rest))
            while !scanner.isComplete && i + 1 < lines.count {
                i += 1
                value += "\n" + lines[i]
                scanner.feed("\n" + lines[i])
            }
            guard scanner.isComplete else { throw AgentSetupError("A value starting on line \(start + 1) never ends.") }
            statements.append(Statement(lines: start..<(i + 1), kind: .keyValue(key: key, value: value)))
            i += 1
        }
        return Document(lines: lines, statements: statements, newline: text.contains("\r\n") ? "\r\n" : "\n")
    }

    /// Tracks strings, comments and bracket depth through a value; complete at a line end outside all of them.
    struct ValueScanner {
        enum State { case normal, basic, literal, mlBasic, mlLiteral, comment }
        var state = State.normal
        var depth = 0
        var isComplete = false
        var escaped = false

        mutating func feed(_ s: String) {
            let chars = Array(s)
            var k = 0
            func at(_ n: Int) -> Character? { n < chars.count ? chars[n] : nil }
            func triple(_ q: Character) -> Bool { at(k) == q && at(k + 1) == q && at(k + 2) == q }
            isComplete = false
            while k < chars.count {
                let c = chars[k]
                switch state {
                case .comment:
                    if c == "\n" { state = .normal; continue }
                case .basic:
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" || c == "\n" { state = .normal }
                case .literal:
                    if c == "'" || c == "\n" { state = .normal }
                case .mlBasic:
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if triple("\"") {
                        k += 3; while at(k) == "\"" { k += 1 }; state = .normal; continue
                    }
                case .mlLiteral:
                    if triple("'") { k += 3; while at(k) == "'" { k += 1 }; state = .normal; continue }
                case .normal:
                    if c == "\n" { if depth <= 0 { isComplete = true; return } }
                    else if c == "#" { state = .comment }
                    else if triple("\"") { state = .mlBasic; k += 3; continue }
                    else if triple("'") { state = .mlLiteral; k += 3; continue }
                    else if c == "\"" { state = .basic }
                    else if c == "'" { state = .literal }
                    else if c == "[" || c == "{" { depth += 1 }
                    else if c == "]" || c == "}" { depth -= 1 }
                }
                k += 1
            }
            // End of the text so far: complete if nothing is open (the next line starts a new statement).
            isComplete = (state == .normal || state == .comment) && depth <= 0
            if state == .comment { state = .normal }
        }
    }

    /// Parses a dotted key up to `terminator` (outside quotes). Returns the parts and the text after the terminator.
    static func parseKey(_ s: Substring, terminator: Character) throws -> (key: [String], rest: Substring) {
        var parts: [String] = []
        var bare = ""
        var quoted: String?
        func finishPart() throws {
            let t = bare.trimmingCharacters(in: .whitespaces)
            if let q = quoted {
                guard t.isEmpty else { throw AgentSetupError("bad key") }
                parts.append(q)
            } else {
                guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw AgentSetupError("bad key") }
                parts.append(t)
            }
            bare = ""; quoted = nil
        }
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" || c == "'" {
                guard quoted == nil, bare.trimmingCharacters(in: .whitespaces).isEmpty else { throw AgentSetupError("bad key") }
                var j = s.index(after: i)
                var raw = ""
                var esc = false
                while j < s.endIndex {
                    let d = s[j]
                    if c == "\"" && esc { raw.append("\\"); raw.append(d); esc = false }
                    else if c == "\"" && d == "\\" { esc = true }
                    else if d == c { break }
                    else { raw.append(d) }
                    j = s.index(after: j)
                }
                guard j < s.endIndex else { throw AgentSetupError("unterminated key") }
                quoted = c == "\"" ? try unescape(raw) : raw
                bare = ""
                i = s.index(after: j)
                continue
            }
            if c == "." { try finishPart() }
            else if c == terminator { try finishPart(); return (parts, s[s.index(after: i)...]) }
            else { bare.append(c) }
            i = s.index(after: i)
        }
        throw AgentSetupError("no \(terminator)")
    }

    static func unescape(_ raw: String) throws -> String {
        var out = ""
        var it = Array(raw)
        var k = 0
        while k < it.count {
            let c = it[k]
            guard c == "\\", k + 1 < it.count else { out.append(c); k += 1; continue }
            let e = it[k + 1]
            k += 2
            switch e {
            case "b": out.append("\u{08}")
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "f": out.append("\u{0C}")
            case "r": out.append("\r")
            case "e": out.append("\u{1B}")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u", "U":
                let n = e == "u" ? 4 : 8
                guard k + n <= it.count, let v = UInt32(String(it[k..<(k + n)]), radix: 16), let sc = Unicode.Scalar(v) else { throw AgentSetupError("bad escape") }
                out.unicodeScalars.append(sc)
                k += n
            default: throw AgentSetupError("bad escape")
            }
        }
        it.removeAll()
        return out
    }

    /// The first string in a value (basic, literal or multi-line), ignoring a trailing comment.
    static func parseString(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, isBasic) in [("\"\"\"", true), ("'''", false), ("\"", true), ("'", false)] where v.hasPrefix(open) {
            var body = v.dropFirst(open.count)
            if open.count == 3, body.hasPrefix("\n") { body = body.dropFirst() } else if open.count == 3, body.hasPrefix("\r\n") { body = body.dropFirst(2) }
            var raw = ""
            var esc = false
            var idx = body.startIndex
            while idx < body.endIndex {
                if !esc && body[idx...].hasPrefix(open) { return isBasic ? (try? unescape(raw)) : raw }
                let ch = body[idx]
                if isBasic && !esc && ch == "\\" { esc = true; raw.append(ch) } else { esc = false; raw.append(ch) }
                idx = body.index(after: idx)
            }
            return nil
        }
        return nil
    }

    /// An array of strings, e.g. `["mcp"]` or one spread over lines with comments. nil if it isn't one.
    static func parseStringArray(_ value: String) -> [String]? {
        var v = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard v.hasPrefix("[") else { return nil }
        v = v.dropFirst()
        var out: [String] = []
        while true {
            v = v.drop { $0.isWhitespace || $0 == "," }
            if v.hasPrefix("#") { v = v.drop { $0 != "\n" }; continue }
            if v.hasPrefix("]") { return out }
            guard let first = v.first, first == "\"" || first == "'" else { return nil }
            guard let s = parseString(String(v)) else { return nil }
            out.append(s)
            // Skip past the string we just read.
            var i = v.index(after: v.startIndex)
            var esc = false
            while i < v.endIndex {
                let ch = v[i]
                if first == "\"" && !esc && ch == "\\" { esc = true } else { if ch == first && !esc { break }; esc = false }
                i = v.index(after: i)
            }
            guard i < v.endIndex else { return nil }
            v = v[v.index(after: i)...]
        }
    }

    // MARK: Structure

    static func isGlint(_ path: [String]) -> Bool { path.count >= 2 && path[0] == "mcp_servers" && path[1] == AgentSetup.serverName }

    /// Statement index range of each table that is Glint's (`[mcp_servers.glint]` and its subtables).
    static func glintTables(_ doc: Document) -> (main: Range<Int>?, all: [Range<Int>]) {
        var main: Range<Int>?
        var all: [Range<Int>] = []
        var i = 0
        while i < doc.statements.count {
            if case .header(let path, false) = doc.statements[i].kind, isGlint(path) {
                var j = i + 1
                while j < doc.statements.count { if case .header = doc.statements[j].kind { break }; j += 1 }
                all.append(i..<j)
                if path.count == 2 && main == nil { main = i..<j }
                i = j
            } else { i += 1 }
        }
        return (main, all)
    }

    /// Glint configured some other way (inline table, dotted key, array of tables), or an inline `mcp_servers = {…}`
    /// that a new `[mcp_servers.glint]` table can't be added next to.
    static func unsupportedForm(_ doc: Document) -> String? {
        var table: [String] = []
        for s in doc.statements {
            switch s.kind {
            case .trivia: continue
            case .header(let path, let isArray):
                if isArray && isGlint(path) { return "an array of tables" }
                table = path
            case .keyValue(let key, _):
                let full = table + key
                if full == ["mcp_servers"] { return "an inline mcp_servers table" }
                if isGlint(full) && !isGlint(table) { return "an inline table or dotted keys" }
            }
        }
        return nil
    }

    static func text(_ doc: Document, _ s: Statement) -> String { doc.lines[s.lines].joined(separator: "\n") }

    // MARK: Read / edit

    public static func entry(in text: String) throws -> Entry? {
        let doc = try lex(text)
        if let form = unsupportedForm(doc), glintTables(doc).main == nil {
            if form != "an inline mcp_servers table" || text.contains(AgentSetup.serverName) { return Entry(command: nil, args: nil, enabled: true, toolTimeout: nil) }
        }
        guard let r = glintTables(doc).main else { return nil }
        var e = Entry(command: nil, args: nil, enabled: true, toolTimeout: nil)
        for s in doc.statements[r] {
            guard case .keyValue(let key, let value) = s.kind, key.count == 1 else { continue }
            switch key[0] {
            case "command": e.command = parseString(value)
            case "args": e.args = parseStringArray(value)
            case "enabled": e.enabled = !value.trimmingCharacters(in: .whitespaces).hasPrefix("false")
            case "tool_timeout_sec": e.toolTimeout = Int(value.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
            default: break
            }
        }
        return e
    }

    /// Adds or updates Glint's table. Keeps keys a person added (env, cwd…) and every subtable; replaces the keys Glint owns.
    public static func upsert(_ text: String, command: String) throws -> String {
        let doc = try lex(text)
        let tables = glintTables(doc)
        if let form = unsupportedForm(doc) {
            throw AgentSetupError("\(AgentSetup.display(AgentSetup.codexConfigURL)) uses \(form) for MCP servers, which Glint won't rewrite. Add this yourself:\n\n\(block(command: command))")
        }
        let fresh = block(command: command, newline: "\n").components(separatedBy: "\n").filter { !$0.isEmpty }
            .map { doc.newline == "\r\n" ? $0 + "\r" : $0 }
        guard let r = tables.main else {
            var out = text
            if !out.isEmpty && !out.hasSuffix("\n") { out += doc.newline }
            let lastLine = out.components(separatedBy: "\n").dropLast().last ?? ""
            if !out.isEmpty && !lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += doc.newline }
            return out + block(command: command, newline: doc.newline)
        }
        // Rebuild only the lines of Glint's main table.
        let header = doc.statements[r.lowerBound]
        var body: [String] = []
        for s in doc.statements[r].dropFirst() {
            if case .keyValue(let key, _) = s.kind, key.count == 1, ownedKeys.contains(key[0]) { continue }
            body.append(contentsOf: doc.lines[s.lines])
        }
        let first = header.lines.lowerBound
        let last = doc.statements[r.upperBound - 1].lines.upperBound
        var lines = doc.lines
        lines.replaceSubrange(first..<last, with: fresh + body)
        return lines.joined(separator: "\n")
    }

    /// Removes Glint's table and subtables (e.g. `[mcp_servers.glint.env]`); every other byte stays as it was.
    public static func remove(_ text: String) throws -> String {
        let doc = try lex(text)
        let tables = glintTables(doc)
        if tables.all.isEmpty {
            if unsupportedForm(doc) != nil && text.contains(AgentSetup.serverName) {
                throw AgentSetupError("\(AgentSetup.display(AgentSetup.codexConfigURL)) defines glint in a form Glint won't rewrite; remove it by hand.")
            }
            return text
        }
        var drop = IndexSet()
        for r in tables.all {
            let first = doc.statements[r.lowerBound].lines.lowerBound
            let last = doc.statements[r.upperBound - 1].lines.upperBound
            drop.insert(integersIn: first..<last)
        }
        var lines = doc.lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        // The table ran to the end of the file: drop the blank separator lines before it and end with one newline,
        // the way the file ended before Glint appended its table.
        if drop.contains(doc.lines.count - 1) {
            while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
            if lines.isEmpty { return "" }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// Asks the installed Codex CLI to read a config, so Glint never leaves Codex with a file it rejects.
enum CodexCLI {
    static func find() -> String? {
        if let o = ProcessInfo.processInfo.environment["GLINT_CODEX_CLI"] { return o.isEmpty ? nil : o }
        let h = AgentSetup.home.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(h)/.local/bin/codex", "\(h)/.npm-global/bin/codex", "\(h)/.bun/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        if let c = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        if let c = LoginShell.which("codex") { return c }
        return bundledCLIs().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `codex` executables shipped inside the Codex and ChatGPT apps.
    static func bundledCLIs() -> [String] {
        AgentSetup.codexAppBundles.flatMap { app in
            ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex", "Contents/MacOS/codex"].map { "\(app)/\($0)" }
        }
    }

    /// nil when Codex reads `text` (or no Codex CLI is installed to ask); otherwise Codex's complaint.
    static func rejection(of text: String) -> String? {
        guard let codex = find() else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-codex-check-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            let r = try ClaudeCLI.run(codex, ["mcp", "list", "--json"], env: ["CODEX_HOME": dir.path], timeout: 20)
            return r.status == 0 ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }
}

// MARK: - Claude Desktop

extension AgentSetup {
    static var claudeDesktopConfigURL: URL {
        if let o = ProcessInfo.processInfo.environment["GLINT_CLAUDE_DESKTOP_CONFIG"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static func claudeDesktopInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Claude.app") || fm.fileExists(atPath: home.appendingPathComponent("Applications/Claude.app").path)
            || fm.fileExists(atPath: claudeDesktopConfigURL.path)
    }

    static func claudeDesktopStatus(helper: String) -> AgentStatus {
        var s = AgentStatus(client: .claudeDesktop, state: .notInstalled, configLocation: display(claudeDesktopConfigURL))
        guard claudeDesktopInstalled() else { return s }
        guard let data = try? Data(contentsOf: claudeDesktopConfigURL) else { s.state = .notConnected; return s }
        do {
            let e = try ClaudeDesktopJSON.entry(in: data)
            s.configuredCommand = e?["command"] as? String
            s.state = classify(command: s.configuredCommand, args: e?["args"] as? [String] ?? [], helper: helper)
        } catch { s.state = .error("\(error)") }
        return s
    }

    static func connectClaudeDesktop(helper: String) throws -> AgentChange {
        let path = claudeDesktopConfigURL
        let data = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
        try writeKeepingBackup(try ClaudeDesktopJSON.upsert(data, command: helper), to: path)
        return AgentChange(client: .claudeDesktop, summary: "Connected Claude Desktop.", followUp: "Quit and reopen Claude to load Glint.")
    }
}

/// Edits `mcpServers.glint` in Claude Desktop's JSON config, keeping every other key.
public enum ClaudeDesktopJSON {
    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentSetupError("\(AgentSetup.display(AgentSetup.claudeDesktopConfigURL)) isn't valid JSON. Fix or remove it, then connect again.")
        }
        return root
    }

    static func serialize(_ root: [String: Any]) throws -> Data {
        var d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    public static func command(in data: Data) throws -> String? { try entry(in: data)?["command"] as? String }

    static func entry(in data: Data) throws -> [String: Any]? {
        (try parse(data)["mcpServers"] as? [String: Any])?[AgentSetup.serverName] as? [String: Any]
    }

    public static func upsert(_ data: Data?, command: String) throws -> Data {
        var root = try parse(data)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var entry = servers[AgentSetup.serverName] as? [String: Any] ?? [:]
        entry["command"] = command
        entry["args"] = ["mcp"]
        servers[AgentSetup.serverName] = entry
        root["mcpServers"] = servers
        return try serialize(root)
    }

    /// nil when there was nothing to remove.
    public static func remove(_ data: Data) throws -> Data? {
        var root = try parse(data)
        guard var servers = root["mcpServers"] as? [String: Any], servers[AgentSetup.serverName] != nil else { return nil }
        servers.removeValue(forKey: AgentSetup.serverName)
        root["mcpServers"] = servers
        return try serialize(root)
    }
}
