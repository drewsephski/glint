import Foundation
import GlintCore
import GlintAnalysis

public enum SubscriptionNarratorError: Error, CustomStringConvertible {
    case unavailable, notInstalled(SubscriptionProvider), authentication(SubscriptionProvider), usageLimit(String?), timedOut, refused, unreadable
    public var description: String {
        switch self {
        case .unavailable: return "Sign in with Claude or ChatGPT in Glint › Settings › Account, or add an Anthropic API key under Narration."
        case .notInstalled(let p): return "Install \(p.toolTitle), then reconnect in Glint › Settings › Account."
        case .authentication(let p): return "Reconnect \(p.title) in Glint › Settings › Account."
        case .usageLimit(let reset): return "Your plan usage limit was reached." + (reset.map { " Resets " + $0 + "." } ?? " Wait for your provider’s limit to reset and try again.")
        case .timedOut: return "Writing narration timed out. Try again."
        case .refused: return "The model declined this script. Revise the brief and try again."
        case .unreadable: return "The writer returned unreadable output. Try again."
        }
    }
}

enum SubscriptionNarrator {
    static func parse(_ text: String) throws -> JSONValue {
        for line in text.split(separator: "\n").reversed() {
            if let event = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line.utf8)), event["type"]?.stringValue == "result" {
                if let structured = event["structured_output"] { return try validate(structured) }
                if let result = event["result"]?.stringValue { return try parse(result) }
            }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(text[start...end].utf8)) else { throw SubscriptionNarratorError.unreadable }
        if let structured = value["structured_output"] { return try validate(structured) }
        if let result = value["result"]?.stringValue { return try parse(result) }
        return try validate(value)
    }
    static func validate(_ value: JSONValue) throws -> JSONValue {
        guard value["title"]?.stringValue != nil, value["summary"]?.stringValue != nil,
              let scenes = value["scenes"]?.arrayValue,
              scenes.allSatisfy({ $0["id"]?.stringValue != nil && $0["title"]?.stringValue != nil && $0["narration"]?.stringValue != nil }) else { throw SubscriptionNarratorError.unreadable }
        return value
    }
    static func write(provider: SubscriptionProvider, bundle: ProjectBundle, storyboard: Storyboard, document: ProjectDocument, options: NarrationOptions, timeout: TimeInterval = 600) async throws -> Storyboard {
        guard let path = provider.chatAgent.cliPath else { throw SubscriptionNarratorError.notInstalled(provider) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glint-narration-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let (content, system, schema) = Narrator.prompt(bundle: bundle, storyboard: storyboard, document: document, options: options)
        let schemaURL = dir.appendingPathComponent("schema.json")
        try JSONCoding.compactEncoder.encode(schema).write(to: schemaURL)
        var images: [String] = []
        for block in content where block["type"]?.stringValue == "image" {
            if let encoded = block["source"]?["data"]?.stringValue, let data = Data(base64Encoded: encoded) {
                let url = dir.appendingPathComponent("frame-\(images.count).jpg")
                try data.write(to: url); images.append(url.path)
            }
        }
        let input: Data
        var args: [String]
        let output = dir.appendingPathComponent("answer.txt")
        if provider == .claude {
            args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--safe-mode", "--json-schema", String(decoding: try JSONCoding.compactEncoder.encode(schema), as: UTF8.self)]
            let blocks = [JSONValue.object(["type": .string("text"), "text": .string(system)])] + content
            input = try JSONCoding.compactEncoder.encode(JSONValue.object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .array(blocks)])])) + Data([10])
        } else {
            args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-c", "mcp_servers={}", "-c", "features.shell_tool=false", "--output-schema", schemaURL.path, "--output-last-message", output.path]
            for image in images { args += ["--image", image] }
            args += ["-"]
            input = Data((system + "\n" + content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")).utf8)
        }
        let stdin = dir.appendingPathComponent("input")
        try input.write(to: stdin)
        let log = dir.appendingPathComponent("output")
        fm.createFile(atPath: log.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: stdin), writer = try FileHandle(forWritingTo: log)
        defer { try? reader.close(); try? writer.close() }
        let process = Process()
        SubscriptionProcessTree.configure(process, path: path, arguments: args)
        var environment = ProcessInfo.processInfo.environment
        let dirs = [URL(fileURLWithPath: path).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] + (LoginShell.path()?.split(separator: ":").map(String.init) ?? [])
        environment["PATH"] = (dirs + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = dir; process.standardInput = reader
        let errorURL = dir.appendingPathComponent("stderr")
        fm.createFile(atPath: errorURL.path, contents: nil)
        let errorWriter = try FileHandle(forWritingTo: errorURL)
        defer { try? errorWriter.close() }
        process.standardOutput = writer; process.standardError = errorWriter
        try Task.checkCancellation()
        do { try process.run() } catch { throw SubscriptionNarratorError.notInstalled(provider) }
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline { throw SubscriptionNarratorError.timedOut }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            SubscriptionProcessTree.stop(process)
            // Do not block the cooperative executor while Foundation delivers exit.
            while process.isRunning {
                await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
            }
            throw error
        }
        try Task.checkCancellation()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let diagnostics = text + ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")
        if Subscriptions.authIssue(in: diagnostics, provider: provider) != nil { throw SubscriptionNarratorError.authentication(provider) }
        let lower = diagnostics.lowercased()
        if Subscriptions.isUsageLimit(diagnostics) {
            throw SubscriptionNarratorError.usageLimit(Subscriptions.resetTime(in: diagnostics))
        }
        if lower.contains("refusal") { throw SubscriptionNarratorError.refused }
        guard process.terminationStatus == 0 else { throw SubscriptionNarratorError.unreadable }
        let answer = provider == .chatgpt ? ((try? String(contentsOf: output, encoding: .utf8)) ?? text) : text
        let result = try parse(answer)
        let ids = result["scenes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        guard ids.count == storyboard.scenes.count, Set(ids) == Set(storyboard.scenes.map(\.id)) else { throw SubscriptionNarratorError.unreadable }
        let envelope = answer.split(separator: "\n").reversed().compactMap { try? JSONCoding.decoder.decode(JSONValue.self, from: Data($0.utf8)) }.first
        let reportedModel = diagnostics.split(separator: "\n").first(where: { $0.hasPrefix("model:") }).map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        let safeModel = reportedModel.flatMap { value in value.count < 100 && value.allSatisfy { $0.isLetter || $0.isNumber || "-._/".contains($0) } ? value : nil }
        let model = envelope?["model"]?.stringValue ?? envelope?["modelUsage"]?.objectValue?.keys.sorted().first ?? safeModel
        return try Narrator.apply(result, writer: model ?? "\(provider.title) (your subscription)", bundle: bundle, storyboard: storyboard, options: options)
    }
}
