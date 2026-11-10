import Foundation
import ArgumentParser
import GlintCore
import GlintAnalysis
import GlintAgent

// MARK: - Narration: scenes → script → voice

struct Scenes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Split the recording into scenes (on-device): one frame and its on-screen text per scene.")
    @OptionGroup var p: ProjectOption
    @Option(help: "Input gap that starts a new scene (s).") var gap: Double?
    @Option(help: "Longest scene before splitting (s).") var maxScene: Double?
    @Flag(help: "Print the saved storyboard instead of re-analyzing.") var show = false
    @Flag var json = false
    func run() throws {
        let out = show ? try callTool("get_storyboard", ["project": p.project.j], quiet: true)
                       : try callTool("analyze_scenes", ["project": p.project.j, "gap": gap.j, "max_scene": maxScene.j])
        if json { printJSON(out.json); return }
        printStoryboard(out.json)
    }
}

func printStoryboard(_ sb: JSONValue) {
    guard let scenes = sb["scenes"]?.arrayValue, !scenes.isEmpty else { print(sb.str("hint") ?? "No scenes."); return }
    if let t = sb.str("title") { print(t) }
    if let s = sb.str("summary") { print(s); print("") }
    for sc in scenes {
        let id = sc.str("id") ?? "", start = sc.num("start") ?? 0, end = sc.num("end") ?? 0
        print(String(format: "%@  %6.1f–%6.1fs  %@", id.padding(toLength: 10, withPad: " ", startingAt: 0), start, end, sc.str("title") ?? ""))
        let actions = sc["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !actions.isEmpty { print("          " + actions.prefix(4).joined(separator: " · ")) }
        if let n = sc.str("narration") { print("          “\(n)”") } else { print("          (no narration)") }
    }
}

struct Narrate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the narration: Claude drafts one line per scene from the frames (sends them to Anthropic), or set lines yourself.")
    @OptionGroup var p: ProjectOption
    @Option(help: "What the product is, who the demo is for, what to emphasise.") var brief: String?
    @Option var tone: String?
    @Option var language: String?
    @Option var model: String?
    @Option(help: "auto | claude | chatgpt | api-key") var writer = "auto"
    @Flag(help: "Keep lines you already wrote.") var onlyMissing = false
    @Option(name: .customLong("set"), parsing: .unconditionalSingleValue, help: "Set a line by hand: --set s3=\"Click Export to…\" (empty clears). Skips Claude.") var set: [String] = []
    @Option var approval: String?
    func run() throws {
        if !set.isEmpty {
            var lines: [String: JSONValue] = [:]
            for item in set {
                guard let eq = item.firstIndex(of: "=") else { throw ValidationError("--set wants scene_id=text") }
                lines[String(item[..<eq])] = .string(String(item[item.index(after: eq)...]))
            }
            let out = try callTool("set_narration", ["project": p.project.j, "lines": .object(lines)])
            printStoryboard(out.json); return
        }
        let out = try callTool("write_narration", ["project": p.project.j, "brief": brief.j, "tone": tone.j, "language": language.j, "model": model.j,
                                                   "writer": .string(writer), "only_missing": onlyMissing.j, "approval_id": approval.j])
        if let writer = out.json.str("writer") { print("Writer: " + writer) }
        printStoryboard(out.json)
        if let next = out.json.str("next") { print("\n" + next) }
    }
}

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List ElevenLabs voices on your account.")
    @Flag var json = false
    func run() throws {
        let out = try callTool("list_voices", [:], quiet: true)
        if json { printJSON(out.json); return }
        for v in out.json.arrayValue ?? [] {
            let labels = v["labels"]?.objectValue?.values.compactMap(\.stringValue).sorted().joined(separator: ", ") ?? ""
            print("\((v.str("name") ?? "").padding(toLength: 22, withPad: " ", startingAt: 0)) \(v.str("id") ?? "")  \(labels)")
        }
    }
}

struct Voiceover: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Synthesize the narration with ElevenLabs, fit the picture to it and caption it (proposal; --apply to apply).")
    @OptionGroup var p: ProjectOption
    @Option(help: "Voice ID or name (default: the project's saved voice).") var voice: String?
    @Option(parsing: .upToNextOption, help: "Only these scene IDs.") var scene: [String] = []
    @Flag(help: "Don't retime the picture to the narration.") var noFit = false
    @Flag(help: "Don't rebuild captions from the voice.") var noCaptions = false
    @Flag var apply = false
    @Option var approval: String?
    func run() throws {
        try emit("voiceover", ["project": p.project.j, "voice": voice.j, "scenes": scene.isEmpty ? nil : .array(scene.map(JSONValue.string)),
                               "fit": (!noFit).j, "captions": (!noCaptions).j, "apply": apply.j, "approval_id": approval.j])
    }
}

struct Fit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Retime scenes to the voiceover clips already on the timeline (after moving clips or cutting).")
    @OptionGroup var p: ProjectOption
    @Flag var noCaptions = false
    @Flag var apply = false
    func run() throws { try emit("fit_narration", ["project": p.project.j, "captions": (!noCaptions).j, "apply": apply.j]) }
}

// MARK: - API keys

struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or store API keys. Anthropic is an alternative to signing in with Claude or ChatGPT. Keys live in the macOS Keychain (signed builds), a 0600 file (development builds) or env vars; never in the app itself.",
                                                    subcommands: [Show.self, Set_.self, Clear.self], defaultSubcommand: Show.self)
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Which keys are set and where they come from.")
        func run() {
            for k in Secrets.Key.allCases {
                let src = Secrets.source(k)
                print("\(k.title.padding(toLength: 12, withPad: " ", startingAt: 0)) \(src ?? "not set")   (env \(k.environment))")
            }
        }
    }
    struct Set_: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Store a key. Reads it from the terminal without echo; refuses when not at a terminal.")
        @Argument(help: "elevenlabs | anthropic") var service: String
        func run() throws {
            guard let key = Secrets.Key(rawValue: service) ?? Secrets.Key.allCases.first(where: { $0.title.lowercased() == service.lowercased() || "\($0)" == service }) else {
                throw ValidationError("Unknown service. Use elevenlabs or anthropic.")
            }
            guard isatty(STDIN_FILENO) != 0 else { throw ValidationError("glint keys set only works at an interactive terminal (keys aren't taken from pipes or agents). Set \(key.environment) instead.") }
            guard let raw = getpass("\(key.title) API key: ") else { throw ExitCode(1) }
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ValidationError("Empty key") }
            try Secrets.set(key, value)
            print("Saved \(key.title) key to \(Secrets.storeDescription)")
        }
    }
    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a stored key.")
        @Argument(help: "elevenlabs | anthropic") var service: String
        func run() throws {
            guard let key = Secrets.Key(rawValue: service) ?? Secrets.Key.allCases.first(where: { $0.title.lowercased() == service.lowercased() || "\($0)" == service }) else {
                throw ValidationError("Unknown service. Use elevenlabs or anthropic.")
            }
            try Secrets.set(key, nil)
            print("Removed \(key.title) key")
        }
    }
}
