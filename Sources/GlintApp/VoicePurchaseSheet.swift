import SwiftUI

struct VoicePurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var purchase = VoicePurchaseModel.shared
    @State private var recoveryCode = ""
    @State private var showRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "waveform").font(.system(size: 24)).foregroundStyle(Theme.accent)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Give your video a voice").font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                Text("Natural ElevenLabs narration, ready to use in Glint.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("$29").font(.system(size: 34, weight: .semibold))
                    Text("USD · one time").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Text("50,000 characters").font(.system(size: 15, weight: .semibold))
                Text("Roughly an hour of narration. No subscription or API key needed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if purchase.purchased {
                    Text("\(purchase.remaining.formatted()) characters remaining").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).surface()
            VStack(alignment: .leading, spacing: 10) {
                Button { Task { await purchase.buy() } } label: {
                    HStack {
                        Spacer()
                        Text(purchase.checkoutOpened ? "Return to Checkout" : purchase.purchased ? "Add 50,000 Characters — $29" : "Get Voiceover — $29")
                        if purchase.busy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(purchase.busy || !purchase.configured)
                Hint("Only generated text uses characters, including new takes. Your script is sent to Glint’s voice service and ElevenLabs.")
                if !purchase.configured { Hint("Purchases aren’t available in this build. You can still use your own key below.") }
                if purchase.checkoutOpened {
                    Button("Check Purchase") { Task { await purchase.refresh(reconcile: true) } }
                        .buttonStyle(GhostButtonStyle()).disabled(purchase.busy)
                }
                if let error = purchase.error { InlineError(text: error) }
                if let message = purchase.message { Hint(message) }
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Button("Use My ElevenLabs Key") {
                    dismiss(); SettingsTab.select(.narration); openSettings()
                }.buttonStyle(LinkButtonStyle())
                Spacer()
                Button("Restore Purchase") { showRestore.toggle() }.buttonStyle(LinkButtonStyle())
            }
            if showRestore {
                HStack {
                    SecureField("Recovery code", text: $recoveryCode).accessibilityLabel("Purchase recovery code")
                    Button("Restore") { Task { await purchase.restore(recoveryCode) } }
                        .disabled(purchase.busy || recoveryCode.isEmpty || !purchase.configured)
                }
            }
            if purchase.purchased || purchase.checkoutOpened {
                Button("Copy Recovery Code") { purchase.copyRecoveryCode() }.buttonStyle(LinkButtonStyle())
                Hint("Save this code to restore your balance on another Mac.")
            }
            if purchase.hasAccess {
                Button("Done") { dismiss() }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(28).frame(width: 460).background(Theme.canvas)
        .task { await purchase.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await purchase.refresh(reconcile: purchase.checkoutOpened) }
        }
    }
}
