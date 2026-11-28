/// The OMEMO version a session or device speaks. The raw value is the stored and JSON form.
public enum OMEMOWireFormat: String, CaseIterable, Sendable {
    /// OMEMO 2 (`urn:xmpp:omemo:2`, XEP-0384 v0.9).
    case omemo2
    /// Legacy OMEMO (`eu.siacs.conversations.axolotl`, XEP-0384 v0.3), the libsignal wire format.
    case legacy
}
