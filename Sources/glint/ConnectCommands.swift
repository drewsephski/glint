import Foundation
import ArgumentParser
import GlintAgent

extension AgentClient: ExpressibleByArgument {
    public init?(argument: String) {
        let a = argument.lowercased()
        switch a {
        case "claude", "claude-code", "claudecode", "cc": self = .claudeCode
        case "codex", "chatgpt", "openai": self = .codex
        case "claude-desktop", "desktop", "claude-app": self = .claudeDesktop
        default: return nil
        }
    }
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect Glint to your agents: Claude Code, Codex and Claude Desktop.",
        discussion: """
        With no client named, connects every one that's installed. Claude Code is set up for every folder \
        (`claude mcp add-json --scope user`); Codex gets an entry in ~/.codex/config.toml with a 15-minute tool \
        timeout for long renders; Claude Desktop gets one in claude_desktop_config.json. Glint changes only its own \
        entry and keeps a .glint-backup of any file it edits. Run it again after moving Glint.app.

        Examples:
          glint connect                 connect everything installed
          glint connect codex           just Codex
          glint connect --status        what's connected
          glint connect --remove        disconnect
          glint connect --print         show the config to paste into other clients
        """)

    @Argument(help: "claude-code | codex | claude-desktop (default: all installed)") var clients: [AgentClient] = []
    @Flag(help: "Show what's connected; change nothing.") var status = false
    @Flag(help: "Remove Glint from the named (or all) clients.") var remove = false
    @Flag(name: .customLong("dry-run"), help: "Print what would change; change nothing.") var dryRun = false
    @Flag(name: .customLong("print"), help: "Print manual setup for each client and for any other MCP client.") var printConfig = false
    @Flag(name: .customLong("no-check"), help: "Skip starting the server to check it answers.") var noCheck = false

    func run() throws {
        let helper = AgentSetup.helperPath()
        if printConfig { return printManual(helper) }
        let statuses = AgentSetup.statusAll(helper: helper)
        if status { return report(statuses, helper: helper) }

        let named = !clients.isEmpty
        let targets: [AgentClient] = named ? clients : statuses.filter { remove ? $0.configuredCommand != nil : $0.state != .notInstalled }.map(\.client)
        if targets.isEmpty {
            print(remove ? "Glint isn't connected to any agent." : "No supported agent found. Install Claude Code or Codex, or run `glint connect --print` for other MCP clients.")
            return
        }
        if !remove, let problem = AgentSetup.locationProblem(helper) { throw ValidationError(problem) }

        if dryRun {
            for c in targets {
                print("\(c.title):")
                print(remove ? "  remove the glint entry (\(AgentSetup.status(c, helper: helper).configLocation))" : indent(AgentSetup.manualInstructions(c, helper: helper)))
                print("")
            }
            return
        }

        // Check the server starts before changing any config, so a broken copy never gets connected.
        if !remove && !noCheck {
            do { print("✓ The Glint server answers (\(try AgentSetup.selfTest(helper: helper)) tools).") }
            catch { print("✗ Nothing was changed: the Glint server didn't start: \(error)"); throw ExitCode(1) }
        }
        var failures = 0
        for c in targets {
            let s = statuses.first { $0.client == c }!
            if !remove, !named, s.state == .connected {
                print("✓ \(c.title): already connected")
                continue
            }
            do {
                let change = remove ? try AgentSetup.disconnect(c) : try AgentSetup.connect(c, helper: helper)
                print("✓ \(change.summary)")
                if let f = change.followUp { print("  \(f)") }
            } catch {
                failures += 1
                print("✗ \(c.title): \(error)")
            }
        }
        if !remove && failures < targets.count { print("\nAgents record through Glint.app, so macOS asks once for Screen Recording permission for Glint.") }
        if failures > 0 { throw ExitCode(1) }
    }

    func report(_ statuses: [AgentStatus], helper: String) {
        print("Glint CLI: \(helper)")
        if let p = AgentSetup.locationProblem(helper) { print("  ! \(p)") }
        for s in statuses {
            let state: String
            switch s.state {
            case .connected: state = "connected"
            case .notConnected: state = "not connected"
            case .notInstalled: state = "not installed"
            case .disabled: state = "turned off in its config"
            case .misconfigured(let why): state = "needs repair: \(why)"
            case .otherCopy(let cmd): state = "points at another copy: \(cmd)"
            case .error(let e): state = "error: \(e)"
            }
            print("\(s.client.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)")
            if s.state != .notInstalled { print("\("".padding(toLength: 16, withPad: " ", startingAt: 0)) \(s.configLocation)") }
            for n in s.notes { print("\("".padding(toLength: 16, withPad: " ", startingAt: 0)) \(n)") }
        }
    }

    func printManual(_ helper: String) {
        for c in AgentClient.allCases {
            print("# \(c.title)\n")
            print(AgentSetup.manualInstructions(c, helper: helper))
            print("")
        }
        for o in OtherClient.allCases {
            print("# \(o.title)\n\n\(o.destination)\n")
            print(o.snippet(helper: helper))
            print("")
        }
    }

    func indent(_ s: String) -> String { s.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") }
}

struct InstallCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install-cli",
                                                    abstract: "Link `glint` into ~/.local/bin so it runs from any terminal.")
    @Flag(help: "Remove the link instead.") var remove = false

    func run() throws {
        if remove {
            try AgentSetup.removeCLILink()
            print("Removed \(AgentSetup.cliLinkURL.path).")
            return
        }
        let link = try AgentSetup.installCLILink()
        print("✓ \(link) → \(AgentSetup.helperPath())")
        if !AgentSetup.cliLinkDirectoryOnPath() {
            print("  ~/.local/bin isn't on your PATH yet. Add this to ~/.zshrc, then open a new terminal:")
            print("  export PATH=\"$HOME/.local/bin:$PATH\"")
        }
    }
}
