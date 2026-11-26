import Foundation

/// Shows the provider's sign-in page and catches the redirect that ends it.
public protocol BrowserAuthorizer: Sendable {
    /// Runs one sign-in attempt. It opens the URL `makeURL` builds for this attempt's redirect URI, and returns the
    /// callback to `callbackPath` that carries `expectedState`, along with the redirect URI it was sent to. It owns its
    /// listener or session until it returns, on completion or task cancellation. An authorizer that gives the user no
    /// control to end the sign-in also gives up after a timeout.
    func authorize(
        callbackPath: String, makeURL: @Sendable (_ redirectURI: String) -> URL, expectedState: String
    ) async throws -> (callback: URL, redirectURI: String)
}

/// For an environment that cannot show a browser.
public struct NoOpBrowserAuthorizer: BrowserAuthorizer {
    public init() {}

    public func authorize(
        callbackPath _: String, makeURL _: @Sendable (_ redirectURI: String) -> URL, expectedState _: String
    ) async throws -> (callback: URL, redirectURI: String) {
        throw SSOError.browserUnavailable
    }
}
