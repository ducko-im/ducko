/// A device of a contact or of the account, whichever OMEMO versions it speaks. Trust and the identity key held for a
/// device belong to it, not to one of its sessions.
struct OMEMODeviceKey: Hashable {
    let jid: BareJID
    let deviceID: UInt32
}

/// A session with a device in one OMEMO version. A device can hold a session in each version it speaks.
struct SessionKey: Hashable {
    let jid: BareJID
    let deviceID: UInt32
    let version: OMEMOWireFormat

    var device: OMEMODeviceKey {
        OMEMODeviceKey(jid: jid, deviceID: deviceID)
    }
}
