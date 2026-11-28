import DuckoXMPP
import Testing

public extension OMEMOModule.EncryptedMessageElements {
    /// The OMEMO 2 element, which a message carries when a device that lists OMEMO 2 receives it.
    var omemo2: DuckoXMPP.XMLElement {
        get throws { try #require(omemo2Encrypted) }
    }

    /// The legacy element, which a message carries when a device that lists only legacy OMEMO receives it.
    var legacy: DuckoXMPP.XMLElement {
        get throws { try #require(legacyEncrypted) }
    }
}
