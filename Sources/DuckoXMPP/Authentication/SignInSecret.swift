/// What a sign-in proves the account with.
public enum SignInSecret: Sendable, Equatable {
    case password(String)
    /// An OAuth 2.0 access token, sent with OAUTHBEARER (RFC 7628). An empty token asks the server where its
    /// authorization server is, and the sign-in then fails with the server's answer (XEP-0493 §2.3.1).
    case bearerToken(String)
}
