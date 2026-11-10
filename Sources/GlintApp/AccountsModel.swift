import SwiftUI
import AppKit
import GlintCore
import GlintAgent

/// The person's Claude and ChatGPT sign-ins: what Glint uses for chat and for writing narration.
///
/// Glint never holds a password or a token. Claude Code and Codex keep the sign-in; this model asks them whether one
/// exists, starts their sign-in page in the browser, and signs out through them. Checks shell out, so they run off the
/// main thread.
@MainActor @Observable
final class AccountsModel {
    static let shared = AccountsModel()

    enum SignInPhase: Equatable { case starting, browser(URL?), needsCode }
    struct Message: Equatable { var text: String; var isError: Bool }

    private(set) var statuses: [SubscriptionStatus] = []
    private(set) var loaded = false
    /// The account the person picked when both are signed in.
    private(set) var preferred: SubscriptionProvider?
    private(set) var signingIn: SubscriptionProvider?
    private(set) var phase: SignInPhase?
    private(set) var busy: Set<SubscriptionProvider> = []
    var messages: [SubscriptionProvider: Message] = [:]
    /// The code the browser shows, when a sign-in asks for one.
    var code = ""

    private(set) var installing: SubscriptionProvider?
    private(set) var installProgress: String?
    private var installTask: Task<Void, Never>?
    private var run: SubscriptionSignIn?
    private var cancelled = false
    /// Bumped by every refresh and every sign-in or sign-out, so a slow, older check can't overwrite newer state.
    private var generation = 0
    private var lastRefresh = Date.distantPast
    private var observer: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?

    init() {
        // People also sign in from a terminal or the vendor's app: pick that up when they come back to Glint.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A sign-in left waiting on the browser must not outlive Glint.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.run?.cancel(); self?.installTask?.cancel() }
        }
        refresh(force: true)
    }

    func status(_ p: SubscriptionProvider) -> SubscriptionStatus? { statuses.first { $0.provider == p } }
    func isUsable(_ p: SubscriptionProvider) -> Bool { status(p)?.isUsable == true }
    var usable: [SubscriptionProvider] { statuses.filter(\.isUsable).map(\.provider) }
    var hasUsable: Bool { !usable.isEmpty }

    /// The account in use: the chosen one while it works, otherwise whichever is signed in.
    var active: SubscriptionProvider? {
        if let p = preferred, isUsable(p) { return p }
        return usable.first
    }

    func refresh(force: Bool = false) {
        guard signingIn == nil, installing == nil, busy.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 4 else { return }
        lastRefresh = Date()
        generation += 1
        let gen = generation
        Task.detached {
            let all = Subscriptions.statusAll()
            let chosen = Subscriptions.preferred
            await MainActor.run {
                guard gen == self.generation else { return }
                self.statuses = all
                self.preferred = chosen
                self.loaded = true
            }
        }
    }

    /// A chat turn or a script failed: if it reads like a lost sign-in, check again so the rows offer Reconnect.
    func noteFailure(_ text: String) {
        if SubscriptionProvider.allCases.contains(where: { Subscriptions.authIssue(in: text, provider: $0) != nil }) { refresh(force: true) }
    }

    func signIn(_ p: SubscriptionProvider) {
        guard signingIn == nil, installing == nil, busy.isEmpty else { return }
        messages[p] = nil
        code = ""
        cancelled = false
        signingIn = p
        phase = .starting
        generation += 1
        let r = SubscriptionSignIn(provider: p) { [weak self] e in
            Task { @MainActor in self?.handle(e, provider: p) }
        }
        run = r
        do { try r.start() } catch {
            endSignIn()
            messages[p] = Message(text: "\(error)", isError: true)
        }
    }

    func install(_ provider: SubscriptionProvider) {
        guard signingIn == nil, installing == nil, busy.isEmpty else { return }
        installing = provider
        installProgress = "Preparing installation…"
        messages[provider] = nil
        generation += 1
        installTask = Task {
            do {
                try await SubscriptionInstaller.install(provider) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.installing == provider, self.installTask?.isCancelled == false else { return }
                        self.installProgress = message
                    }
                }
                try Task.checkCancellation()
                installing = nil; installTask = nil; installProgress = nil
                refresh(force: true)
                signIn(provider)
            } catch {
                let cancelled = Task.isCancelled
                installing = nil; installTask = nil; installProgress = nil
                messages[provider] = Message(text: cancelled ? "Installation cancelled. You can retry when you're ready." : "\(error)", isError: !cancelled)
                refresh(force: true)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installProgress = "Cancelling installation…"
    }

    func submitCode() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        run?.submit(code: c)
        code = ""
        phase = .browser(nil)
    }

    func cancelSignIn() {
        cancelled = true
        run?.cancel()
    }

    private func endSignIn() {
        run = nil
        signingIn = nil
        phase = nil
        code = ""
    }

    private func handle(_ e: SubscriptionSignIn.Event, provider p: SubscriptionProvider) {
        guard signingIn == p else { return }
        switch e {
        case .openedBrowser(let url):
            phase = .browser(url)
        case .needsCode:
            phase = .needsCode
        case .finished(let s):
            endSignIn()
            replace(s)
            // The first account signed in becomes the one in use; a second one doesn't take over.
            if active == p || preferred == nil { choose(p) }
        case .failed(let why):
            endSignIn()
            if !cancelled { messages[p] = Message(text: why, isError: true) }
            refresh(force: true)
        }
    }

    func signOut(_ p: SubscriptionProvider) {
        guard !busy.contains(p), signingIn == nil, installing == nil else { return }
        busy.insert(p)
        messages[p] = nil
        generation += 1
        Task.detached {
            let failure: String?
            do { try Subscriptions.signOut(p); failure = nil } catch { failure = "\(error)" }
            let s = Subscriptions.status(p)
            await MainActor.run {
                self.busy.remove(p)
                self.replace(s)
                if let failure { self.messages[p] = Message(text: failure, isError: true) }
            }
        }
    }

    /// Use this account for chat and narration.
    func choose(_ p: SubscriptionProvider) {
        preferred = p
        UserDefaults.standard.set(p.chatAgent.rawValue, forKey: "GlintChatAgent")
        Task.detached { Subscriptions.preferred = p }
    }

    private func replace(_ s: SubscriptionStatus) {
        if let i = statuses.firstIndex(where: { $0.provider == s.provider }) { statuses[i] = s } else { statuses.append(s) }
        loaded = true
    }
}

extension SubscriptionProvider {
    var symbol: String { self == .claude ? "text.bubble" : "bubble.left.and.bubble.right" }
}

/// Which Settings tab opens. Set before opening Settings to land on the right one.
enum SettingsTab: String {
    case account, narration
    static let key = "GlintSettingsTab"
    static func select(_ t: SettingsTab) { UserDefaults.standard.set(t.rawValue, forKey: key) }
}

// MARK: - Views

/// One account: who is signed in, and the single next step (sign in, reconnect, install). Used in setup, Settings,
/// Home, and wherever a feature needs an account.
struct AccountRow: View {
    @Bindable var model: AccountsModel
    let provider: SubscriptionProvider
    /// Tighter, for sidebars.
    var compact = false
    /// Sign In is the screen's main action (setup, Settings). Off where another action leads, like Record on Home.
    var prominent = true
    @State private var confirmSignOut = false
    @State private var showInstall = false

    var body: some View {
        let status = model.status(provider)
        let signingIn = model.signingIn == provider
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: compact ? 9 : 12) {
                IconTile(systemName: provider.symbol, size: compact ? 26 : 32, tint: status?.isUsable == true ? Theme.accent : Theme.text2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(provider.title).font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                        if !signingIn, let (text, tint) = pill(status) { StatusPill(text: text, tint: tint) }
                    }
                    Text(detail(status, signingIn: signingIn)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing(status, signingIn: signingIn)
            }
            if signingIn { progress }
            if model.installing == provider { WorkingRow(text: model.installProgress ?? "Installing…") }
            if case .notInstalled = status?.state {
                Button("Installation help") { NSWorkspace.shared.open(provider.installURL) }.buttonStyle(LinkButtonStyle())
            }
            if let m = model.messages[provider] {
                Label(m.text, systemImage: m.isError ? "exclamationmark.circle" : "checkmark")
                    .font(.system(size: 11)).foregroundStyle(m.isError ? Theme.cut : Theme.text2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, compact ? 3 : 13)
        .animation(.smooth(duration: 0.25), value: status)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .accessibilityElement(children: .contain)
        .confirmationDialog("Install \(provider.toolTitle)?", isPresented: $showInstall, titleVisibility: .visible) {
            Button("Install and Sign In") { model.install(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Glint downloads and runs the official \(provider.title) installer for your Mac, then opens sign-in. No terminal or administrator password is needed.")
        }
        .confirmationDialog("Sign out of \(provider.title)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs \(provider.toolTitle) out on this Mac, including in your terminal. Your projects stay as they are.")
        }
    }

    func pill(_ s: SubscriptionStatus?) -> (String, Color)? {
        switch s?.state {
        case .signedIn: (model.active == provider ? "Selected" : "Signed in", Theme.ok)
        case .usingAPIKey: (model.active == provider ? "Selected" : "API key", Theme.ok)
        case .expired: ("Sign-in expired", Theme.speed)
        case .unknown: ("Couldn't check", Theme.speed)
        case .signedOut, .notInstalled, nil: nil
        }
    }

    func detail(_ s: SubscriptionStatus?, signingIn: Bool) -> String {
        if signingIn {
            switch model.phase {
            case .needsCode: return "Paste the code your browser shows."
            case .browser: return "Finish signing in in your browser. This updates on its own."
            default: return "Opening the sign-in page…"
            }
        }
        guard let s else { return "Checking…" }
        switch s.state {
        case .notInstalled:
            return "Needs \(provider.toolTitle), the free tool \(provider.title) signs in through. Glint can install it for you."
        case .signedOut:
            return "Use the \(provider.title) plan you already pay for. Sign-in opens in your browser."
        case .signedIn:
            let who = [s.account, s.plan.map { "\($0.capitalized) plan" }].compactMap { $0 }.joined(separator: " · ")
            return who.isEmpty ? "Using your \(provider.title) subscription." : who
        case .expired:
            return "Your sign-in ran out. Reconnect to keep using \(provider.title)."
        case .usingAPIKey:
            return "\(provider.toolTitle) is set up with an API key, so use is billed to that key rather than a subscription."
        case .unknown(let why):
            return why
        }
    }

    @ViewBuilder func trailing(_ s: SubscriptionStatus?, signingIn: Bool) -> some View {
        if model.installing == provider {
            Button("Cancel") { model.cancelInstall() }.buttonStyle(GhostButtonStyle())
        } else if signingIn {
            Button("Cancel") { model.cancelSignIn() }.buttonStyle(GhostButtonStyle())
        } else if model.busy.contains(provider) || s == nil {
            ProgressView().controlSize(.small)
        } else if let s {
            let locked = model.signingIn != nil || model.installing != nil || !model.busy.isEmpty
            switch s.state {
            case .notInstalled:
                Button("Install \(provider.toolTitle)…") { showInstall = true }.buttonStyle(GhostButtonStyle()).disabled(locked)
            case .signedOut:
                // One primary action at a time: the second account is secondary once one works.
                if model.hasUsable || !prominent { Button("Sign In") { model.signIn(provider) }.buttonStyle(GhostButtonStyle()).disabled(locked) }
                else { Button("Sign In") { model.signIn(provider) }.buttonStyle(PrimaryButtonStyle()).disabled(locked) }
            case .expired:
                Button("Reconnect") { model.signIn(provider) }.buttonStyle(PrimaryButtonStyle()).disabled(locked)
            case .unknown:
                Button("Check Again") { model.refresh(force: true) }.buttonStyle(GhostButtonStyle())
            case .signedIn, .usingAPIKey:
                HStack(spacing: 6) {
                    if model.usable.count > 1, model.active != provider {
                        Button("Select") { model.choose(provider) }.buttonStyle(GhostButtonStyle()).help("Use \(provider.title) for chat and narration")
                    }
                    Menu {
                        Button(s.state == .usingAPIKey ? "Sign In with a Subscription" : "Reconnect") { model.signIn(provider) }.disabled(locked)
                        Button("Check Again") { model.refresh(force: true) }
                        Divider()
                        Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                    } label: {
                        MenuChip(systemImage: "ellipsis")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Reconnect or sign out").accessibilityLabel("\(provider.title) account options")
                }
            }
        }
    }

    @ViewBuilder var progress: some View {
        switch model.phase {
        case .needsCode:
            HStack(spacing: 8) {
                TextField("Code from your browser", text: $model.code).textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                    .onSubmit { model.submitCode() }
                Button("Continue") { model.submitCode() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .browser(let url):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                Spacer(minLength: 8)
                if let url {
                    Button("Open the Page Again") { NSWorkspace.shared.open(url) }.buttonStyle(LinkButtonStyle())
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }.buttonStyle(LinkButtonStyle())
                }
            }
        default:
            WorkingRow(text: "Starting \(provider.toolTitle)…")
        }
    }
}

/// Both accounts in one panel.
struct AccountsCard: View {
    let model: AccountsModel
    var prominent = true
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SubscriptionProvider.allCases.enumerated()), id: \.element) { i, p in
                if i > 0 { Divider().overlay(Theme.hairline) }
                AccountRow(model: model, provider: p, prominent: prominent)
            }
        }
        .surface(radius: 14)
    }
}

/// Shown inside a feature that needs an account when none is signed in: what it's for, and both ways in.
struct SignInPrompt: View {
    let model: AccountsModel
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hint(text)
            ForEach(SubscriptionProvider.allCases) { p in AccountRow(model: model, provider: p, compact: true, prominent: false) }
        }
    }
}

/// Home's header: which account is in use, or the way to sign in. Opens Settings on the Account tab.
struct AccountChip: View {
    let model: AccountsModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("GlintAccountBannerDismissed") private var bannerDismissed = false
    var body: some View {
        // While the sign-in banner is showing right below, a second Sign In here would only repeat it.
        if model.loaded, model.active != nil || bannerDismissed {
            Button {
                SettingsTab.select(.account)
                openSettings()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(label)
                }
            }
            .buttonStyle(GhostButtonStyle())
            .help(model.active == nil ? "Sign in with your Claude or ChatGPT subscription" : "Account settings")
        }
    }

    var needsReconnect: Bool { model.statuses.contains { $0.state == .expired } && model.active == nil }
    var tint: Color { model.active != nil ? Theme.ok : needsReconnect ? Theme.speed : Theme.text3 }
    var label: String {
        if let a = model.active { return a.title }
        return needsReconnect ? "Reconnect" : "Sign In"
    }
}

/// On Home for anyone who hasn't signed in yet (including people who set Glint up before sign-in existed).
struct AccountBanner: View {
    let model: AccountsModel
    @AppStorage("GlintAccountBannerDismissed") private var dismissed = false
    var body: some View {
        if model.loaded, model.active == nil, !dismissed {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sign in with Claude or ChatGPT").font(.system(size: 15, weight: .semibold))
                        Text("Glint uses the subscription you already have to write narration and to edit with you in chat. No API keys.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                        .help("Hide. You can sign in later in Settings.").accessibilityLabel("Hide")
                }
                AccountsCard(model: model, prominent: false)
            }
        }
    }
}
