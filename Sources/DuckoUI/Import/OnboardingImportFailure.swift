import DuckoCore
import Foundation

/// How the onboarding import treats an account whose sign-in failed: a rejected password is asked for again, and any
/// other failure lists the account as failed with its reason.
enum OnboardingImportFailure: Equatable {
    case credentialsRejected
    case failed(String)

    static func classify(_ error: any Error) -> OnboardingImportFailure {
        AccountService.isCredentialsRejected(error) ? .credentialsRejected : .failed(error.localizedDescription)
    }
}
