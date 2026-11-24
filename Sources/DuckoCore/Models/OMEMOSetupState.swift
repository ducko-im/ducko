/// How far setting up this device's encryption got on an account's current session.
public enum OMEMOSetupState: Sendable, Equatable {
    /// The session started, and no setup attempt has had its outcome yet.
    case pending
    case complete
    /// The last attempt did not finish. Replies encrypted to this device may not reach it.
    case incomplete
    /// The server refused to store this device's keys.
    case refused
}

/// What asking to set up an account's encryption again did.
public enum OMEMOSetupRetryOutcome: Sendable {
    case started
    case notConnected
    /// Setup is not incomplete or refused, so there is nothing to retry.
    case notNeeded
}
