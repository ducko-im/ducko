import CryptoKit
import Foundation
import Testing

/// Plays the server side of one SCRAM sign-in (RFC 5802, RFC 7677) for a client whose nonce a test cannot fix. It
/// answers the base64 payloads the client sends and does not check the client's proof. Built with another password than
/// the client's, its signature fails the client's check.
public struct SCRAMTestServer {
    public static let mechanism = "SCRAM-SHA-256"

    /// SASL1 stream features offering only SCRAM-SHA-256.
    public static let sasl1Features = """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>SCRAM-SHA-256</mechanism></mechanisms>\
    </features>
    """

    /// What the server-first message says about the offer (XEP-0474) and the TLS version (XEP-0515).
    public enum Attribute: Sendable {
        /// The hash of the mechanisms and channel-binding types the server offered, built as XEP-0474 §6.1 says.
        case offerHash(mechanisms: [String], channelBindingTypes: [String]?)
        /// `h` with a value that matches no offer.
        case wrongOfferHash
        /// `t` with this value.
        case tlsVersion(String)
    }

    private let password: String
    private let hash: Hash
    private let attributes: [Attribute]
    private let salt = Array("ducko-test-salt".utf8)
    private let iterations = 4096
    private var clientFirstMessageBare = ""
    private var serverFirstMessage = ""
    /// The GS2 header the client's final message bound to, decoded from its `c=`.
    public private(set) var clientGS2Header: String?
    /// The bytes the client's `c=` carried after its GS2 header: the channel-binding data, if it bound.
    public private(set) var clientBindingData: [UInt8]?

    /// `mechanism` picks the hash, with or without `-PLUS`. `attributes` follow `r`, `s` and `i` in the server-first
    /// message, which the server signs over as it sent it.
    public init(password: String, mechanism: String = Self.mechanism, attributes: [Attribute] = []) {
        self.password = password
        self.hash = Hash(mechanism: mechanism)
        self.attributes = attributes
    }

    /// Plays a SASL1 sign-in on `transport` from the client's first stream opening up to the server's `<success>`. It
    /// offers ``sasl1Features``, so the server must use the default `mechanism`.
    public mutating func playSASL1SignIn(on transport: MockTransport) async throws {
        await transport.waitForSent(count: 1) // stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(Self.sasl1Features)
        let auth = try #require(await transport.waitForSent { $0.hasPrefix("<auth ") })
        let first = try serverFirst(answering: #require(Self.payload(in: auth)))
        await transport.simulateReceive("<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(first)</challenge>")
        let response = try #require(await transport.waitForSent { $0.hasPrefix("<response ") })
        let verifier = try serverFinal(answering: #require(Self.payload(in: response)))
        await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(verifier)</success>")
    }

    /// The base64 payload a client sent in `stanza`: the text of `<auth>`, `<response>` or `<initial-response>`,
    /// which comes before any other text in the element.
    public static func payload(in stanza: String) -> String? {
        guard let range = stanza.range(of: #">([A-Za-z0-9+/=]+)</"#, options: .regularExpression) else { return nil }
        return String(stanza[range].dropFirst().dropLast(2))
    }

    /// The base64 server-first-message answering the base64 client-first-message.
    public mutating func serverFirst(answering clientFirst: String) -> String {
        let message = Self.decode(clientFirst)
        // The client-first-message is the GS2 header, which holds two commas, then the bare message.
        clientFirstMessageBare = message.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .dropFirst(2).joined()
        let clientNonce = Self.attribute("r", in: clientFirstMessageBare) ?? ""
        serverFirstMessage = (["r=\(clientNonce)server-nonce", "s=\(Data(salt).base64EncodedString())", "i=\(iterations)"]
            + attributes.map(attributeText)).joined(separator: ",")
        return Self.encode(serverFirstMessage)
    }

    /// The base64 server-final-message, the server signature, answering the base64 client-final-message.
    public mutating func serverFinal(answering clientFinal: String) -> String {
        let withoutProof = Self.decode(clientFinal).components(separatedBy: ",p=")[0]
        if let binding = Self.attribute("c", in: withoutProof).flatMap({ Data(base64Encoded: $0) }).map(Array.init),
           let headerEnd = binding.firstRange(of: Array(",,".utf8))?.upperBound {
            clientGS2Header = String(decoding: binding[..<headerEnd], as: UTF8.self)
            clientBindingData = Array(binding[headerEnd...])
        }
        let authMessage = "\(clientFirstMessageBare),\(serverFirstMessage),\(withoutProof)"
        let serverKey = hash.hmac(key: saltedPassword(), data: Array("Server Key".utf8))
        let signature = hash.hmac(key: serverKey, data: Array(authMessage.utf8))
        return Self.encode("v=\(Data(signature).base64EncodedString())")
    }

    private func attributeText(_ attribute: Attribute) -> String {
        switch attribute {
        case let .offerHash(mechanisms, types):
            var input = Self.sortedAndJoined(mechanisms)
            if let types {
                input += [0x1F] + Self.sortedAndJoined(types)
            }
            return "h=\(Data(hash.digest(input)).base64EncodedString())"
        case .wrongOfferHash:
            return "h=\(Data(hash.digest(Array("not the offer".utf8))).base64EncodedString())"
        case let .tlsVersion(version):
            return "t=\(version)"
        }
    }

    private func saltedPassword() -> [UInt8] {
        let key = Array(password.utf8)
        var block = hash.hmac(key: key, data: salt + [0, 0, 0, 1])
        var result = block
        for _ in 1 ..< iterations {
            block = hash.hmac(key: key, data: block)
            for index in result.indices {
                result[index] ^= block[index]
            }
        }
        return result
    }

    private static func sortedAndJoined(_ values: [String]) -> [UInt8] {
        Array(values.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }.joined(separator: [0x1E]))
    }

    private static func attribute(_ name: String, in message: String) -> String? {
        message.split(separator: ",").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private static func decode(_ base64: String) -> String {
        String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self)
    }

    private static func encode(_ message: String) -> String {
        Data(message.utf8).base64EncodedString()
    }

    /// The hash a SCRAM mechanism name stands for.
    private enum Hash {
        case sha1, sha256, sha512, sha3_512

        init(mechanism: String) {
            let name = mechanism.hasSuffix("-PLUS") ? String(mechanism.dropLast(5)) : mechanism
            switch name {
            case "SCRAM-SHA-1": self = .sha1
            case "SCRAM-SHA-512": self = .sha512
            case "SCRAM-SHA3-512": self = .sha3_512
            default: self = .sha256
            }
        }

        func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
            switch self {
            case .sha1: Self.hmac(Insecure.SHA1.self, key: key, data: data)
            case .sha256: Self.hmac(SHA256.self, key: key, data: data)
            case .sha512: Self.hmac(SHA512.self, key: key, data: data)
            case .sha3_512: Self.hmac(SHA3_512.self, key: key, data: data)
            }
        }

        func digest(_ data: [UInt8]) -> [UInt8] {
            switch self {
            case .sha1: Array(Insecure.SHA1.hash(data: data))
            case .sha256: Array(SHA256.hash(data: data))
            case .sha512: Array(SHA512.hash(data: data))
            case .sha3_512: Array(SHA3_512.hash(data: data))
            }
        }

        private static func hmac<H: HashFunction>(_: H.Type, key: [UInt8], data: [UInt8]) -> [UInt8] {
            Array(HMAC<H>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
    }
}
