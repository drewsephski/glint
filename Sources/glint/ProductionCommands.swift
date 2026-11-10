import Foundation
import ArgumentParser
import GlintCore
import GlintAgent

enum ProductionCommands {
    static let all: [ParsableCommand.Type] = [Clips.self, AddClip.self, AddAudio.self, Callout.self, Redact.self, SubtitlesCmd.self, CutWords.self,
                                              Presets.self, RecipeCmd.self, JobCmd.self]
}

func parseRect(_ s: String) throws -> JSONValue {
    let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard v.count == 4 else { throw ValidationError("rect is x,y,width,height (0–1, origin top-left), e.g. 0.6,0.05,0.3,0.08") }
    return .object(["x": .number(v[0]), "y": .number(v[1]), "width": .number(v[2]), "height": .number(v[3])])
}
func parsePoint(_ s: String) throws -> JSONValue {
    let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard v.count == 2 else { throw ValidationError("points are x,y (0–1), e.g. 0.4,0.6") }
    return .object(["x": .number(v[0]), "y": .number(v[1])])
}

struct Clips: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the program's shots (program start/end, file range, scene, take).")
    @OptionGroup var p: ProjectOption
    func run() throws { try emit("list_clips", ["project": p.project.j]) }
}

struct AddClip: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-clip", abstract: "Insert a movie as a shot (copied into the project; edits keep their content).")
    @OptionGroup var p: ProjectOption
    @Argument var file: String
    @Option(help: "Program time to insert at (default: the end).") var at: Double?
    @Option var name: String?
    @Option(help: "Recipe scene ID this shot shows.") var scene: String?
    @Option(help: "Use the file from this time (s).") var start: Double?
    @Option(help: "…to this time (s).") var end: Double?
    @Flag(help: "Create a proposal instead of applying.") var propose = false
    func run() throws {
        try emit("import_clip", ["project": p.project.j, "file": .string(file), "at": at.j, "name": name.j, "scene": scene.j, "start": start.j, "end": end.j, "apply": (!propose).j])
    }
}

struct AddAudio: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-audio", abstract: "Add a music bed, a recorded voiceover or a sound effect.")
    @OptionGroup var p: ProjectOption
    @Argument var file: String
    @Option(help: "music | voice | effect") var kind: String = "music"
    @Option(help: "Program time to start at.") var at: Double = 0
    @Option var name: String?
    @Option(help: "Level 0–3 (music defaults to 0.35).") var gain: Double?
    @Flag(inversion: .prefixedNo, help: "Loop to fill the video (music default).") var loop: Bool?
    func run() throws {
        try emit("import_audio", ["project": p.project.j, "file": .string(file), "kind": .string(kind), "at": .number(at), "name": name.j, "gain": gain.j, "loop": loop.map(JSONValue.bool)])
    }
}

struct Callout: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add a callout: text, arrow, box or highlight (positions 0–1 on the recorded screen, top-left origin).")
    @OptionGroup var p: ProjectOption
    @Argument(help: "text | arrow | box | highlight") var kind: String
    @Option var start: Double
    @Option var end: Double
    @Option(help: "x,y,width,height for box/highlight/text.") var rect: String?
    @Option(help: "Arrow tail x,y.") var from: String?
    @Option(help: "Arrow head x,y.") var to: String?
    @Option var text: String?
    @Option(help: "#RRGGBB") var color: String?
    @Flag(help: "Times are output (rendered) seconds.") var outputTime = false
    func run() throws {
        var item: [String: JSONValue] = ["kind": .string(kind), "start": .number(start), "end": .number(end)]
        if let rect { item["rect"] = try parseRect(rect) }
        if let from { item["from"] = try parsePoint(from) }
        if let to { item["to"] = try parsePoint(to) }
        if let text { item["text"] = .string(text) }
        if let color { item["color"] = .string(color) }
        var op: [String: JSONValue] = ["op": .string("add_annotation"), "item": .object(item)]
        if outputTime { op["time_base"] = .string("output") }
        try emit("apply_operations", ["project": p.project.j, "operations": .array([.object(op)])])
    }
}

struct Redact: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mask part of the screen for a time range (pixelate, blur or solid) in every render.")
    @OptionGroup var p: ProjectOption
    @Option var start: Double
    @Option var end: Double
    @Option(help: "x,y,width,height (0–1, top-left origin).") var rect: String
    @Option(help: "pixelate | blur | solid") var mode: String = "pixelate"
    @Option(help: "0.1–1") var strength: Double?
    @Flag(help: "Times are output (rendered) seconds.") var outputTime = false
    func run() throws {
        var item: [String: JSONValue] = ["start": .number(start), "end": .number(end), "rect": try parseRect(rect), "mode": .string(mode)]
        if let strength { item["strength"] = .number(strength) }
        var op: [String: JSONValue] = ["op": .string("add_redaction"), "item": .object(item)]
        if outputTime { op["time_base"] = .string("output") }
        try emit("apply_operations", ["project": p.project.j, "operations": .array([.object(op)])])
    }
}

struct SubtitlesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "subtitles", abstract: "Export or import SRT/WebVTT captions timed to the edited output.",
                                                    subcommands: [ExportSubs.self, ImportSubs.self])
    struct ExportSubs: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "export")
        @OptionGroup var p: ProjectOption
        @Option(help: "srt | vtt") var format: String = "srt"
        func run() throws { try emit("export_subtitles", ["project": p.project.j, "format": .string(format)]) }
    }
    struct ImportSubs: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "import")
        @OptionGroup var p: ProjectOption
        @Argument var file: String
        @Flag(help: "Cue times are recording (source) seconds rather than the edited output.") var sourceTime = false
        func run() throws { try emit("import_subtitles", ["project": p.project.j, "file": .string(file), "time_base": .string(sourceTime ? "source" : "output")]) }
    }
}

struct CutWords: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cut-words", abstract: "Remove spoken words by editing the transcript (proposal unless --apply).")
    @OptionGroup var p: ProjectOption
    @Option(help: "Delete every occurrence of this phrase.") var phrase: String?
    @Option(help: "Word index range from:to (repeatable).") var range: [String] = []
    @Flag var apply = false
    func run() throws {
        let rs: [JSONValue] = try range.map { r in
            let v = r.split(separator: ":").compactMap { Int($0) }
            guard v.count == 2 else { throw ValidationError("ranges are from:to word indices") }
            return .array([.number(Double(v[0])), .number(Double(v[1]))])
        }
        try emit("edit_transcript", ["project": p.project.j, "phrase": phrase.j, "remove": .array(rs), "apply": apply.j])
    }
}

struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List, apply or save reusable style presets.", subcommands: [List.self, ApplyP.self, Save.self])
    struct List: ParsableCommand { func run() throws { try emit("list_presets", [:]) } }
    struct ApplyP: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "apply")
        @OptionGroup var p: ProjectOption
        @Argument var name: String
        func run() throws { try emit("apply_preset", ["project": p.project.j, "name": .string(name)]) }
    }
    struct Save: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Argument var name: String
        @Option var summary: String?
        func run() throws { try emit("save_preset", ["project": p.project.j, "name": .string(name), "summary": summary.j]) }
    }
}

struct RecipeCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recipe", abstract: "Reusable demo recipes: scenes with stable IDs, expected outcomes and evidence.",
                                                    subcommands: [Save.self, Show.self, Build.self, Evidence.self, Verify.self, Refresh.self])
    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a recipe from a JSON file (- for stdin).")
        @OptionGroup var p: ProjectOption
        @Argument var file: String
        func run() throws {
            let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            try emit("recipe_save", ["project": p.project.j, "recipe": try JSONCoding.decoder.decode(JSONValue.self, from: data)])
        }
    }
    struct Show: ParsableCommand {
        @OptionGroup var p: ProjectOption
        func run() throws { try emit("recipe_get", ["project": p.project.j]) }
    }
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Split the recording into one shot per scene from its scene:<id> markers.")
        @OptionGroup var p: ProjectOption
        func run() throws { try emit("recipe_build", ["project": p.project.j]) }
    }
    struct Evidence: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record evidence for an expected outcome.")
        @OptionGroup var p: ProjectOption
        @Argument var scene: String
        @Argument var expectation: String
        @Option(help: "verified | failed | needs_review") var status: String
        @Option(help: "assertion | ocr | human | action | vision") var source: String
        @Option var detail: String
        @Option var observed: String?
        func run() throws {
            try emit("recipe_evidence", ["project": p.project.j, "scene_id": .string(scene), "expectation_id": .string(expectation), "status": .string(status),
                                         "source": .string(source), "detail": .string(detail), "observed": observed.j])
        }
    }
    struct Verify: ParsableCommand {
        @OptionGroup var p: ProjectOption
        func run() throws {
            let out = try callTool("recipe_verify", ["project": p.project.j])
            printJSON(out.json)
            if out.json["status"]?.stringValue == "failed" { throw ExitCode(1) }
        }
    }
    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Replace a scene's shot with the same scene from a new recording.")
        @OptionGroup var p: ProjectOption
        @Argument var scene: String
        @Option(help: "The new recording (project path or name).") var take: String
        @Option var start: Double?
        @Option var end: Double?
        @Flag(help: "Create a proposal instead of applying.") var propose = false
        func run() throws {
            try emit("recipe_refresh_scene", ["project": p.project.j, "scene_id": .string(scene), "take": .string(take), "start": start.j, "end": end.j, "apply": (!propose).j])
        }
    }
}

struct JobCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "job", abstract: "Durable render/production jobs with checkpoints, cancel and retry.",
                                                    subcommands: [Start.self, Status.self, List.self, Cancel.self, Retry.self])
    struct Start: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Option(help: "render | production") var kind: String = "render"
        @Option(name: [.short, .long]) var variant: [String] = []
        @Option(help: "Same key → same job (no duplicate work).") var key: String?
        @Option var expectedRevision: Int?
        @Flag(help: "production: don't apply automatic repairs.") var noRepair = false
        @Option var target: Double?
        func run() throws {
            var a: [String: JSONValue?] = ["project": p.project.j, "kind": .string(kind), "idempotency_key": key.j, "expected_revision": expectedRevision.j,
                                           "repair": (!noRepair).j, "target_duration": target.j, "wait": true.j]
            if kind == "production" { a["variant"] = variant.first.j } else if !variant.isEmpty { a["variants"] = .array(variant.map(JSONValue.string)) }
            let out = try callTool("job_start", a)
            printJSON(out.json)
            if out.json["status"]?.stringValue == "failed" { throw ExitCode(1) }
        }
    }
    struct Status: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Argument var id: String
        func run() throws { try emit("job_status", ["project": p.project.j, "job_id": .string(id)]) }
    }
    struct List: ParsableCommand {
        @OptionGroup var p: ProjectOption
        func run() throws { try emit("job_list", ["project": p.project.j]) }
    }
    struct Cancel: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Argument var id: String
        func run() throws { try emit("job_cancel", ["project": p.project.j, "job_id": .string(id)]) }
    }
    struct Retry: ParsableCommand {
        @OptionGroup var p: ProjectOption
        @Argument var id: String
        func run() throws { try emit("job_retry", ["project": p.project.j, "job_id": .string(id), "wait": true.j]) }
    }
}
