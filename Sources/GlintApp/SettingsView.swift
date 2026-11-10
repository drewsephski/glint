import SwiftUI
import GlintCore

/// Settings: connecting agents, and the narration API keys.
struct SettingsRoot: View {
    let agents: AgentsModel
    var body: some View {
        TabView {
            ScrollView { AgentsPanel(model: agents).padding(22) }
                .tabItem { Label("Agents", systemImage: "terminal") }
            SettingsView()
                .tabItem { Label("Narration", systemImage: "waveform") }
        }
        .frame(width: 640, height: 600)
        .background(Theme.canvas)
    }
}

/// API keys for the two cloud services. Keys live in the macOS Keychain (release builds) or a 0600 file (development
/// builds), or come from the environment; agents can't read them through tools.
struct SettingsView: View {
    @State private var elevenlabs = ""
    @State private var anthropic = ""
    @State private var saved: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Narration").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                Text("Writing a script sends scene frames and on-screen text to Anthropic. Generating a voice sends the script to ElevenLabs. Everything else runs on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
            keyField(.anthropic, value: $anthropic, hint: "Writes the narration (Claude). console.anthropic.com → API keys.")
            keyField(.elevenlabs, value: $elevenlabs, hint: "Synthesizes the voice. elevenlabs.io → Profile → API keys.")
            HStack {
                if let saved { Label(saved, systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.ok) }
                if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.cut) }
                Spacer()
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle())
            }
            Hint("Stored in \(Secrets.storeDescription), never inside the app. Environment variables ANTHROPIC_API_KEY and ELEVENLABS_API_KEY take precedence.")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .onAppear { elevenlabs = Secrets.get(.elevenlabs) ?? ""; anthropic = Secrets.get(.anthropic) ?? "" }
    }

    func keyField(_ k: Secrets.Key, value: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(k.title) API key").font(.system(size: 13, weight: .semibold))
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
            Hint(hint)
        }
        .padding(14).surface()
    }

    func save() {
        do {
            if Secrets.source(.elevenlabs) != "environment" { try Secrets.set(.elevenlabs, elevenlabs) }
            if Secrets.source(.anthropic) != "environment" { try Secrets.set(.anthropic, anthropic) }
            saved = "Saved"; error = nil
        } catch { self.error = "\(error)" }
    }
}
