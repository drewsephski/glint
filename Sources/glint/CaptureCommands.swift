import Foundation
import ArgumentParser
import GlintCore
import GlintCapture
import GlintAgent

/// Capture reliability commands: pause/resume a take in progress, check a take can start, recover interrupted takes.
enum CaptureCommands {
    static let all: [ParsableCommand.Type] = [Pause.self, Resume.self, Preflight.self, Recover.self]
}

/// Pause or resume the take in another process (Glint.app, `glint record`, an agent's take) through `RecordingControl`.
private func controlRecording(_ action: String, session: String?, json: Bool) throws {
    let entries = SessionRegistry.active()
    let candidates = session.map { id in entries.filter { $0.id == id } } ?? entries
    guard !candidates.isEmpty else { throw ServiceError.invalid(session.map { "No recording \($0) is in progress." } ?? "Nothing is recording.") }
    guard candidates.count == 1 else {
        let list = candidates.map { "  \($0.id)  \($0.author.name)  \(URL(fileURLWithPath: $0.project).lastPathComponent)" }.joined(separator: "\n")
        throw ServiceError.invalid("Several recordings are in progress; choose one with --session:\n\(list)")
    }
    let e = candidates[0]
    let j = try RecordingControl.send(action, to: e, by: cliAuthor.description)
    if json {
        printJSON(.object(["session_id": .string(e.id), "project": .string(e.project), "paused": .bool(j.paused),
                           "elapsed": .number(j.elapsed), "pauses": try JSONValue.from(j.pauses)]))
        return
    }
    let name = URL(fileURLWithPath: e.project).deletingPathExtension().lastPathComponent
    let at = j.pauses.last.map { String(format: "%.1f s", $0.at) } ?? String(format: "%.1f s", j.elapsed)
    print(j.paused ? "❙❙ Paused “\(name)” at \(at). `glint resume` continues it." : "● Resumed “\(name)” (\(j.pauses.count) pause\(j.pauses.count == 1 ? "" : "s") so far).")
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause the recording in progress (in Glint, `glint record` or an agent's take).",
                                                    discussion: "Screen, audio, camera and input all pause together. `glint resume` continues in the same files with no gap; the pause becomes a cut.")
    @Option(help: "Session ID (default: the only recording in progress).") var session: String?
    @Flag var json = false
    func run() throws { try controlRecording("pause", session: session, json: json) }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a paused recording.")
    @Option(help: "Session ID (default: the only recording in progress).") var session: String?
    @Flag var json = false
    func run() throws { try controlRecording("resume", session: session, json: json) }
}

struct Preflight: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check a recording can start: permissions, source, disk space, folder.",
                                                    discussion: "Checks this process's permissions, as `glint record` records here. Exits 1 when a check fails.")
    @Option(help: "Display ID (default main).") var display: UInt32?
    @Option(help: "Window ID.") var window: UInt32?
    @Option(name: [.short, .long], help: "Planned length in seconds (the disk check covers the whole take).") var duration: Double?
    @Flag(help: "Will record the microphone.") var mic = false
    @Flag(help: "Won't record system audio.") var noSystemAudio = false
    @Flag(help: "Will record the camera.") var camera = false
    @Option(help: "Camera to record (implies --camera).") var cameraId: String?
    @Option(help: "Folder for the project (default ~/Movies/Glint).") var dir: String?
    @Flag var json = false
    func run() throws {
        var args: [String: JSONValue?] = ["display_id": display.map { .number(Double($0)) }, "window_id": window.map { .number(Double($0)) },
                                          "max_duration": duration.j, "microphone": mic.j, "system_audio": (!noSystemAudio).j,
                                          "camera": (camera || cameraId != nil).j, "camera_id": cameraId.j, "directory": dir.j]
        args = args.filter { $0.value != nil }
        let out = try callTool("record_preflight", args, quiet: true)
        if json { printJSON(out.json) } else {
            for c in out.json["checks"]?.arrayValue ?? [] {
                let mark = ["pass": "✓", "warn": "!", "fail": "✗"][c.str("verdict") ?? ""] ?? "?"
                print("\(mark) \(c.str("title") ?? ""): \(c.str("detail") ?? "")")
                if let fix = c.str("fix"), c.str("verdict") != "pass" { print("    Fix: \(fix)") }
            }
            if let perMinute = out.json.num("estimatedBytesPerMinute") {
                print("About \(PreflightMath.formatBytes(perMinute)) a minute\(out.json.num("estimatedBytes").map { ", \(PreflightMath.formatBytes($0)) for the take" } ?? "").")
            }
        }
        if out.json.flag("ok") == false { throw ExitCode(1) }
    }
}

struct Recover: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List takes that were interrupted (crash, forced quit, power loss) and rebuild them into projects.",
                                                    discussion: "Media is saved every 2 s while recording, so a take interrupted at any point keeps all but its last couple of seconds. With no arguments, lists the interrupted takes.")
    @Argument(help: "Interrupted project to recover (path or name).") var project: String?
    @Flag(help: "Recover every interrupted take.") var all = false
    @Flag(help: "Move the take to the Trash instead of recovering it.") var discard = false
    @Option(help: "Approval ID (when an agent discards).") var approval: String?
    @Flag var json = false

    func run() throws {
        if discard {
            guard let project else { throw ValidationError("Name the take to discard (see `glint recover`).") }
            try discardTake(project)
            return
        }
        guard project != nil || all else { return try list() }
        let out = try callTool("recover_recordings", ["action": .string("recover"), "project": project.j], quiet: true)
        if json { printJSON(out.json); return }
        let results = out.json["recovered"]?.arrayValue ?? []
        if results.isEmpty { print(out.json.str("note") ?? "No interrupted recordings.") }
        var failed = false
        for r in results {
            if let e = r.str("error") {
                failed = true
                FileHandle.standardError.write(Data("✗ \(URL(fileURLWithPath: r.str("project") ?? "").lastPathComponent): \(e)\n".utf8))
                continue
            }
            print("✓ \(r.str("project") ?? "")")
            for n in r["notes"]?.arrayValue ?? [] { print("    \(n.stringValue ?? "")") }
        }
        if failed { throw ExitCode(1) }
    }

    private func list() throws {
        let out = try callTool("recover_recordings", ["action": .string("list")], quiet: true)
        if json { printJSON(out.json); return }
        let items = out.json.arrayValue ?? []
        if items.isEmpty { print("No interrupted recordings."); return }
        for r in items {
            let name = r.str("name") ?? ""
            let at = r.str("lastCheckpoint") ?? ""
            print("\(name)  ·  \(String(format: "%.1f s", r.num("elapsed") ?? 0)) recorded  ·  last saved \(at)\(r.str("error").map { "  ·  \($0)" } ?? "")\n   \(r.str("project") ?? "")")
        }
        print("\nRecover one with `glint recover <path>`, all with `glint recover --all`, or discard with `glint recover <path> --discard`.")
    }

    private func discardTake(_ ref: String) throws {
        let author = cliAuthor
        if author.kind == .user {
            // A person at the terminal confirms here, which is the approval (as the app's confirmation dialog is).
            FileHandle.standardError.write(Data("Move “\(URL(fileURLWithPath: ref).lastPathComponent)” to the Trash? [y/N] ".utf8))
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else { print("Kept."); return }
            let r = try service.discardRecording(try service.resolveRecoverable(ref), author: author, approvalID: nil, confirmedByUser: true)
            print("Moved to the Trash: \(r?.path ?? ref)")
            return
        }
        let out = try callTool("recover_recordings", ["action": .string("discard"), "project": .string(ref), "approval_id": approval.j], quiet: true)
        if json { printJSON(out.json) } else { print("Moved to the Trash: \(out.json.str("trashed") ?? ref)") }
    }
}
