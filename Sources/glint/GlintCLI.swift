import Foundation
import ArgumentParser
import AppKit
import GlintCore
import GlintCapture
import GlintRender
import GlintAnalysis
import GlintAgent

// MARK: - Plumbing

/// Run async work while spinning the main run loop (needed for AppKit sampling such as the system cursor).
final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>?; init() {} }

func runLoop<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
    }
    while box.result == nil { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    return try box.result!.get()
}

/// People at an interactive terminal are users; anything else (an agent's shell, a script) is treated as an agent,
/// so approval gates apply to it.
var cliAuthor: Author {
    if isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 { return Author(.user, "cli") }
    return Author(.agent, ProcessInfo.processInfo.environment["GLINT_AGENT_NAME"] ?? "cli")
}

let service = GlintService()

@Sendable func logProgress(_ msg: String) { FileHandle.standardError.write(("… " + msg + "\n").data(using: .utf8)!) }

func printJSON(_ v: JSONValue) { print(JSONCoding.string(v)) }

func callTool(_ name: String, _ args: [String: JSONValue?], quiet: Bool = false) throws -> ToolOutput {
    var a: [String: JSONValue] = [:]
    for (k, v) in args { if let v { a[k] = v } }
    var progress: (@Sendable (String) -> Void)? = nil
    if !quiet { progress = logProgress }
    let ctx = ToolContext(author: cliAuthor, service: service, progress: progress)
    let arguments = JSONValue.object(a)
    do {
        return try runLoop { () async throws -> ToolOutput in try await ToolRegistry.call(name, arguments: arguments, context: ctx) }
    } catch let e as ApprovalError {
        FileHandle.standardError.write(Data("\(e.description)\n".utf8))
        throw ExitCode(3)
    }
}

func emit(_ name: String, _ args: [String: JSONValue?]) throws {
    let out = try callTool(name, args)
    printJSON(out.json)
    for img in out.images { FileHandle.standardError.write(Data("image: \(img.path)\n".utf8)) }
}

extension Optional where Wrapped == String { var j: JSONValue? { self.map(JSONValue.string) } }
extension Optional where Wrapped == Double { var j: JSONValue? { self.map(JSONValue.number) } }
extension Optional where Wrapped == Int { var j: JSONValue? { self.map { .number(Double($0)) } } }
extension Bool { var j: JSONValue { .bool(self) } }

func readOperations(file: String?, ops: [String]) throws -> JSONValue {
    var items: [JSONValue] = []
    if let file {
        let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
        let v = try JSONCoding.decoder.decode(JSONValue.self, from: data)
        items += v.arrayValue ?? v["operations"]?.arrayValue ?? [v]
    }
    for o in ops { items.append(try JSONCoding.decoder.decode(JSONValue.self, from: Data(o.utf8))) }
    guard !items.isEmpty else { throw ValidationError("Provide operations with --op '{\"op\":…}' or --file ops.json") }
    return .array(items)
}

struct ProjectOption: ParsableArguments {
    @Option(name: [.short, .long], help: "Project path, name, or \"latest\" (default).")
    var project: String?
}

// MARK: - Commands

@main
struct Glint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glint",
        abstract: "Record your screen and turn takes into polished demos — from the terminal, the app, or an AI agent (MCP).",
        discussion: "Every edit is an undoable transaction shared with the Glint app. Run `glint docs workflow` for the agent workflow.",
        version: GlintVersion.string,
        subcommands: [Sources_.self, Record.self, Import.self, Projects.self, Info.self, Timeline.self, Events.self, Transcribe.self, Plan.self,
                      Edit.self, Propose.self, Proposals.self, Apply.self, Reject.self, Undo.self, Redo.self, Revert.self, History.self,
                      Frame.self, Sheet.self, Render.self, Inspect.self, QC.self, Autopilot_.self, Export.self, Approvals.self, Approve.self,
                      Deny.self, Tools.self, Call.self, MCP.self, DocsCmd.self, Open.self, DemoProject.self]
    )
}

struct Sources_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sources", abstract: "List displays and windows you can record.")
    @Flag var json = false
    func run() throws {
        let out = try callTool("list_sources", [:], quiet: true)
        if json { printJSON(out.json); return }
        for s in out.json.arrayValue ?? [] {
            let kind = s.str("kind") ?? "", id = s.num("id").map { String(Int($0)) } ?? ""
            let size = "\(s.num("pixelWidth").map { Int($0) } ?? 0)×\(s.num("pixelHeight").map { Int($0) } ?? 0)"
            print("\(kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(id.padding(toLength: 7, withPad: " ", startingAt: 0)) \(size.padding(toLength: 11, withPad: " ", startingAt: 0)) \(s.str("app").map { "\($0) — " } ?? "")\(s.str("name") ?? "")\(s.flag("isMain") == true ? "  (main)" : "")")
        }
    }
}

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record a display or window into a new project (Ctrl-C to stop).")
    @Option(help: "Display ID (see `glint sources`; default main).") var display: UInt32?
    @Option(help: "Window ID.") var window: UInt32?
    @Option(name: [.short, .long], help: "Stop after N seconds.") var duration: Double?
    @Flag(help: "Record the microphone.") var mic = false
    @Flag(help: "Don't record system audio.") var noSystemAudio = false
    @Option(help: "Project name.") var name: String?
    @Option(help: "Folder for the project (default ~/Movies/Glint).") var dir: String?
    @Option(help: "Approval ID (when an agent records).") var approval: String?
    @Option(help: "Marker notes to drop at given seconds, e.g. --mark '3:opened settings'.") var mark: [String] = []

    func run() throws {
        var o = RecordingOptions()
        o.displayID = display; o.windowID = window; o.maxDuration = duration; o.microphone = mic; o.systemAudio = !noSystemAudio
        o.projectName = name; o.directory = dir
        let author = cliAuthor
        let marks = mark.compactMap { m -> (Double, String)? in
            let parts = m.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let t = Double(parts[0]) else { return nil }
            return (t, String(parts[1]))
        }
        let opts = o
        let approvalID = approval, maxDuration = duration
        let bundle: ProjectBundle = try runLoop { () async throws -> ProjectBundle in
            let (_, session) = try await service.startRecording(options: opts, author: author, approvalID: approvalID)
            FileHandle.standardError.write(Data("● Recording \(session.source.kind.rawValue) “\(session.source.name)” → \(session.bundle.url.lastPathComponent)\(maxDuration.map { " for \($0)s" } ?? " — press Ctrl-C to stop")\n".utf8))
            let stopFlag = StopFlag()
            signal(SIGINT, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            src.setEventHandler { stopFlag.set() }
            src.resume()
            var pending = marks.sorted { $0.0 < $1.0 }
            while session.isRecording && !stopFlag.isSet {
                if let next = pending.first, session.elapsed >= next.0 { session.mark(next.1); pending.removeFirst() }
                if let d = maxDuration, session.elapsed >= d { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            src.cancel()
            return try await service.stopRecording(nil)
        }
        let s = try service.summary(bundle)
        FileHandle.standardError.write(Data("■ Saved \(String(format: "%.1f", s.sourceDuration))s, \(s.counts["clicks"] ?? 0) clicks, \(s.counts["keys"] ?? 0) keys\n".utf8))
        print(bundle.url.path)
    }
}

final class StopFlag: @unchecked Sendable { private var v = false; private let l = NSLock(); func set() { l.withLock { v = true } }; var isSet: Bool { l.withLock { v } } }

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a project from an existing movie (no input events, so no auto zoom).")
    @Argument var movie: String
    @Option var name: String?
    func run() throws {
        let url = URL(fileURLWithPath: (movie as NSString).expandingTildeInPath)
        let n = name
        let b = try runLoop { () async throws -> ProjectBundle in try await service.importMovie(url, name: n) }
        print(b.url.path)
    }
}

struct Projects: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent projects.")
    @Flag var json = false
    func run() throws {
        let out = try callTool("list_projects", [:], quiet: true)
        if json { printJSON(out.json); return }
        for p in out.json.arrayValue ?? [] {
            print("\(p.str("name") ?? "")  ·  \(String(format: "%.1fs → %.1fs", p.num("sourceDuration") ?? 0, p.num("outputDuration") ?? 0))  ·  rev \(Int(p.num("revision") ?? 0))\n   \(p.str("path") ?? "")")
        }
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Summary of a project.")
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("project_info", ["project": p.project.j]) }
}

struct Timeline: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the edit document and time map.")
    @OptionGroup var p: ProjectOption
    @Option var proposal: String?
    func run() throws { try emit("get_timeline", ["project": p.project.j, "proposal_id": proposal.j]) }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What happened while recording: clicks, typing, idle, apps, markers.")
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("get_events", ["project": p.project.j]) }
}

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe speech on-device (word timings).")
    @OptionGroup var p: ProjectOption
    @Option var locale: String = "en-US"
    @Option(help: "auto | apple | whisper") var engine: String = "auto"
    @Option(help: "microphone | system") var source: String?
    func run() throws { try emit("transcribe", ["project": p.project.j, "locale": .string(locale), "engine": .string(engine), "source": source.j]) }
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Plan zooms, cuts or captions (creates a proposal; --apply to apply).",
                                                    subcommands: [Zooms.self, Cuts.self, Captions.self])
    struct Zooms: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Option var scale: Double?
        @Flag var apply = false
        @Flag(help: "Don't zoom on typing.") var noTyping = false
        func run() throws { try emit("plan_zooms", ["project": p.project.j, "scale": scale.j, "apply": apply.j, "include_typing": (!noTyping).j]) }
    }
    struct Cuts: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Option var minSilence: Double?
        @Flag var apply = false
        func run() throws { try emit("plan_cuts", ["project": p.project.j, "min_silence": minSilence.j, "apply": apply.j]) }
    }
    struct Captions: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Option(help: "highlight | pill | plain") var look: String?
        @Flag var apply = false
        func run() throws { try emit("generate_captions", ["project": p.project.j, "look": look.j, "apply": apply.j]) }
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply operations now (one undoable transaction).",
                                                    discussion: "Example: glint edit --op '{\"op\":\"add_zoom\",\"start\":3,\"end\":6,\"scale\":2}'")
    @OptionGroup var p: ProjectOption
    @Option(name: .customLong("op"), help: "Operation JSON (repeatable).") var ops: [String] = []
    @Option(help: "JSON file with an array of operations ('-' for stdin).") var file: String?
    @Option var label: String?
    @Option var expectedRevision: Int?
    func run() throws {
        try emit("apply_operations", ["project": p.project.j, "operations": try readOperations(file: file, ops: ops), "label": label.j, "expected_revision": expectedRevision.j])
    }
}

struct Propose: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a reviewable proposal from operations.")
    @OptionGroup var p: ProjectOption
    @Option var title: String
    @Option var rationale: String = ""
    @Option(name: .customLong("op")) var ops: [String] = []
    @Option var file: String?
    func run() throws {
        try emit("propose_edits", ["project": p.project.j, "title": .string(title), "rationale": .string(rationale), "operations": try readOperations(file: file, ops: ops)])
    }
}

struct Proposals: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List proposals.")
    @OptionGroup var p: ProjectOption
    @Option var status: String?
    func run() throws { try emit("list_proposals", ["project": p.project.j, "status": status.j]) }
}

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply a proposal.")
    @Argument var proposal: String
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("apply_proposal", ["project": p.project.j, "proposal_id": .string(proposal)]) }
}

struct Reject: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reject a proposal.")
    @Argument var proposal: String
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("reject_proposal", ["project": p.project.j, "proposal_id": .string(proposal)]) }
}

struct Undo: ParsableCommand {
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("undo", ["project": p.project.j]) }
}

struct Redo: ParsableCommand {
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("redo", ["project": p.project.j]) }
}

struct Revert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Revert one earlier transaction.")
    @Argument var transaction: String
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("revert", ["project": p.project.j, "transaction_id": .string(transaction)]) }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show edit history (who changed what).")
    @OptionGroup var p: ProjectOption
    @Flag var json = false
    func run() throws {
        let out = try callTool("history", ["project": p.project.j], quiet: true)
        if json { printJSON(out.json); return }
        for t in out.json["transactions"]?.arrayValue ?? [] {
            print("\(t.str("id") ?? "")  r\(Int(t.num("revision") ?? 0))  \((t.str("author") ?? "").padding(toLength: 22, withPad: " ", startingAt: 0))  \(t.str("label") ?? "")")
        }
        print("undo: \(out.json["undo_stack"]?.arrayValue?.count ?? 0)  redo: \(out.json["redo_stack"]?.arrayValue?.count ?? 0)")
    }
}

struct Frame: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render one output frame to PNG.")
    @OptionGroup var p: ProjectOption
    @Option(name: [.short, .long], help: "Output time (s).") var time: Double
    @Option var proposal: String?
    @Option var variant: String?
    func run() throws { try emit("render_frame", ["project": p.project.j, "time": .number(time), "proposal_id": proposal.j, "variant": variant.j]) }
}

struct Sheet: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Contact sheet of output frames.")
    @OptionGroup var p: ProjectOption
    @Option var count: Int = 12
    @Option var proposal: String?
    @Option var variant: String?
    func run() throws { try emit("contact_sheet", ["project": p.project.j, "count": .number(Double(count)), "proposal_id": proposal.j, "variant": variant.j]) }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render deliverables (landscape, landscape-4k, square, portrait, gif, preview) and measure them.")
    @OptionGroup var p: ProjectOption
    @Option(name: [.short, .long]) var variant: [String] = ["landscape"]
    @Option var proposal: String?
    @Flag var noInspect = false
    func run() throws {
        try emit("render", ["project": p.project.j, "variants": .array(variant.map(JSONValue.string)), "proposal_id": proposal.j, "inspect": (!noInspect).j])
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure a rendered video (duration, frames, sharpness, loudness…).")
    @Argument var file: String
    @Option var expectedDuration: Double?
    func run() throws { try emit("inspect_render", ["path": .string(file), "expected_duration": expectedDuration.j]) }
}

struct QC: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "qc", abstract: "Edit quality checks (no render needed).")
    @OptionGroup var p: ProjectOption
    @Option var proposal: String?
    @Option var target: Double?
    @Flag var json = false
    func run() throws {
        let out = try callTool("quality_report", ["project": p.project.j, "proposal_id": proposal.j, "target_duration": target.j], quiet: true)
        if json { printJSON(out.json); return }
        print("score \(Int(out.json.num("score") ?? 0))/100")
        for c in out.json["checks"]?.arrayValue ?? [] {
            let v = c.str("verdict") ?? ""
            let mark = v == "pass" ? "✓" : v == "warn" ? "!" : v == "fail" ? "✗" : "·"
            print(" \(mark) \((c.str("id") ?? "").padding(toLength: 24, withPad: " ", startingAt: 0)) \(c.str("message") ?? "")\(c.str("fix").map { "  → \($0)" } ?? "")")
        }
    }
}

struct Autopilot_: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "autopilot", abstract: "Transcribe, tighten, zoom, caption, check and render in one pass.")
    @OptionGroup var p: ProjectOption
    @Option(name: [.short, .long]) var variant: [String] = []
    @Flag var proposeOnly = false
    @Option var target: Double?
    func run() throws {
        try emit("autopilot", ["project": p.project.j, "variants": .array(variant.map(JSONValue.string)), "propose_only": proposeOnly.j, "target_duration": target.j])
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Copy a rendered file somewhere (overwrite needs approval).")
    @Argument var file: String
    @Argument var destination: String
    @Option var approval: String?
    func run() throws { try emit("export", ["file": .string(file), "destination": .string(destination), "approval_id": approval.j]) }
}

struct Approvals: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List approval requests from agents.")
    @Flag var all = false
    func run() throws {
        let rs = all ? service.approvals.all() : service.approvals.pending()
        if rs.isEmpty { print(all ? "No approval requests." : "No pending approval requests."); return }
        for r in rs {
            print("\(r.id)  [\(r.status.rawValue)]  \(r.risk.rawValue)  by \(r.requestedBy)\n   \(r.summary)")
        }
    }
}

func decide(_ id: String, approve: Bool) throws {
    guard isatty(STDIN_FILENO) != 0 else {
        throw ValidationError("Approvals need a person: run this in an interactive terminal (agents can't approve their own requests).")
    }
    guard let r = service.approvals.get(id) else { throw ValidationError("No approval request \(id)") }
    print("\(r.requestedBy) wants to: \(r.summary)\nRisk: \(r.risk.rawValue)\nParameters: \(r.parameters)")
    print(approve ? "Approve? [y/N] " : "Deny? [y/N] ", terminator: "")
    guard let line = readLine(), line.lowercased().hasPrefix("y") else { print("Cancelled."); return }
    let out = try service.approvals.decide(id, approve: approve, by: NSUserName())
    print("\(out.id): \(out.status.rawValue)")
}

struct Approve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Approve an agent's request (interactive terminal only).")
    @Argument var id: String
    func run() throws { try decide(id, approve: true) }
}

struct Deny: ParsableCommand {
    @Argument var id: String
    func run() throws { try decide(id, approve: false) }
}

struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List tools (the same set the MCP server exposes).")
    @Flag var json = false
    @Flag var markdown = false
    func run() throws {
        let tools = ToolRegistry.all()
        if json {
            printJSON(.array(tools.map { .object(["name": .string($0.name), "description": .string($0.description), "risk": .string($0.risk.rawValue), "inputSchema": $0.schema]) }))
        } else if markdown {
            print("| Tool | Risk | Description |\n|---|---|---|")
            for t in tools { print("| `\(t.name)` | \(t.risk.rawValue) | \(t.description.replacingOccurrences(of: "|", with: "\\|")) |") }
        } else {
            for t in tools { print("\(t.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(t.risk.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(t.title)") }
        }
    }
}

struct Call: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Call any tool with JSON arguments (exactly what MCP clients do).",
                                                    discussion: "glint call plan_zooms '{\"project\":\"latest\",\"apply\":true}'")
    @Argument var tool: String
    @Argument var arguments: String = "{}"
    func run() throws {
        let args = try JSONCoding.decoder.decode(JSONValue.self, from: Data(arguments.utf8))
        let ctx = ToolContext(author: cliAuthor, service: service, progress: logProgress)
        do {
            let out = try runLoop { () async throws -> ToolOutput in try await ToolRegistry.call(tool, arguments: args, context: ctx) }
            printJSON(out.json)
            for img in out.images { FileHandle.standardError.write(Data("image: \(img.path)\n".utf8)) }
        } catch let e as ApprovalError {
            FileHandle.standardError.write(Data("\(e.description)\n".utf8)); throw ExitCode(3)
        }
    }
}

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the MCP server on stdio.",
                                                    discussion: "Claude Code: claude mcp add glint -- \(CommandLine.arguments[0]) mcp")
    func run() throws {
        let server = MCPServer(service: service)
        let done = StopFlag()
        server.serve { done.set() }
        while !done.isSet { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        // Finish an in-flight recording cleanly if the client disconnects.
        if service.session(nil) != nil { _ = try? runLoop { () async throws -> ProjectBundle in try await service.stopRecording(nil) } }
    }
}

struct DocsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "docs", abstract: "Agent docs: workflow | operations | style | quality.")
    @Argument var topic: String = "workflow"
    func run() throws {
        guard let r = Docs.resources.first(where: { $0.uri.hasSuffix("/" + topic) }) else { throw ValidationError("Topics: workflow, operations, style, quality") }
        print(r.body())
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a project in the Glint app.")
    @OptionGroup var p: ProjectOption
    func run() throws {
        let b = try service.resolve(p.project)
        let app = URL(fileURLWithPath: "/Applications/Glint.app")
        let local = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Glint.app")
        let target = FileManager.default.fileExists(atPath: local.path) ? local : app
        let cfg = NSWorkspace.OpenConfiguration()
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([b.url], withApplicationAt: target, configuration: cfg) { _, err in
            if let err { FileHandle.standardError.write(Data("\(err.localizedDescription)\n".utf8)) }
            sem.signal()
        }
        sem.wait()
    }
}

struct DemoProject: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo-project", abstract: "Create a synthetic demo project (fake app UI + input events, optional voice) to try Glint without recording.")
    @Option var name: String = "Glint Demo"
    @Flag var voice = false
    func run() throws {
        let url = RecordingSession.makeProjectURL(name: name, directory: nil)
        let v = voice
        let b = try runLoop { () async throws -> ProjectBundle in try await SyntheticProject.make(at: url, voice: v) }
        print(b.url.path)
    }
}
