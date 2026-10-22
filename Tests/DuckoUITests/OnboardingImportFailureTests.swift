import DuckoXMPP
import Testing
@testable import DuckoUI

struct OnboardingImportFailureTests {
    @Test
    func `only a rejected password asks for the password again`() {
        let rejected = XMPPClientError.authenticationFailed(AuthenticationFailure(kind: .credentialsRejected, message: "Incorrect username or password"))
        #expect(OnboardingImportFailure.classify(rejected) == .credentialsRejected)
    }

    @Test(arguments: [
        XMPPClientError.authenticationFailed(AuthenticationFailure(kind: .other, message: "The account is disabled")),
        .authenticationFailed(AuthenticationFailure(kind: .temporary, message: "Temporary server failure, try again later")),
        .untrustedCertificate(.notTrusted)
    ])
    func `any other sign-in failure lists the account as failed with its reason`(error: XMPPClientError) {
        #expect(OnboardingImportFailure.classify(error) == .failed(error.localizedDescription))
    }
}
