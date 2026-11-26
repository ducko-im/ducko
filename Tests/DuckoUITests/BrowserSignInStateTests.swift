import DuckoCore
import Testing
@testable import DuckoUI

private struct OtherError: Error {}

struct BrowserSignInClientIDPromptTests {
    @Test(arguments: [
        (SSOError.clientIDRequired(issuer: "https://auth.example.com"), BrowserSignInClientIDPrompt.required(issuer: "https://auth.example.com")),
        (.cancelled, .optional),
        (.timedOut, .optional),
        (.authorizationDenied, .optional)
    ])
    func `a sign-in the client ID can fix asks for one`(error: SSOError, prompt: BrowserSignInClientIDPrompt) {
        #expect(BrowserSignInClientIDPrompt(error) == prompt)
    }

    @Test(arguments: [
        SSOError.serverUnsupported, .registrationUnavailable, .browserUnavailable, .grantInvalid, .providerUnreachable,
        .malformedResponse, .storeFailed
    ])
    func `other sign-in failures ask for no client ID`(error: SSOError) {
        #expect(BrowserSignInClientIDPrompt(error) == nil)
    }

    @Test func `a failure outside sign-in through the browser asks for no client ID`() {
        #expect(BrowserSignInClientIDPrompt(OtherError()) == nil)
    }
}

@MainActor
struct BrowserSignInStateTests {
    @Test func `an empty client ID field passes none`() async {
        let state = BrowserSignInState()
        var passed: String?? = .none
        await state.signIn { passed = $0 }
        #expect(passed == .some(nil))
    }

    @Test func `a required client ID keeps the typed value`() async {
        let state = BrowserSignInState()
        state.clientID = "ducko"
        await state.signIn { _ in throw SSOError.clientIDRequired(issuer: "https://auth.example.com") }
        #expect(state.clientIDPrompt == .required(issuer: "https://auth.example.com"))
        #expect(state.clientID == "ducko")
        #expect(state.errorMessage == SSOError.clientIDRequired(issuer: "https://auth.example.com").localizedDescription)
        #expect(!state.isSigningIn)
    }

    @Test(arguments: [SSOError.cancelled, .timedOut, .authorizationDenied])
    func `a sign-in that did not complete empties the client ID`(error: SSOError) async {
        let state = BrowserSignInState()
        state.clientID = "retired"
        var passed: String?
        await state.signIn { clientID in
            passed = clientID
            throw error
        }
        #expect(passed == "retired")
        #expect(state.clientIDPrompt == .optional)
        #expect(state.clientID.isEmpty)
        #expect(state.errorMessage == error.localizedDescription)
    }

    @Test func `a superseded sign-in shows nothing`() async {
        let state = BrowserSignInState()
        await state.signIn { _ in throw SSOError.clientIDRequired(issuer: "https://auth.example.com") }
        state.clientID = "ducko"
        await state.signIn { _ in throw CancellationError() }
        #expect(state.errorMessage == nil)
        #expect(state.clientIDPrompt == .required(issuer: "https://auth.example.com"))
        #expect(state.clientID == "ducko")
        #expect(!state.isSigningIn)
    }

    @Test func `a completed sign-in hides the client ID field`() async {
        let state = BrowserSignInState()
        await state.signIn { _ in throw SSOError.cancelled }
        await state.signIn { _ in }
        #expect(state.clientIDPrompt == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func `a reset clears the failure, the client ID field and the typed client ID`() async throws {
        let state = BrowserSignInState()
        state.clientID = "ducko"
        await state.signIn { _ in throw SSOError.clientIDRequired(issuer: "https://auth.example.com") }
        try #require(state.errorMessage != nil && state.clientIDPrompt != nil && state.clientID == "ducko")

        state.reset()

        #expect(state.errorMessage == nil)
        #expect(state.clientIDPrompt == nil)
        #expect(state.clientID.isEmpty)
    }

    @Test func `the sign-in is in progress while it runs`() async {
        let state = BrowserSignInState()
        var wasSigningIn = false
        await state.signIn { _ in wasSigningIn = state.isSigningIn }
        #expect(wasSigningIn)
        #expect(!state.isSigningIn)
    }
}

struct AccountPortFieldTests {
    @Test(arguments: ["", "1", "5222", "65535"])
    func `an empty field or a port in range is valid`(text: String) {
        #expect(AccountPortField.isValid(text))
    }

    @Test(arguments: ["0", "65536", "-1", "99999999999999999999", "52 22", "port"])
    func `anything else is invalid`(text: String) {
        #expect(!AccountPortField.isValid(text))
    }
}
