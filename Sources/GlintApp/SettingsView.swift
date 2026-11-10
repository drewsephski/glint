import SwiftUI
import GlintCore
import GlintAgent

/// Account selection and optional narration services.
struct SettingsRoot: View {
    let agents: AgentsModel
    let accounts: AccountsModel
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.account.rawValue

    var body: some View {
        TabView(selection: $tab) {
            AccountSettings(model: accounts, agents: agents)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account.rawValue)
            SettingsView()
                .tabItem { Label("Narration", systemImage: "waveform") }.tag(SettingsTab.narration.rawValue)
        }
        .frame(width: 560, height: tab == SettingsTab.account.rawValue ? 340 : 440)
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
                    Text("Your AI account").font(.system(size: 20, weight: .semibold))
                    Text("Choose who helps you edit and write scripts.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                AccountsCard(model: model)
                Hint("Uses your existing subscription and its usage limits. Voice generation is separate, under Narration.")
                DisclosureGroup("Privacy & permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        fact("lock", "Sign-in is handled by Claude or ChatGPT. Glint never sees your password.")
                        fact("arrow.up.right", "Chat and script writing send messages, scene frames and on-screen text to your selected provider. Recording and export stay on this Mac.")
                        MacSetupPanel(model: agents)
                    }.padding(.top, 10)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
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
    @State private var elevenlabs = ""
    @State private var anthropic = ""
    @State private var saved: String?
    @State private var error: String?
    @State private var showAnthropic = false
    @State private var showPurchase = false
    @State private var purchase = VoicePurchaseModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice & narration").font(.system(size: 20, weight: .semibold))
                    Text("Add a voice to your script with Glint or your own ElevenLabs key.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    IconTile(systemName: "waveform")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Glint Voiceover").font(.system(size: 13, weight: .semibold))
                        Text(purchase.purchased ? "\(purchase.remaining.formatted()) characters remaining" : "$29 once · 50,000 characters")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button(purchase.purchased ? "Manage…" : "View Options…") { showPurchase = true }.buttonStyle(GhostButtonStyle())
                }.padding(14).surface()
                keyField(.elevenlabs, title: "Use your own ElevenLabs key", value: $elevenlabs, hint: "Optional. When saved, generation uses your ElevenLabs account instead of your Glint balance.")
                DisclosureGroup(isExpanded: $showAnthropic) {
                    keyField(.anthropic, title: "Anthropic API key", value: $anthropic,
                             hint: "Only used to write the script when no account is signed in. Billed per use by Anthropic. console.anthropic.com, API keys.")
                        .padding(.top, 8)
                } label: {
                    Text("Advanced: script-writing API key").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                }
                HStack {
                    if let saved { Label(saved, systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.ok) }
                    if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.cut).fixedSize(horizontal: false, vertical: true) }
                    Spacer()
                    Button("Save Keys") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(!changed)
                }
                Hint("Keys are saved securely on this Mac.")
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
        .task { await purchase.refresh() }
        .sheet(isPresented: $showPurchase) { VoicePurchaseSheet() }
    }

    var changed: Bool { elevenlabs != (Secrets.get(.elevenlabs) ?? "") || anthropic != (Secrets.get(.anthropic) ?? "") }

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
            purchase.credentialsRevision += 1
        } catch { self.error = "\(error)"; saved = nil }
    }
}
