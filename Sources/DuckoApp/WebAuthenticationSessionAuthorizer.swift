import AppKit
import AuthenticationServices
import DuckoCore

/// Runs the provider's sign-in in a web authentication session, which can reuse the browser's provider login and hands
/// the `im.ducko:` callback to this app alone.
struct WebAuthenticationSessionAuthorizer: BrowserAuthorizer {
    func authorize(
        callbackPath: String, makeURL: @Sendable (_ redirectURI: String) -> URL, expectedState _: String
    ) async throws -> (callback: URL, redirectURI: String) {
        let redirectURI = SSORedirect.customRedirectURI(callbackPath: callbackPath)
        let callback = try await WebAuthenticationRun().start(url: makeURL(redirectURI))
        return (callback, redirectURI)
    }
}

/// One session, kept so a cancelled sign-in can end it.
@MainActor
private final class WebAuthenticationRun: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                // The session calls this from an XPC reply queue, so it must not inherit the main actor.
                let completion: @Sendable (URL?, (any Error)?) -> Void = { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: SSOError.cancelled)
                    } else {
                        continuation.resume(throwing: SSOError.browserUnavailable)
                    }
                }
                let session = ASWebAuthenticationSession(
                    url: url, callback: .customScheme(SSORedirect.customScheme), completionHandler: completion
                )
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    self.session = nil
                    continuation.resume(throwing: SSOError.browserUnavailable)
                }
            }
        } onCancel: {
            Task { @MainActor in self.session?.cancel() }
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
