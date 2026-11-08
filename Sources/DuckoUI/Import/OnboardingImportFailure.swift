import DuckoCore
import Foundation

/// How the onboarding import treats an account whose sign-in failed: a rejected password is asked for again, a refusal
/// to send the password to a server offering only PLAIN asks whether to allow it, and any other failure lists the
/// account as failed with its reason.
enum OnboardingImportFailure: Equatable {
    case credentialsRejected
    case plainNotAllowed
    case failed(String)

    static func classify(_ error: any Error) -> OnboardingImportFailure {
        if AccountService.isCredentialsRejected(error) { return .credentialsRejected }
        if AccountService.isPLAINRefusal(error) { return .plainNotAllowed }
        return .failed(error.localizedDescription)
    }
}
