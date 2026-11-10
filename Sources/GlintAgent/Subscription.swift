import Foundation
import AppKit
import GlintCore

public enum SubscriptionProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, chatgpt
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "ChatGPT" }
    public var toolTitle: String { chatAgent.title }
    public var chatAgent: ChatAgent { self == .claude ? .claudeCode : .codex }
    public init(_ agent: ChatAgent) { self = agent == .claudeCode ? .claude : .chatgpt }
    public var installURL: URL {
        URL(string: self == .claude ? "https://code.claude.com/docs/en/setup" : "https://developers.openai.com/codex/cli")!
    }
}

public struct SubscriptionStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled, signedOut, signedIn, expired, usingAPIKey
        case unknown(String)
    }
    public var provider: SubscriptionProvider
    public var state: State
    public var account: String?
    public var plan: String?
    public var cliPath: String?
    public var isUsable: Bool { state == .signedIn || state == .usingAPIKey }
}

public enum Subscriptions {
    private static let preferenceLock = NSLock()
    public static var preferred: SubscriptionProvider? {
        get {
            preferenceLock.withLock {
                guard let data = try? Data(contentsOf: preferenceURL) else { return nil }
                return try? JSONDecoder().decode(SubscriptionProvider.self, from: data)
            }
        }
        set {
            preferenceLock.withLock {
                do {
                    try FileManager.default.createDirectory(at: GlintPaths.support, withIntermediateDirectories: true)
                    if let newValue {
                        try JSONEncoder().encode(newValue).write(to: preferenceURL, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: preferenceURL.path) {
                        try FileManager.default.removeItem(at: preferenceURL)
                    }
                } catch {
                    // The required nonthrowing setter cannot surface filesystem errors to its caller.
                    NSLog("Glint could not save the subscription preference.")
                }
            }
        }
    }
    private static var preferenceURL: URL { GlintPaths.support.appendingPathComponent("subscription.json") }

    public static func active(_ statuses: [SubscriptionStatus]) -> SubscriptionProvider? {
        if let preferred, statuses.contains(where: { $0.provider == preferred && $0.isUsable }) { return preferred }
        return SubscriptionProvider.allCases.first { p in statuses.contains { $0.provider == p && $0.isUsable } }
    }

    public static func status(_ p: SubscriptionProvider) -> SubscriptionStatus { status(p, timeout: 10) }

    static func status(_ p: SubscriptionProvider, timeout: TimeInterval) -> SubscriptionStatus {
        guard let path = p.chatAgent.cliPath else { return .init(provider: p, state: .notInstalled) }
        do {
            let result = try ClaudeCLI.run(path, p == .claude ? ["auth", "status"] : ["login", "status"], timeout: timeout)
            return parseStatus(result.output, exitCode: result.status, provider: p, path: path)
        } catch {
            return .init(provider: p, state: .unknown("Couldn't check. Try again."), cliPath: path)
        }
    }

    public static func statusAll() -> [SubscriptionStatus] {
        let results = StatusResults()
        DispatchQueue.concurrentPerform(iterations: SubscriptionProvider.allCases.count) { i in
            results.set(status(SubscriptionProvider.allCases[i]), at: i)
        }
        return results.values
    }

    /// Parses only vendor status output; never opens credential files.
    static func parseStatus(_ text: String, exitCode: Int32, provider: SubscriptionProvider, path: String? = nil) -> SubscriptionStatus {
        var result = SubscriptionStatus(provider: provider, state: .unknown("Could not determine sign-in status."), cliPath: path)
        let lower = text.lowercased()
        if provider == .claude,
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let loggedIn = object["loggedIn"] as? Bool {
            let method = (object["authMethod"] as? String ?? "").lowercased()
            if loggedIn && method == "claude.ai" { result.state = .signedIn }
            else if loggedIn && ["api_key", "api_key_helper", "api-key", "apikey", "console"].contains(method) { result.state = .usingAPIKey }
            else if !loggedIn { result.state = object["storedClaudeAiLogin"] as? Bool == true ? .expired : .signedOut }
            result.account = object["email"] as? String
            result.plan = object["subscriptionType"] as? String
        } else if provider == .chatgpt {
            if exitCode == 0 && lower.contains("logged in using chatgpt") { result.state = .signedIn }
            else if exitCode == 0 && lower.contains("logged in using an api key") { result.state = .usingAPIKey }
            else if lower.contains("not logged in") { result.state = .signedOut }
        }
        if lower.contains("token has expired") || lower.contains("refresh token has already been used") || lower.contains("token has been revoked") {
            result.state = .expired
        }
        return result
    }

    public static func authIssue(in text: String, provider: SubscriptionProvider) -> String? {
        let lower = text.lowercased()
        let expired = ["token has expired", "token is expired", "token has been revoked", "refresh token has already been used", "refresh_token_reused", "authentication token has expired"]
        if expired.contains(where: lower.contains) { return "Your \(provider.title) sign-in has expired. Reconnect in Glint › Settings › Account." }
        let missing = ["not logged in", "please run /login", "please run claude auth login", "please run codex login", "authentication required", "invalid authentication credentials", "401 unauthorized", "invalid_api_key"]
        if missing.contains(where: lower.contains) { return "Sign in with \(provider.title) in Glint › Settings › Account." }
        return nil
    }
}

private final class StatusResults: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: SubscriptionStatus] = [:]
    func set(_ value: SubscriptionStatus, at index: Int) { lock.withLock { entries[index] = value } }
    var values: [SubscriptionStatus] { lock.withLock { entries.keys.sorted().compactMap { entries[$0] } } }
}

extension Subscriptions {
    public static func signOut(_ p: SubscriptionProvider) throws {
        guard let path = p.chatAgent.cliPath else { throw AgentSetupError("Install \(p.toolTitle) first.") }
        do {
            let result = try ClaudeCLI.run(path, p == .claude ? ["auth", "logout"] : ["logout"], timeout: 12)
            guard result.status == 0 else { throw AgentSetupError("Sign-out failed. Try again.") }
        } catch { throw AgentSetupError("Sign-out failed. Try again.") }
    }

    static func isUsageLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["usage limit", "rate limit", "rate_limit", "quota exceeded", "hit your limit"].contains(where: lower.contains)
    }

    /// Extract only a bounded time/date, never echo raw provider diagnostics (which may contain secrets).
    static func resetTime(in text: String) -> String? {
        let date = #"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)?"#
        let clock = #"\d{1,2}(?::\d{2})?\s*(?:am|pm)(?:\s*\([A-Za-z_+/-]+\))?"#
        let duration = #"\d+\s*(?:seconds?|minutes?|hours?)(?:\s+\d+\s*(?:seconds?|minutes?))?"#
        let calendar = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\s+\d{1,2}:\d{2}\s*(?:am|pm)"#
        let twentyFourHour = #"(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:UTC|GMT))?"#
        let pattern = "(?i)\\b(?:reset(?:s|ting)?\\s+(?:at\\s+|on\\s+)?|try again at\\s+)(" + date + "|" + calendar + "|" + clock + "|" + twentyFourHour + "|in\\s+" + duration + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func failureMessage(_ text: String, provider: SubscriptionProvider) -> String {
        if let issue = authIssue(in: text, provider: provider) { return issue }
        let lower = text.lowercased()
        if isUsageLimit(text) {
            let reset = resetTime(in: text).map { " Resets \($0)." } ?? " Try again after it resets."
            return "You've reached your \(provider.title) plan's usage limit." + reset
        }
        if ["network", "connection", "timed out", "fetch failed", "enotfound", "error sending request", "stream disconnected"].contains(where: lower.contains) {
            return "Couldn't connect to \(provider.title). Check your connection and try again."
        }
        return "\(provider.title) couldn't complete the request. Try again."
    }
}

/// A shell supervisor keeps job-control groups separate from Glint. Each supervisor
/// watches its owner, including across script's separate controlling-terminal session.
enum SubscriptionProcessTree {
    static let supervisor = """
    owner=$1
    shift
    set -m
    "$@" <&0 &
    child=$!
    cleanup() {
        trap '' TERM HUP INT
        kill -TERM -- -"$child" 2>/dev/null
        /bin/sleep 0.3
        kill -KILL -- -"$child" 2>/dev/null
        wait "$child" 2>/dev/null
    }
    trap 'cleanup; kill -KILL -- -"$watcher" 2>/dev/null; exit 143' TERM HUP INT
    (
        while kill -0 "$owner" 2>/dev/null; do /bin/sleep 0.2; done
        kill -TERM -- -"$child" 2>/dev/null
        /bin/sleep 0.3
        kill -KILL -- -"$child" 2>/dev/null
        kill -TERM "$$" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    watcher=$!
    if [ -t 0 ]; then fg %1; else wait "$child"; fi
    result=$?
    cleanup
    kill -KILL -- -"$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    exit "$result"
    """

    static func configure(_ process: Process, path: String, arguments: [String], terminal: Bool = false) {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var command = [path] + arguments
        if terminal {
            // script creates another session; supervise the vendor inside that session too.
            command = ["/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c",
                       "stty -echo; wrapper=$1; shift; exec /bin/sh -c \"$wrapper\" glint-inner \"$PPID\" \"$@\"",
                       "glint-terminal", supervisor] + command
        }
        process.arguments = ["-c", supervisor, "glint-supervisor", String(getpid())] + command
    }

    static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}

/// Owns only the CLI process and its transient terminal output, never credentials.
public final class SubscriptionSignIn: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case openedBrowser(URL?), needsCode, finished(SubscriptionStatus), failed(String)
    }
    private let provider: SubscriptionProvider
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "glint.sign-in")
    private let process = Process()
    private let input = Pipe()
    private var terminal = false
    private var started = false
    private var output = ""
    private var opened = false
    private var prompted = false
    private let timeout: TimeInterval
    public convenience init(provider: SubscriptionProvider, onEvent: @escaping @Sendable (Event) -> Void) {
        self.init(provider: provider, timeout: 300, onEvent: onEvent)
    }
    init(provider: SubscriptionProvider, timeout: TimeInterval, onEvent: @escaping @Sendable (Event) -> Void) {
        self.provider = provider; self.timeout = timeout; self.onEvent = onEvent
    }
    deinit { SubscriptionProcessTree.stop(process) }

    public func start() throws {
        try queue.sync {
            guard !started, !terminal else { return }
            guard let path = provider.chatAgent.cliPath, FileManager.default.isExecutableFile(atPath: path) else { throw AgentSetupError("Install \(provider.toolTitle) first.") }
            started = true
            // macOS script supplies a controlling terminal without creating a transcript.
            SubscriptionProcessTree.configure(process, path: path,
                arguments: provider == .claude ? ["auth", "login", "--claudeai"] : ["login"], terminal: true)
            let pipe = Pipe()
            process.standardInput = input
            process.standardOutput = pipe; process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                self?.queue.async { [weak self] in self?.consume(data) }
            }
            process.terminationHandler = { [weak self] p in
                guard let self else { return }
                self.queue.async {
                    guard !self.terminal else { return }
                    if p.terminationStatus != 0 { self.finish(.failed("Sign-in failed. Try again.")); return }
                    DispatchQueue.global().async {
                        let status = Subscriptions.status(self.provider)
                        self.queue.async {
                            self.finish(status.isUsable ? .finished(status) : .failed("Sign-in wasn't completed. Run login again and finish in your browser."))
                        }
                    }
                }
            }
            do { try process.run() } catch {
                finish(.failed("Couldn't start sign-in. Try again."))
                throw AgentSetupError("Couldn't start sign-in. Try again.")
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failed("Sign-in timed out. Try again."))
            }
        }
    }
    private func consume(_ data: Data) {
        guard !terminal else { return }
        output += String(decoding: data, as: UTF8.self)
        output = String(output.suffix(16384)).replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        if !opened, let range = output.range(of: "https://[^\\s<>\\\"\\u{001B}]+", options: .regularExpression), let url = URL(string: String(output[range])) {
            opened = true
            onEvent(.openedBrowser(url))
            if !output.lowercased().contains("opening") && !output.lowercased().contains("opened") {
                // Vendor auth links only; never open arbitrary links printed by an executable.
                let hosts = provider == .claude ? ["claude.ai", "console.anthropic.com", "platform.claude.com"] : ["auth.openai.com", "chatgpt.com"]
                if let host = url.host, hosts.contains(host) { _ = NSWorkspace.shared.open(url) }
            }
        }
        let lower = output.lowercased()
        if !prompted, lower.contains("code"), ["paste", "enter", "submit"].contains(where: lower.contains) {
            prompted = true; onEvent(.needsCode)
        }
    }
    public func submit(code: String) {
        queue.async {
            guard !self.terminal, self.started, !code.contains("\n"), !code.contains("\r") else { return }
            do { try self.input.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8)) }
            catch { self.finish(.failed("Couldn't send the code. Try signing in again.")) }
        }
    }
    public func cancel() { queue.async { self.finish(.failed("Sign-in cancelled.")) } }
    private func finish(_ event: Event) {
        guard !terminal else { return }
        terminal = true; output = ""
        SubscriptionProcessTree.stop(process)
        try? input.fileHandleForWriting.close()
        onEvent(event)
    }
}
