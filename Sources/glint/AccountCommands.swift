import Foundation
import ArgumentParser
import GlintAgent

struct Account: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage vendor CLI sign-in.", subcommands: [Status.self, Login.self, Logout.self, Use.self])
    static func provider(_ value: String) throws -> SubscriptionProvider {
        guard let p = SubscriptionProvider(rawValue: value.lowercased()) else { throw ValidationError("Choose claude or chatgpt.") }
        return p
    }
    struct Status: ParsableCommand {
        @Flag var json = false
        func run() throws {
            let rows = Subscriptions.statusAll().map { s -> [String: String] in
                let state: String
                switch s.state {
                case .notInstalled: state = "not-installed"
                case .signedOut: state = "signed-out"
                case .signedIn: state = "signed-in"
                case .expired: state = "expired"
                case .usingAPIKey: state = "api-key"
                case .unknown(let reason): state = "unknown: " + reason
                }
                return ["provider": s.provider.rawValue, "state": state, "account": s.account ?? "", "plan": s.plan ?? "", "preferred": Subscriptions.preferred == s.provider ? "yes" : "no"]
            }
            if json { print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); return }
            let keys = ["provider", "state", "account", "plan", "preferred"]
            let widths = keys.map { key in max(key.count, rows.map { $0[key]!.count }.max() ?? 0) + 2 }
            for row in [Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })] + rows {
                print(zip(keys, widths).map { row[$0.0]!.padding(toLength: $0.1, withPad: " ", startingAt: 0) }.joined())
            }
        }
    }
    struct Login: ParsableCommand {
        @Argument var provider: String?
        func run() throws {
            let p: SubscriptionProvider
            if let provider { p = try Account.provider(provider) }
            else {
                let installed = SubscriptionProvider.allCases.filter { $0.chatAgent.cliPath != nil }
                if installed.count == 1 { p = installed[0] }
                else { print("Provider (claude/chatgpt):", terminator: " "); guard let value = readLine() else { throw ValidationError("Choose a provider.") }; p = try Account.provider(value) }
            }
            let state = AccountLoginState()
            let flow = SubscriptionSignIn(provider: p) { event in state.receive(event) }
            let previous = signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler { flow.cancel() }; source.resume()
            defer { source.cancel(); signal(SIGINT, previous) }
            try flow.start()
            while true {
                switch state.next() {
                case .openedBrowser(let url): print(url?.absoluteString ?? "Finish sign-in in your browser.")
                case .needsCode:
                    print("Paste the code:")
                    DispatchQueue.global().async { if let code = readLine() { flow.submit(code: code) } else { flow.cancel() } }
                case .finished: print("Signed in with \(p.title)."); return
                case .failed(let reason): throw ValidationError(reason)
                }
            }
        }
    }
    struct Logout: ParsableCommand {
        @Argument var provider: String
        @Flag var yes = false
        func run() throws {
            let p = try Account.provider(provider)
            if !yes { print("Sign out of \(p.title)? [y/N]", terminator: " "); guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { return } }
            try Subscriptions.signOut(p); print("Signed out of \(p.title).")
        }
    }
    struct Use: ParsableCommand {
        @Argument var provider: String
        func run() throws {
            let p = try Account.provider(provider)
            guard Subscriptions.status(p).isUsable else { throw ValidationError("Sign in with \(p.title) first.") }
            Subscriptions.preferred = p
            guard Subscriptions.preferred == p else { throw ValidationError("Couldn't save the preferred provider.") }
            print("Using \(p.title).")
        }
    }
}
private final class AccountLoginState: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [SubscriptionSignIn.Event] = []
    func receive(_ event: SubscriptionSignIn.Event) { condition.lock(); events.append(event); condition.signal(); condition.unlock() }
    func next() -> SubscriptionSignIn.Event {
        condition.lock(); defer { condition.unlock() }
        while events.isEmpty { condition.wait() }
        return events.removeFirst()
    }
}
