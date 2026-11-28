import Foundation
import SwiftData

@Model
final class OMEMOSessionRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var peerJID: String
    var peerDeviceID: Int64
    /// The `OMEMOWireFormat` raw value. Rows written before a device could hold a session per version are OMEMO 2.
    var version: String = "omemo2"
    var sessionData: Data
    var associatedData: Data
    var updatedAt: Date = Date()

    init(
        id: UUID,
        accountJID: String,
        peerJID: String,
        peerDeviceID: Int64,
        version: String,
        sessionData: Data,
        associatedData: Data,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.peerDeviceID = peerDeviceID
        self.version = version
        self.sessionData = sessionData
        self.associatedData = associatedData
        self.updatedAt = updatedAt
    }
}
