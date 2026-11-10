import Foundation
import Testing
@testable import GlintAgent

@Suite struct SubscriptionStatusTests {
    @Test func claudeStates() {
        let samples: [(String, SubscriptionStatus.State)] = [
            (#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#, .signedIn),
            (#"{"loggedIn":true,"authMethod":"api_key"}"#, .usingAPIKey),
            (#"{"loggedIn":false}"#, .signedOut),
            (#"{"loggedIn":false,"storedClaudeAiLogin":true}"#, .expired)
        ]
        for (sample, state) in samples {
            #expect(Subscriptions.parseStatus(sample, exitCode: 0, provider: .claude).state == state)
        }
    }
    @Test func accountMetadata() {
        let status = Subscriptions.parseStatus(#"{"loggedIn":true,"authMethod":"claude.ai","email":"test@example.com","subscriptionType":"max"}"#, exitCode: 0, provider: .claude)
        #expect(status.account == "test@example.com")
        #expect(status.plan == "max")
    }
    @Test func codexStates() {
        #expect(Subscriptions.parseStatus("Logged in using ChatGPT", exitCode: 0, provider: .chatgpt).state == .signedIn)
        #expect(Subscriptions.parseStatus("Logged in using an API key", exitCode: 0, provider: .chatgpt).state == .usingAPIKey)
        #expect(Subscriptions.parseStatus("Not logged in", exitCode: 1, provider: .chatgpt).state == .signedOut)
        #expect(Subscriptions.parseStatus("Your refresh token has already been used", exitCode: 1, provider: .chatgpt).state == .expired)
    }
    @Test func authMessagesAreSanitized() {
        for provider in SubscriptionProvider.allCases {
            #expect(Subscriptions.authIssue(in: "Not logged in · Please run /login SECRET", provider: provider)?.contains("SECRET") == false)
            #expect(Subscriptions.authIssue(in: "Your refresh token has already been used", provider: provider)?.contains("expired") == true)
            #expect(Subscriptions.authIssue(in: "Network connection failed", provider: provider) == nil)
            #expect(Subscriptions.authIssue(in: "Usage limit reached", provider: provider) == nil)
        }
    }
    @Test func unknownOutputDoesNotAuthenticate() {
        for provider in SubscriptionProvider.allCases {
            #expect(!Subscriptions.parseStatus("unexpected response", exitCode: 0, provider: provider).isUsable)
        }
    }
}
