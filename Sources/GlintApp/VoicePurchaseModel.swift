import SwiftUI
import AppKit
import GlintCore
import GlintAnalysis

@MainActor @Observable
final class VoicePurchaseModel {
    static let shared = VoicePurchaseModel()
    private(set) var remaining = 0
    private(set) var purchased = false
    private(set) var busy = false
    var error: String?
    var message: String?
    var checkoutOpened = false
    var credentialsRevision = 0
    var hasAccess: Bool { remaining > 0 }
    var configured: Bool { HostedVoice.baseURL != nil }

    func refresh(reconcile: Bool = false) async {
        guard !busy else { return }
        guard configured, Secrets.get(.voiceAccess) != nil else { remaining = 0; purchased = false; return }
        busy = true
        defer { busy = false }
        do {
            let access = try await HostedVoice.access(reconcile: reconcile)
            let balanceIncreased = access.remaining > remaining
            remaining = access.remaining; purchased = access.purchased; error = nil
            if balanceIncreased { checkoutOpened = false }
            if reconcile {
                message = access.purchased && !checkoutOpened ? "Your balance is up to date." : "Payment hasn’t completed yet. Finish checkout, then check again."
            }
        } catch { self.error = "\(error)" }
    }

    func buy() async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            if Secrets.get(.voiceAccess) == nil { try Secrets.set(.voiceAccess, HostedVoice.makeAccessCode()) }
            let url = try await HostedVoice.checkout()
            guard NSWorkspace.shared.open(url) else { throw VoiceError.badResponse("Your browser could not open checkout. Please try again.") }
            checkoutOpened = true
        } catch { self.error = "\(error)" }
    }

    func restore(_ value: String) async {
        guard !busy else { return }
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedVoice.validAccessCode(code) else { error = "Paste the recovery code you saved from Glint."; return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let access = try await HostedVoice.access(code: code, reconcile: true)
            guard access.purchased else { error = "No completed purchase was found for this code."; return }
            try Secrets.set(.voiceAccess, code)
            credentialsRevision += 1
            remaining = access.remaining; purchased = true
            message = "Purchase restored."
        } catch { self.error = "\(error)" }
    }

    func copyRecoveryCode() {
        guard let code = Secrets.get(.voiceAccess) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        message = "Recovery code copied. Keep it private; it gives access to your balance."
    }
}
