import CryptoKit

/// Jingle action per XEP-0166 §7.
enum JingleAction: String {
    case sessionInitiate = "session-initiate"
    case sessionAccept = "session-accept"
    case sessionTerminate = "session-terminate"
    case transportInfo = "transport-info"
    case transportReplace = "transport-replace"
    case transportAccept = "transport-accept"
    case transportReject = "transport-reject"
    case sessionInfo = "session-info"
    case contentAdd = "content-add"
    case contentAccept = "content-accept"
    case contentReject = "content-reject"
    case contentRemove = "content-remove"
}

/// Jingle-specific error condition per XEP-0166 §10.
enum JingleErrorCondition: String {
    case outOfOrder = "out-of-order"
    case tieBreak = "tie-break"
    case unknownSession = "unknown-session"

    var element: XMLElement {
        XMLElement(name: rawValue, namespace: XMPPNamespaces.jingleErrors)
    }
}

/// Reason for terminating a Jingle session per XEP-0166 §7.4.
public enum JingleTerminateReason: String, Sendable {
    case success
    case decline
    case cancel
    case busy
    case timeout
    case connectivityError = "connectivity-error"
    case failedTransport = "failed-transport"
}

public enum JingleTransferFailureReason: String, Sendable {
    case decline
    case cancel
    case busy
    case timeout
    case connectivityError = "connectivity-error"
    case failedTransport = "failed-transport"
    case unknown
    case disconnected
    case proxyActivationFailed = "proxy-activation-failed"
    case transportReject = "transport-reject"
    case transportReplaceFailed = "transport-replace-failed"
    case incomplete
    case checksumMismatch = "checksum-mismatch"

    public var displayText: String {
        switch self {
        case .decline: "The contact declined the transfer"
        case .cancel: "The transfer was canceled"
        case .busy: "The contact is busy"
        case .timeout: "The transfer timed out"
        case .connectivityError: "The contact could not be reached"
        case .failedTransport: "No connection method worked for the transfer"
        case .unknown: "The transfer ended for an unknown reason"
        case .disconnected: "The connection to the server was lost"
        case .proxyActivationFailed: "The file transfer proxy could not be activated"
        case .transportReject: "The contact rejected the connection method"
        case .transportReplaceFailed: "Switching the connection method failed"
        case .incomplete: "The transfer ended before the whole file arrived"
        case .checksumMismatch: "The received file is corrupted"
        }
    }

    /// The failure a session-terminate reason stands for, or `nil` for a successful session.
    init?(terminationReason: JingleTerminateReason?) {
        switch terminationReason {
        case .some(.success): return nil
        case .some(.decline): self = .decline
        case .some(.cancel): self = .cancel
        case .some(.busy): self = .busy
        case .some(.timeout): self = .timeout
        case .some(.connectivityError): self = .connectivityError
        case .some(.failedTransport): self = .failedTransport
        case .none: self = .unknown
        }
    }
}

/// Senders attribute on a Jingle content element per XEP-0166 §7.3.
/// Controls which party sends media/file data within the content.
public enum JingleContentSenders: String, Sendable {
    case none
    case initiator
    case responder
    case both
}

/// Range element for partial file transfers per XEP-0234 §6. This side never offers or requests a partial transfer.
/// `JingleModule.requiresUnsupportedRange` decides on the raw elements whether a peer's range is accepted, and parsing
/// only rejects a range that does not fit the file's size.
struct JingleFileRange: Sendable, Hashable {
    let offset: Int64?
    let length: Int64?

    init(offset: Int64? = nil, length: Int64? = nil) {
        self.offset = offset
        self.length = length
    }

    /// Parses from a `<range/>` element.
    init?(from element: XMLElement) {
        guard element.name == "range" else { return nil }
        let parsedOffset = element.attribute("offset").flatMap(Int64.init)
        let parsedLength = element.attribute("length").flatMap(Int64.init)
        // Reject negative values from untrusted XML
        if let parsedOffset, parsedOffset < 0 { return nil }
        if let parsedLength, parsedLength < 0 { return nil }
        self.offset = parsedOffset
        self.length = parsedLength
    }

    /// Whether the range lies within a file of `size` bytes.
    func fits(within size: Int64) -> Bool {
        let start = offset ?? 0
        guard start >= 0, start <= size else { return false }
        guard let length else { return true }
        return length >= 0 && length <= size - start
    }

    /// Serializes to a `<range/>` element.
    func toXML() -> XMLElement {
        var attributes: [String: String] = [:]
        if let offset { attributes["offset"] = String(offset) }
        if let length { attributes["length"] = String(length) }
        return XMLElement(name: "range", attributes: attributes)
    }
}

/// File description inside a Jingle content element per XEP-0234.
public struct JingleFileDescription: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let mediaType: String?
    public let hash: String?
    public let hashAlgo: String?
    /// Whether the offer promised a checksum in a later session-info (`<hash-used/>`).
    public let hashUsed: Bool
    public let date: String?
    public let desc: String?
    let range: JingleFileRange?

    /// Describes a file this side offers. Nothing here offers part of a file, so an offer never carries a range.
    public init(
        name: String, size: Int64, mediaType: String? = nil, hash: String? = nil, hashAlgo: String? = nil,
        hashUsed: Bool = false, date: String? = nil, desc: String? = nil
    ) {
        self.init(
            name: name, size: size, mediaType: mediaType, hash: hash, hashAlgo: hashAlgo,
            hashUsed: hashUsed, date: date, desc: desc, range: nil
        )
    }

    /// `range` deliberately has no default, so a call that omits it can only mean the offer initializer above.
    init(
        name: String, size: Int64, mediaType: String? = nil, hash: String? = nil, hashAlgo: String? = nil,
        hashUsed: Bool = false, date: String? = nil, desc: String? = nil, range: JingleFileRange?
    ) {
        self.name = name
        self.size = size
        self.mediaType = mediaType
        self.hash = hash
        self.hashAlgo = hashAlgo
        self.hashUsed = hashUsed
        self.date = date
        self.desc = desc
        self.range = range
    }

    /// Parses from a `<description xmlns='...file-transfer:5'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "description",
              element.namespace == XMPPNamespaces.jingleFileTransfer,
              let file = element.child(named: "file"),
              let name = file.childText(named: "name"),
              let sizeText = file.childText(named: "size"),
              let size = Int64(sizeText),
              size >= 0, size <= Self.maxSize else { return nil }

        let range: JingleFileRange?
        if let rangeElement = file.child(named: "range") {
            guard let parsed = JingleFileRange(from: rangeElement), parsed.fits(within: size) else { return nil }
            range = parsed
        } else {
            range = nil
        }

        let hashElement = file.child(named: "hash", namespace: XMPPNamespaces.hashes2)
        self.name = Self.sanitizeFileName(name)
        self.size = size
        self.mediaType = file.childText(named: "media-type")
        self.hash = hashElement?.textContent
        self.hashAlgo = hashElement?.attribute("algo")
        self.hashUsed = file.child(named: "hash-used", namespace: XMPPNamespaces.hashes2) != nil
        self.date = file.childText(named: "date")
        self.desc = file.childText(named: "desc")
        self.range = range
    }

    /// The largest size an offer may declare. A received file is held in memory whole before it is saved, so a size past
    /// this is refused before any byte arrives.
    public static let maxSize: Int64 = 16 * 1024 * 1024 * 1024

    /// The base64 SHA-256 digest of `data`, as carried in a `<hash algo='sha-256'>` element.
    public static func sha256Hash(of data: [UInt8]) -> String {
        Base64.encode(Array(SHA256.hash(data: data)))
    }

    /// Serializes to a `<description>` element containing a `<file>`.
    public func toXML() -> XMLElement {
        var file = XMLElement(name: "file")
        file.setChildText(named: "name", to: name)
        file.setChildText(named: "size", to: String(size))
        if let mediaType {
            file.setChildText(named: "media-type", to: mediaType)
        }
        if let hash {
            var hashElement = XMLElement(name: "hash", namespace: XMPPNamespaces.hashes2, attributes: ["algo": hashAlgo ?? "sha-256"])
            hashElement.addText(hash)
            file.addChild(hashElement)
        }
        if let date {
            file.setChildText(named: "date", to: date)
        }
        if let desc {
            file.setChildText(named: "desc", to: desc)
        }
        if let range {
            file.addChild(range.toXML())
        }

        var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
        description.addChild(file)
        return description
    }

    /// Reduces a peer's filename to one visible file name (XEP-0234 §9). Path components are stripped so the file can't land
    /// outside its directory, and leading dots, control and format characters are dropped so it can't be hidden or disguised.
    public static func sanitizeFileName(_ name: String) -> String {
        let lastComponent = name.split { $0 == "/" || $0 == "\\" }.last ?? ""
        let visible = lastComponent.replacing(":", with: "-").filter { character in
            !character.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
        }
        var result = String(visible.drop { $0 == "." || $0.isWhitespace })
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result.isEmpty ? "unnamed" : result
    }
}

/// SOCKS5 Bytestreams transport per XEP-0260.
public struct SOCKS5Transport: Sendable, Hashable {
    public let sid: String
    public let candidates: [Candidate]

    public init(sid: String, candidates: [Candidate] = []) {
        self.sid = sid
        self.candidates = candidates
    }

    /// A SOCKS5 transport candidate.
    public struct Candidate: Sendable, Hashable {
        public let cid: String
        public let host: String
        public let port: UInt16
        public let jid: String
        public let priority: UInt32
        public let type: CandidateType

        public init(cid: String, host: String, port: UInt16, jid: String, priority: UInt32, type: CandidateType) {
            self.cid = cid
            self.host = host
            self.port = port
            self.jid = jid
            self.priority = priority
            self.type = type
        }
    }

    /// SOCKS5 candidate type.
    public enum CandidateType: String, Sendable, Hashable {
        case direct
        case proxy
    }

    /// Parses from a `<transport xmlns='...s5b:1'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "transport",
              element.namespace == XMPPNamespaces.jingleS5B,
              let sid = element.attribute("sid") else { return nil }

        self.sid = sid
        self.candidates = element.children(named: "candidate").compactMap { candidate in
            guard let cid = candidate.attribute("cid"),
                  let host = candidate.attribute("host"),
                  let portStr = candidate.attribute("port"),
                  let port = UInt16(portStr),
                  let jid = candidate.attribute("jid"),
                  let priorityStr = candidate.attribute("priority"),
                  let priority = UInt32(priorityStr) else { return nil }
            let type = candidate.attribute("type").flatMap(CandidateType.init(rawValue:)) ?? .direct
            return Candidate(cid: cid, host: host, port: port, jid: jid, priority: priority, type: type)
        }
    }

    /// Serializes to a `<transport>` element.
    public func toXML() -> XMLElement {
        var transport = XMLElement(name: "transport", namespace: XMPPNamespaces.jingleS5B, attributes: ["sid": sid])
        for candidate in candidates {
            let candidateElement = XMLElement(
                name: "candidate",
                attributes: [
                    "cid": candidate.cid,
                    "host": candidate.host,
                    "jid": candidate.jid,
                    "port": String(candidate.port),
                    "priority": String(candidate.priority),
                    "type": candidate.type.rawValue
                ]
            )
            transport.addChild(candidateElement)
        }
        return transport
    }
}

/// In-Band Bytestreams transport per XEP-0261.
public struct IBBTransport: Sendable, Hashable {
    public let sid: String
    public let blockSize: Int

    public init(sid: String, blockSize: Int) {
        self.sid = sid
        self.blockSize = blockSize
    }

    /// Parses from a `<transport xmlns='...ibb:1'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "transport",
              element.namespace == XMPPNamespaces.jingleIBB,
              let sid = element.attribute("sid"),
              let blockSizeStr = element.attribute("block-size"),
              let blockSize = Int(blockSizeStr),
              // XEP-0047 caps block-size at 65535; a non-positive size would stall or crash chunking.
              (1 ... 65535).contains(blockSize) else { return nil }

        self.sid = sid
        self.blockSize = blockSize
    }

    /// Serializes to a `<transport>` element.
    public func toXML() -> XMLElement {
        XMLElement(
            name: "transport",
            namespace: XMPPNamespaces.jingleIBB,
            attributes: ["sid": sid, "block-size": String(blockSize)]
        )
    }
}

/// Which Jingle transport actually carried the bytes to completion.
public enum JingleTransportKind: String, Sendable, Hashable {
    case socks5
    case ibb
}

/// Transport description for a Jingle content element.
public enum JingleTransportDescription: Sendable, Hashable {
    case socks5(SOCKS5Transport)
    case ibb(IBBTransport)

    /// Detects transport type by namespace and parses accordingly.
    public static func parse(from element: XMLElement) -> JingleTransportDescription? {
        switch element.namespace {
        case XMPPNamespaces.jingleS5B:
            if let transport = SOCKS5Transport(from: element) {
                return .socks5(transport)
            }
        case XMPPNamespaces.jingleIBB:
            if let transport = IBBTransport(from: element) {
                return .ibb(transport)
            }
        default:
            break
        }
        return nil
    }

    /// Serializes to the appropriate transport XML element.
    public func toXML() -> XMLElement {
        switch self {
        case let .socks5(transport): transport.toXML()
        case let .ibb(transport): transport.toXML()
        }
    }
}

/// A Jingle content element containing file description and transport.
struct JingleContent {
    let name: String
    let creator: String
    let senders: JingleContentSenders?
    let description: JingleFileDescription
    let transport: JingleTransportDescription

    /// The effective senders value, defaulting to `.both` when not explicitly set.
    var effectiveSenders: JingleContentSenders {
        senders ?? .both
    }

    init(
        name: String, creator: String, senders: JingleContentSenders? = nil,
        description: JingleFileDescription, transport: JingleTransportDescription
    ) {
        self.name = name
        self.creator = creator
        self.senders = senders
        self.description = description
        self.transport = transport
    }

    /// Parses from a `<content>` element.
    init?(from element: XMLElement) {
        guard element.name == "content",
              let name = element.attribute("name"),
              let creator = element.attribute("creator") else { return nil }

        guard let descElement = element.child(named: "description", namespace: XMPPNamespaces.jingleFileTransfer),
              let description = JingleFileDescription(from: descElement) else { return nil }

        guard let transportElement = element.child(named: "transport"),
              let transport = JingleTransportDescription.parse(from: transportElement) else { return nil }

        self.name = name
        self.creator = creator
        self.senders = element.attribute("senders").flatMap(JingleContentSenders.init(rawValue:))
        self.description = description
        self.transport = transport
    }

    /// Serializes to a `<content>` element.
    func toXML() -> XMLElement {
        var attributes = ["creator": creator, "name": name]
        if let senders {
            attributes["senders"] = senders.rawValue
        }
        var content = XMLElement(name: "content", attributes: attributes)
        content.addChild(description.toXML())
        content.addChild(transport.toXML())
        return content
    }
}

/// IBB session state for tracking in-band data transfer.
struct IBBSessionState {
    let ibbSID: String
    let blockSize: Int
    var receivedData: [UInt8] = []
    var nextExpectedSeq: UInt16 = 0
    var hasOpened: Bool = false
}

/// Transport connection state within a Jingle session.
enum TransportState {
    case pending
    case connecting
    case connected(candidateCID: String)
    case failed
    case replacePending
}

/// State of a Jingle session.
struct JingleSession {
    let peer: FullJID
    /// The initiator sends the file and the responder receives it.
    let role: Role
    var transportState: TransportState
    var selectedTransport: JingleTransportKind?
    /// The id this side gave the session, stamped by `JingleModule.addSession`. A peer can reuse the sid once this
    /// session ends, so accept, decline and receive name the session by this id. An outcome that outlived its session
    /// checks it too, so it cannot mutate the session that replaced it.
    var offerID = ""
    /// Set when this side starts accepting the session, so a repeated accept is rejected, and read as the peer's
    /// permission to send bytes: nothing may be buffered for a transfer the user has not taken. Cleared when the
    /// session-accept fails to send, so the accept can be retried.
    var isAccepted = false
    /// Set when the SOCKS5 attempt starts, so no later session-accept starts another.
    var isTransportAttemptStarted = false

    /// The content the session was created with. Fixed for the session's lifetime — nothing renegotiates it.
    let content: JingleContent

    /// Whether this side initiated or is responding.
    enum Role {
        case initiator
        case responder
    }

    init(
        peer: FullJID,
        role: Role,
        transportState: TransportState = .pending,
        selectedTransport: JingleTransportKind? = nil,
        content: JingleContent
    ) {
        self.peer = peer
        self.role = role
        self.transportState = transportState
        self.selectedTransport = selectedTransport
        self.content = content
    }
}

/// Simplified file offer for event consumers.
public struct JingleFileOffer: Sendable {
    /// The id this side gave the offer, which accepting, declining and receiving it take.
    public let offerID: String
    public let sid: String
    public let from: FullJID
    public let fileName: String
    public let fileSize: Int64
    public let mediaType: String?

    public init(offerID: String, sid: String, from: FullJID, fileName: String, fileSize: Int64, mediaType: String? = nil) {
        self.offerID = offerID
        self.sid = sid
        self.from = from
        self.fileName = fileName
        self.fileSize = fileSize
        self.mediaType = mediaType
    }
}

/// Parsed checksum from a session-info per XEP-0234 §5.
public struct JingleChecksumInfo: Sendable {
    public let contentName: String
    public let algo: String
    public let hash: String

    public init(contentName: String, algo: String, hash: String) {
        self.contentName = contentName
        self.algo = algo
        self.hash = hash
    }
}
