import SwiftUI
import GlintCore
import GlintAgent

/// Settings: one Account tab for Claude and ChatGPT (sign-in, and using Glint inside their own apps) plus what this
/// Mac needs, and a Narration tab for the voice.
struct SettingsRoot: View {
    let agents: AgentsModel
    let accounts: AccountsModel
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.account.rawValue

    var body: some View {
        TabView(selection: $tab) {
            AccountSettings(model: accounts, agents: agents)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account.rawValue)
            SettingsView(accounts: accounts)
                .tabItem { Label("Narration", systemImage: "waveform") }.tag(SettingsTab.narration.rawValue)
        }
        .frame(width: 640, height: 600)
        .background(Theme.canvas)
    }
}

/// Who is signed in, with reconnect and sign-out, and what the sign-in is used for.
struct AccountSettings: View {
    let model: AccountsModel
    let agents: AgentsModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Account").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                        if model.loaded {
                            StatusPill(text: model.active.map { "Using \($0.title)" } ?? "Not signed in", tint: model.active == nil ? Theme.text3 : Theme.ok)
                        }
                    }
                    Text("Glint works through the Claude or ChatGPT subscription you already have. It writes narration and edits with you in chat, and counts against that plan's usual limits.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                AccountsCard(model: model, apps: agents)
                if model.usable.count > 1 {
                    Hint("Both are signed in. Glint uses the one marked In use; pick the other with Use.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    fact("lock", "You sign in on Claude's or ChatGPT's own page. Glint never sees your password and stores no sign-in of its own; \(SubscriptionProvider.claude.toolTitle) and \(SubscriptionProvider.chatgpt.toolTitle) keep it.")
                    fact("arrow.up.right", "Writing a script sends scene frames and on-screen text to the account in use. Chat sends your messages and what the tools return. Recording, editing and rendering stay on this Mac.")
                    fact("key", "Prefer an API key? Add one under Narration. It is only used when no account is signed in.")
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
                MacSetupPanel(model: agents).padding(.top, 4)
            }
            .padding(22)
        }
        .background(Theme.canvas)
        .onAppear {
            model.refresh(force: true)
            // An older build may have left the removed Agents tab selected.
            if SettingsTab(rawValue: UserDefaults.standard.string(forKey: SettingsTab.key) ?? "") == nil { SettingsTab.select(.account) }
        }
    }

    func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 14).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The voice service's key, and an Anthropic key as the alternative to signing in. Keys live in the macOS Keychain
/// (release builds) or a 0600 file (development builds), or come from the environment; agents can't read them through
/// tools.
struct SettingsView: View {
    let accounts: AccountsModel
    @State private var elevenlabs = ""
    @State private var anthropic = ""
    @State private var saved: String?
    @State private var error: String?
    @State private var showAnthropic = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Narration").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    Text("The script is written through your Claude or ChatGPT account. The voice is synthesized by ElevenLabs, which needs its own key. Everything else runs on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                scriptWriter
                keyField(.elevenlabs, title: "Voice: ElevenLabs API key", value: $elevenlabs, hint: "Synthesizes the voice. elevenlabs.io, Profile, API keys.")
                DisclosureGroup(isExpanded: $showAnthropic) {
                    keyField(.anthropic, title: "Anthropic API key", value: $anthropic,
                             hint: "Only used to write the script when no account is signed in. Billed per use by Anthropic. console.anthropic.com, API keys.")
                        .padding(.top, 8)
                } label: {
                    Text("Use an API key instead of signing in").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                }
                HStack {
                    if let saved { Label(saved, systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.ok) }
                    if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.cut).fixedSize(horizontal: false, vertical: true) }
                    Spacer()
                    Button("Save Keys") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(!changed)
                }
                Hint("Keys are stored in \(Secrets.storeDescription), never inside the app. Environment variables ELEVENLABS_API_KEY and ANTHROPIC_API_KEY take precedence.")
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .onAppear {
            elevenlabs = Secrets.get(.elevenlabs) ?? ""
            anthropic = Secrets.get(.anthropic) ?? ""
            showAnthropic = !anthropic.isEmpty
        }
    }

    var changed: Bool { elevenlabs != (Secrets.get(.elevenlabs) ?? "") || anthropic != (Secrets.get(.anthropic) ?? "") }

    /// Which of the three ways will write the next script.
    var scriptWriter: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: "text.alignleft")
            VStack(alignment: .leading, spacing: 3) {
                Text("Script writer").font(.system(size: 13, weight: .semibold))
                Text(writerText).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if accounts.active == nil {
                Button("Sign In…") { SettingsTab.select(.account) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14).surface()
    }

    var writerText: String {
        if let a = accounts.active { return "\(a.title), through your subscription." }
        if Secrets.get(.anthropic) != nil { return "Claude, through your Anthropic API key. Sign in to use your subscription instead." }
        return accounts.loaded ? "Nobody yet. Sign in with Claude or ChatGPT, or type the lines yourself in the Voice tab."
                               : "Checking your account…"
    }

    func keyField(_ k: Secrets.Key, title: String, value: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let src = Secrets.source(k) {
                    StatusPill(text: src == "environment" ? "From \(k.environment)" : src == "keychain" ? "In Keychain" : "Saved", tint: Theme.ok)
                }
            }
            SecureField("Paste a key", text: value).textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                .disabled(Secrets.source(k) == "environment")
                .accessibilityLabel(title)
                .onChange(of: value.wrappedValue) { _, _ in saved = nil }
            Hint(hint)
        }
        .padding(14).surface()
    }

    func save() {
        do {
            if Secrets.source(.elevenlabs) != "environment" { try Secrets.set(.elevenlabs, elevenlabs.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if Secrets.source(.anthropic) != "environment" { try Secrets.set(.anthropic, anthropic.trimmingCharacters(in: .whitespacesAndNewlines)) }
            saved = "Saved"; error = nil
        } catch { self.error = "\(error)"; saved = nil }
    }
}
