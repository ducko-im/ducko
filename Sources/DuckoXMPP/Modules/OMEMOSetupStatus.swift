/// The outcome of one attempt to set up this device's OMEMO encryption on a connection: its identity, its entry on the
/// account's device list, and its bundle (XEP-0384).
public enum OMEMOSetupStatus: Sendable, Equatable {
    case complete
    /// The attempt did not finish, as after a timeout, a lost connection, a device list that could not be read, a local
    /// key failure, or a server error that asks to wait or names no known condition. A later attempt may succeed.
    case incomplete
    /// The server refused to store the device list or the bundle, with this condition. No automatic retry follows,
    /// since it would fail the same way until the server changes.
    case refused(XMPPStanzaError.Condition)
}
