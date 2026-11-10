import Foundation
import Testing
import GlintAnalysis

@Suite struct HostedVoiceTests {
    @Test func serviceURLsRequireHTTPSExceptLoopback() {
        #expect(HostedVoice.validatedBaseURL("https://voice.example.com") != nil)
        #expect(HostedVoice.validatedBaseURL("http://127.0.0.1:8787") != nil)
        #expect(HostedVoice.validatedBaseURL("http://voice.example.com") == nil)
        #expect(HostedVoice.validatedBaseURL("https://user:password@voice.example.com") == nil)
        #expect(HostedVoice.validatedBaseURL("https://voice.example.com?token=test") == nil)
        #expect(HostedVoice.validatedBaseURL("file:///tmp/service") == nil)
        #expect(HostedVoice.validatedBaseURL("https://voice.example.com/unexpected-path") == nil)
        #expect(HostedVoice.validatedBaseURL(nil) == nil)
    }

    @Test func recoveryCodesAreRandomAndStrictlyValidated() {
        let first = HostedVoice.makeAccessCode(), second = HostedVoice.makeAccessCode()
        #expect(first != second)
        #expect(HostedVoice.validAccessCode(first))
        #expect(HostedVoice.validAccessCode(second))
        #expect(!HostedVoice.validAccessCode("glint_paid"))
        #expect(!HostedVoice.validAccessCode(first + "\nextra"))
        #expect(!HostedVoice.validAccessCode(first + "\n"))
        #expect(!HostedVoice.validAccessCode("Bearer " + first))
    }
}
