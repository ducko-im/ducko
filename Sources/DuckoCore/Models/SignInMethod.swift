/// How an account proves who it is when it signs in.
public enum SignInMethod: String, Sendable {
    /// A password stored for the account.
    case password
    /// An OAuth grant from a sign-in through the browser (XEP-0493).
    case browser
}
