/// Domain events emitted by ``XMPPClient`` for consumption by higher layers.
public enum XMPPEvent: Sendable {
    case connected(FullJID)
    case streamResumed(FullJID)
    case disconnected(DisconnectReason)
    case authenticationFailed(String)
    case messageReceived(XMPPMessage)
    case presenceReceived(XMPPPresence)
    case iqReceived(XMPPIQ)
    case rosterUpdated(RosterUpdate)
    case presenceUpdated(from: JID, presence: XMPPPresence)
    case presenceSubscriptionRequest(from: BareJID)
    case presenceSubscriptionApproved(from: BareJID)
    case presenceSubscriptionRevoked(from: BareJID)
    case messageCarbonReceived(ForwardedMessage)
    case messageCarbonSent(ForwardedMessage)
    case archivedMessagesLoaded([ArchivedMessage], fin: MAMFin)
    case chatStateChanged(from: BareJID, state: ChatState)
    case deliveryReceiptReceived(messageID: String, from: JID)
    case chatMarkerReceived(messageID: String, type: ChatMarkerType, from: JID)
    case messageCorrected(originalID: String, newBody: String, from: JID)
    case messageRetracted(originalID: String, from: JID)
    case messageModerated(originalID: String, moderator: String, room: BareJID, reason: String?)
    case messageError(messageID: String?, from: JID, error: XMPPStanzaError)

    // MUC (XEP-0045)
    case roomJoined(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool)
    case roomOccupantJoined(room: BareJID, occupant: RoomOccupant)
    /// `isSelf` tells the user's own departure, as the room confirmed it, from another occupant's.
    case roomOccupantLeft(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?, isSelf: Bool)
    /// `isSelf` tells the user's own nickname change, as the room confirmed it, from another occupant's.
    case roomOccupantNickChanged(room: BareJID, oldNickname: String, occupant: RoomOccupant, isSelf: Bool)
    case roomSubjectChanged(room: BareJID, subject: String?, setter: JID?)
    case roomInviteReceived(RoomInvite)
    case roomMessageReceived(XMPPMessage)
    case mucPrivateMessageReceived(XMPPMessage)
    case roomDestroyed(room: BareJID, reason: String?, alternateVenue: BareJID?)
    case mucSelfPingFailed(room: BareJID, reason: MUCSelfPingFailure)

    // Jingle File Transfer (XEP-0166/0234)
    case jingleFileTransferReceived(JingleFileOffer)
    case jingleFileTransferCompleted(sid: String, transport: JingleTransportKind)
    case jingleFileTransferFailed(sid: String, reason: JingleTransferFailureReason)
    case jingleFileTransferProgress(sid: String, bytesTransferred: Int64, totalBytes: Int64)
    case jingleChecksumReceived(sid: String, checksum: JingleChecksumInfo)

    // PEP (XEP-0163)
    case pepItemsPublished(from: BareJID, node: String, items: [PEPItem])
    case pepItemsRetracted(from: BareJID, node: String, itemIDs: [String])

    /// Avatar (XEP-0153 vCard-Based Avatars)
    case vcardAvatarHashReceived(from: BareJID, hash: String?)

    // Blocking (XEP-0191)
    case blockListLoaded([BareJID])
    case contactBlocked(BareJID)
    case contactUnblocked(BareJID)

    // OMEMO (XEP-0384)

    case omemoDeviceListReceived(jid: BareJID, devices: [UInt32])
    /// `message` is the stanza as received. Only `decryptedBody` comes from the encrypted envelope, so the stanza's
    /// ids, attachments, delay and reply are not covered by the encryption.
    case omemoEncryptedMessageReceived(message: XMPPMessage, decryptedBody: String?, senderDeviceID: UInt32)
    /// `consumedPreKeyID` names the one-time pre-key of this device that a contact's key exchange used up, or nil when
    /// this device started the session.
    case omemoSessionEstablished(jid: BareJID, deviceID: UInt32, identityKey: [UInt8], consumedPreKeyID: UInt32?)
    case omemoSessionAdvanced(jid: BareJID, deviceID: UInt32)
    /// Per-message diagnostic: an OMEMO send completed with at least one recipient device skipped (missing bundle).
    /// Fires for peer AND own devices. The outgoing stanza ID is omitted because encrypt runs before the stanza is built —
    /// correlate by `conversation` + temporal proximity.
    case omemoRecipientsPartial(conversation: BareJID, droppedDevices: [DroppedOMEMORecipient])

    /// OOB IQ (XEP-0066)
    case oobIQOfferReceived(OOBIQOffer)

    /// Service Outage (XEP-0455)
    case serviceOutageReceived(ServiceOutageInfo)
}

/// Reason the client disconnected.
public enum DisconnectReason: Sendable {
    case requested
    case streamError(XMPPStreamError?, text: String?)
    case connectionLost(String)
    case redirect(host: String, port: UInt16?)
}

/// Reason for MUC self-ping failure per XEP-0410.
public enum MUCSelfPingFailure: Sendable {
    case notJoined
    case nickChanged(String)
}

/// Chat state notification per XEP-0085.
public enum ChatState: String, Sendable, CaseIterable {
    case active
    case composing
    case paused
    case inactive
    case gone
}

/// Chat marker type per XEP-0333.
public enum ChatMarkerType: String, Sendable, CaseIterable {
    case received
    case displayed
    case acknowledged
}

/// An incoming OOB IQ file offer per XEP-0066 §3 (IQ-based).
public struct OOBIQOffer: Sendable {
    /// The id this side gave the offer, which accepting or rejecting it takes. `id` is the sender's stanza id, which
    /// another sender can use too.
    public let offerID: String
    public let id: String
    public let from: JID
    public let url: String
    public let desc: String?

    public init(offerID: String, id: String, from: JID, url: String, desc: String?) {
        self.offerID = offerID
        self.id = id
        self.from = from
        self.url = url
        self.desc = desc
    }
}

/// A random id this side gives an offer it received. The ids on the wire are chosen by peers, so two offers, whether
/// from different peers or of different kinds, can carry the same one.
func makeOfferID() -> String {
    hexString((0 ..< 8).map { _ in UInt8.random(in: .min ... .max) })
}

/// Parsed service outage information per XEP-0455.
public struct ServiceOutageInfo: Sendable {
    public let description: String?
    public let expectedEnd: String?
    public let alternativeDomain: String?

    public init(description: String?, expectedEnd: String?, alternativeDomain: String?) {
        self.description = description
        self.expectedEnd = expectedEnd
        self.alternativeDomain = alternativeDomain
    }
}
