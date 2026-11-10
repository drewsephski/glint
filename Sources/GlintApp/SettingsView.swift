import SwiftUI
import GlintCore

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
                Text("Narration").font(.system(size: 15, weight: .semibold))
                Hint("Writing a script sends scene frames and on-screen text to Anthropic. Generating a voice sends the script to ElevenLabs. Everything else runs on this Mac.")
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
        .frame(width: 480)
        .background(Theme.panel)
        .onAppear { elevenlabs = Secrets.get(.elevenlabs) ?? ""; anthropic = Secrets.get(.anthropic) ?? "" }
    }

    func keyField(_ k: Secrets.Key, value: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(k.title) API key").font(.system(size: 12, weight: .medium))
                Spacer()
                if let src = Secrets.source(k) {
                    Text(src == "environment" ? "from \(k.environment)" : src == "keychain" ? "in Keychain" : "saved").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
            }
            SecureField("", text: value).textFieldStyle(.roundedBorder).disabled(Secrets.source(k) == "environment")
            Hint(hint)
        }
    }

    func save() {
        do {
            if Secrets.source(.elevenlabs) != "environment" { try Secrets.set(.elevenlabs, elevenlabs) }
            if Secrets.source(.anthropic) != "environment" { try Secrets.set(.anthropic, anthropic) }
            saved = "Saved"; error = nil
        } catch { self.error = "\(error)" }
    }
}
