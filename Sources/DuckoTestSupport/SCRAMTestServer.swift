import CryptoKit
import Foundation
import Testing

/// Plays the server side of one SCRAM-SHA-256 sign-in (RFC 5802, RFC 7677) for a client whose nonce a test cannot
/// fix. It answers the base64 payloads the client sends and does not check the client's proof. Built with another
/// password than the client's, its signature fails the client's check.
public struct SCRAMTestServer {
    public static let mechanism = "SCRAM-SHA-256"

    /// SASL1 stream features offering only SCRAM-SHA-256.
    public static let sasl1Features = """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>SCRAM-SHA-256</mechanism></mechanisms>\
    </features>
    """

    private let password: String
    private let salt = Array("ducko-test-salt".utf8)
    private let iterations = 4096
    private var clientFirstMessageBare = ""
    private var serverFirstMessage = ""

    public init(password: String) {
        self.password = password
    }

    /// Plays a SASL1 sign-in on `transport` from the client's first stream opening up to the server's `<success>`.
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
        serverFirstMessage = "r=\(clientNonce)server-nonce,s=\(Data(salt).base64EncodedString()),i=\(iterations)"
        return Self.encode(serverFirstMessage)
    }

    /// The base64 server-final-message, the server signature, answering the base64 client-final-message.
    public func serverFinal(answering clientFinal: String) -> String {
        let withoutProof = Self.decode(clientFinal).components(separatedBy: ",p=")[0]
        let authMessage = "\(clientFirstMessageBare),\(serverFirstMessage),\(withoutProof)"
        let serverKey = Self.hmac(key: saltedPassword(), data: Array("Server Key".utf8))
        let signature = Self.hmac(key: serverKey, data: Array(authMessage.utf8))
        return Self.encode("v=\(Data(signature).base64EncodedString())")
    }

    private func saltedPassword() -> [UInt8] {
        let key = Array(password.utf8)
        var block = Self.hmac(key: key, data: salt + [0, 0, 0, 1])
        var result = block
        for _ in 1 ..< iterations {
            block = Self.hmac(key: key, data: block)
            for index in result.indices {
                result[index] ^= block[index]
            }
        }
        return result
    }

    private static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
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
}
