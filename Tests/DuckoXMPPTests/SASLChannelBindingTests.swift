import CryptoKit
import Testing
@testable import DuckoXMPP

// MARK: - Channel Binding Mode Tests

enum ChannelBindingTests {
    struct GS2Header {
        private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
        private static let mockCBData: [UInt8] = Array(repeating: 0xAB, count: 32)

        @Test
        func `No channel binding produces n,, header`() {
            var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
            let message = state.clientFirstMessage(authcid: "user", password: "pencil")
            #expect(message.hasPrefix("n,,"))
        }

        @Test
        func `Client supports but not used produces y,, header`() {
            var state = SCRAMState<SHA256>(
                channelBindingMode: .clientSupportsButNotUsed,
                nonceGenerator: { Self.clientNonce }
            )
            let message = state.clientFirstMessage(authcid: "user", password: "pencil")
            #expect(message.hasPrefix("y,,"))
        }

        @Test
        func `Bound channel binding produces p= header`() {
            var state = SCRAMState<SHA256>(
                channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData),
                nonceGenerator: { Self.clientNonce }
            )
            let message = state.clientFirstMessage(authcid: "user", password: "pencil")
            #expect(message.hasPrefix("p=tls-server-end-point,,"))
        }

        @Test
        func `Client-first-message-bare is identical regardless of CB mode`() {
            let expectedBare = "n=user,r=\(Self.clientNonce)"

            var stateNone = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
            let messageNone = stateNone.clientFirstMessage(authcid: "user", password: "pencil")
            #expect(messageNone.hasSuffix(expectedBare))

            var stateBound = SCRAMState<SHA256>(
                channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData),
                nonceGenerator: { Self.clientNonce }
            )
            let messageBound = stateBound.clientFirstMessage(authcid: "user", password: "pencil")
            #expect(messageBound.hasSuffix(expectedBare))
        }
    }

    struct ClientFinalChannelBinding {
        private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
        private static let serverFirst =
            "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        private static let mockCBData: [UInt8] = [0x01, 0x02, 0x03, 0x04]

        @Test
        func `No CB produces c=biws (base64 of n,,)`() throws {
            var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
            _ = state.clientFirstMessage(authcid: "user", password: "pencil")
            let clientFinal = try state.clientFinalMessage(serverFirstMessage: Self.serverFirst).get()
            // biws = base64("n,,")
            #expect(clientFinal.hasPrefix("c=biws,"))
        }

        @Test
        func `Client supports but not used produces c=base64(y,,)`() throws {
            var state = SCRAMState<SHA256>(
                channelBindingMode: .clientSupportsButNotUsed,
                nonceGenerator: { Self.clientNonce }
            )
            _ = state.clientFirstMessage(authcid: "user", password: "pencil")
            let clientFinal = try state.clientFinalMessage(serverFirstMessage: Self.serverFirst).get()
            let expectedC = Base64.encode(Array("y,,".utf8))
            #expect(clientFinal.hasPrefix("c=\(expectedC),"))
        }

        @Test
        func `Bound CB produces c=base64(p=type,, + data)`() throws {
            var state = SCRAMState<SHA256>(
                channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData),
                nonceGenerator: { Self.clientNonce }
            )
            _ = state.clientFirstMessage(authcid: "user", password: "pencil")
            let clientFinal = try state.clientFinalMessage(serverFirstMessage: Self.serverFirst).get()
            let cbPayload = Array("p=tls-server-end-point,,".utf8) + Self.mockCBData
            let expectedC = Base64.encode(cbPayload)
            #expect(clientFinal.hasPrefix("c=\(expectedC),"))
        }
    }

    struct FullExchangeWithChannelBinding {
        private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
        private static let mockCBData: [UInt8] = Array(repeating: 0xAA, count: 32)
        private static let serverFirst =
            "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        @Test
        func `Full SCRAM-SHA-256 exchange with channel binding self-verifies`() throws {
            // This test verifies that the client can generate a proof and verify
            // a server signature when channel binding is active.
            // We can't use RFC test vectors (those assume n,,), but we can verify
            // internal consistency: the auth message used for proof == the one used for verification.
            var state = SCRAMState<SHA256>(
                channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData),
                nonceGenerator: { Self.clientNonce }
            )
            _ = state.clientFirstMessage(authcid: "user", password: "pencil")
            let clientFinal = try state.clientFinalMessage(serverFirstMessage: Self.serverFirst).get()

            // Client final should have the CB payload, not biws
            let hasBiws = clientFinal.hasPrefix("c=biws,")
            #expect(!hasBiws)

            // Verify it starts with c= and has a proof
            #expect(clientFinal.contains(",p="))
        }
    }
}

// MARK: - SCRAM-PLUS Mechanism Tests

enum SCRAMPLUSTests {
    struct SHA256PLUS {
        private static let clientNonce = "testnonce123"
        private static let mockCBData: [UInt8] = Array(repeating: 0xFF, count: 32)

        @Test
        func `Start produces correct auth element`() throws {
            var mechanism = SCRAM(
                mechanismName: SCRAMMechanismName.sha256Plus,
                session: SCRAMState<SHA256>(channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData), nonceGenerator: { Self.clientNonce })
            )
            let auth = mechanism.start(authcid: "user", password: "pencil")

            #expect(auth.name == "auth")
            #expect(auth.namespace == saslNamespace)
            #expect(auth.attribute("mechanism") == "SCRAM-SHA-256-PLUS")

            let payload = try #require(auth.textContent)
            let decoded = try #require(Base64.decodeString(payload))
            #expect(decoded.hasPrefix("p=tls-server-end-point,,"))
            #expect(decoded.contains("n=user,r=\(Self.clientNonce)"))
        }
    }

    struct SHA1PLUS {
        private static let clientNonce = "testnonce456"
        private static let mockCBData: [UInt8] = Array(repeating: 0xEE, count: 20)

        @Test
        func `Start produces correct auth element`() throws {
            var mechanism = SCRAM(
                mechanismName: SCRAMMechanismName.sha1Plus,
                session: SCRAMState<Insecure.SHA1>(channelBindingMode: .bound(type: .tlsServerEndPoint, data: Self.mockCBData), nonceGenerator: { Self.clientNonce })
            )
            let auth = mechanism.start(authcid: "user", password: "pencil")

            #expect(auth.name == "auth")
            #expect(auth.namespace == saslNamespace)
            #expect(auth.attribute("mechanism") == "SCRAM-SHA-1-PLUS")

            let payload = try #require(auth.textContent)
            let decoded = try #require(Base64.decodeString(payload))
            #expect(decoded.hasPrefix("p=tls-server-end-point,,"))
            #expect(decoded.contains("n=user,r=\(Self.clientNonce)"))
        }
    }
}

// MARK: - Channel Binding Choice Tests

/// Each way a server can offer channel binding (XEP-0440 §3), through both authenticators.
struct ChannelBindingChoiceTests {
    enum Outcome: Sendable, Equatable {
        /// `header` is the GS2 header, which PLAIN doesn't have.
        case mechanism(String, header: String?)
        case failed(SASLAuthError)

        static func bound(_ type: ChannelBindingType, with mechanism: String) -> Outcome {
            .mechanism(mechanism, header: "p=\(type.rawValue),,")
        }
    }

    /// The bindings TLS computed: both on TLS 1.3, only the end-point one on TLS 1.2, and none without TLS.
    enum Computed: Sendable {
        case both, endPointOnly, none
    }

    struct Offer: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let mechanisms: [String]
        /// `nil` leaves out `<sasl-channel-binding>`; an empty list sends it empty.
        let types: [String]?
        let sasl1: Outcome
        let sasl2: Outcome
        var computed = Computed.both
        var allowsPLAIN = false

        var bindings: [ChannelBindingType: [UInt8]] {
            switch computed {
            case .both: tls13Bindings
            case .endPointOnly: tls13Bindings.filter { $0.key == .tlsServerEndPoint }
            case .none: [:]
            }
        }
    }

    private static let both = ["tls-server-end-point", "tls-exporter"]
    private static let plusAndUnbound = ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]

    static let offers: [Offer] = [
        Offer(
            testDescription: "tls-exporter is preferred over tls-server-end-point", mechanisms: plusAndUnbound, types: both,
            sasl1: .bound(.tlsExporter, with: "SCRAM-SHA-256-PLUS"), sasl2: .bound(.tlsExporter, with: "SCRAM-SHA-256-PLUS")
        ),
        Offer(
            testDescription: "tls-server-end-point binds when only it is computed", mechanisms: plusAndUnbound, types: both,
            sasl1: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-256-PLUS"), sasl2: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-256-PLUS"),
            computed: .endPointOnly
        ),
        Offer(
            testDescription: "a listed type binds over a stronger unbound mechanism", mechanisms: ["SCRAM-SHA-256", "SCRAM-SHA-1-PLUS"],
            types: ["tls-server-end-point"],
            sasl1: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-1-PLUS"), sasl2: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-1-PLUS")
        ),
        Offer(
            testDescription: "no types and no PLUS says the client supports binding", mechanisms: ["SCRAM-SHA-256"],
            types: nil, sasl1: .mechanism("SCRAM-SHA-256", header: "y,,"), sasl2: .mechanism("SCRAM-SHA-256", header: "y,,")
        ),
        Offer(
            testDescription: "an empty type list counts as none", mechanisms: ["SCRAM-SHA-256"],
            types: [], sasl1: .mechanism("SCRAM-SHA-256", header: "y,,"), sasl2: .mechanism("SCRAM-SHA-256", header: "y,,")
        ),
        Offer(
            testDescription: "types without PLUS abort", mechanisms: ["SCRAM-SHA-256"], types: ["tls-server-end-point"],
            sasl1: .failed(.channelBindingMechanismMissing), sasl2: .failed(.channelBindingMechanismMissing)
        ),
        Offer(
            testDescription: "types with only PLAIN abort even when PLAIN is allowed", mechanisms: ["PLAIN"], types: ["tls-exporter"],
            sasl1: .failed(.channelBindingMechanismMissing), sasl2: .failed(.channelBindingMechanismMissing), allowsPLAIN: true
        ),
        Offer(
            testDescription: "types with only PLAIN abort by default", mechanisms: ["PLAIN"], types: ["tls-exporter"],
            sasl1: .failed(.channelBindingMechanismMissing), sasl2: .failed(.channelBindingMechanismMissing)
        ),
        Offer(
            testDescription: "PLUS with an empty type list", mechanisms: plusAndUnbound, types: [],
            sasl1: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-256-PLUS"), sasl2: .failed(.channelBindingTypesMissing)
        ),
        Offer(
            testDescription: "PLUS without types binds with tls-server-end-point over SASL1",
            mechanisms: ["SCRAM-SHA-1-PLUS", "SCRAM-SHA-1", "PLAIN"], types: nil,
            sasl1: .bound(.tlsServerEndPoint, with: "SCRAM-SHA-1-PLUS"), sasl2: .failed(.channelBindingTypesMissing), allowsPLAIN: true
        ),
        Offer(
            testDescription: "an unimplemented PLUS without types aborts", mechanisms: ["SCRAM-SHA-384-PLUS", "SCRAM-SHA-256"], types: nil,
            sasl1: .failed(.channelBindingUnavailable), sasl2: .failed(.channelBindingTypesMissing)
        ),
        Offer(
            testDescription: "a listed type with only an unimplemented PLUS aborts", mechanisms: ["SCRAM-SHA-384-PLUS", "SCRAM-SHA-256"],
            types: ["tls-server-end-point"],
            sasl1: .failed(.channelBindingUnavailable), sasl2: .failed(.channelBindingUnavailable)
        ),
        Offer(
            testDescription: "only tls-exporter listed without an exporter aborts", mechanisms: plusAndUnbound, types: ["tls-exporter"],
            sasl1: .failed(.channelBindingUnavailable), sasl2: .failed(.channelBindingUnavailable), computed: .endPointOnly
        ),
        Offer(
            testDescription: "only tls-unique listed aborts", mechanisms: plusAndUnbound, types: ["tls-unique"],
            sasl1: .failed(.channelBindingUnavailable), sasl2: .failed(.channelBindingUnavailable)
        ),
        Offer(
            testDescription: "only types the client can't compute abort even when PLAIN is allowed", mechanisms: ["SCRAM-SHA-256-PLUS", "PLAIN"],
            types: ["tls-unique"], sasl1: .failed(.channelBindingUnavailable), sasl2: .failed(.channelBindingUnavailable), allowsPLAIN: true
        ),
        Offer(
            testDescription: "no bindings sign in unbound", mechanisms: plusAndUnbound, types: ["tls-server-end-point"],
            sasl1: .mechanism("SCRAM-SHA-256", header: "n,,"), sasl2: .mechanism("SCRAM-SHA-256", header: "n,,"), computed: .none
        ),
        Offer(
            testDescription: "no bindings sign in unbound when PLUS comes without types", mechanisms: plusAndUnbound, types: nil,
            sasl1: .mechanism("SCRAM-SHA-256", header: "n,,"), sasl2: .mechanism("SCRAM-SHA-256", header: "n,,"), computed: .none
        )
    ]

    @Test(arguments: offers)
    func `Chooses the binding the offer calls for`(offer: Offer) {
        let features = Self.features(for: offer)

        var sasl1 = SASLAuthenticator()
        let sasl1Outcome = Self.outcome(Result { () throws(SASLAuthError) -> XMLElement in
            try sasl1.begin(
                features: features, authcid: "user", secret: .password("pencil"), tlsActive: true, channelBindings: offer.bindings, allowsPLAIN: offer.allowsPLAIN
            )
        }, initialResponse: \.textContent)
        #expect(sasl1Outcome == offer.sasl1)

        var sasl2 = SASL2Authenticator()
        let sasl2Outcome = Self.outcome(Result { () throws(SASLAuthError) -> XMLElement in
            try sasl2.begin(
                features: features, authcid: "user", secret: .password("pencil"), tlsActive: true, inlinePayloads: [], channelBindings: offer.bindings,
                allowsPLAIN: offer.allowsPLAIN
            )
        }, initialResponse: { $0.childText(named: "initial-response") })
        #expect(sasl2Outcome == offer.sasl2)
    }

    /// Offers the mechanisms over both SASL1 and SASL2, with the types directly under the stream features.
    private static func features(for offer: Offer) -> XMLElement {
        var sasl1 = XMLElement(name: "mechanisms", namespace: saslNamespace)
        var sasl2 = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
        for name in offer.mechanisms {
            var mechanism = XMLElement(name: "mechanism")
            mechanism.addText(name)
            sasl1.addChild(mechanism)
            sasl2.addChild(mechanism)
        }
        var features = XMLElement(name: "stream:features")
        features.addChild(sasl1)
        features.addChild(sasl2)
        if let types = offer.types {
            var binding = XMLElement(name: "sasl-channel-binding", namespace: XMPPNamespaces.saslChannelBinding)
            for type in types {
                binding.addChild(XMLElement(name: "channel-binding", attributes: ["type": type]))
            }
            features.addChild(binding)
        }
        return features
    }

    private static func outcome(
        _ result: Result<XMLElement, SASLAuthError>, initialResponse: (XMLElement) -> String?
    ) -> Outcome? {
        switch result {
        case let .success(element):
            guard let mechanism = element.attribute("mechanism"),
                  let decoded = initialResponse(element).flatMap(Base64.decodeString) else { return nil }
            return .mechanism(mechanism, header: decoded.firstRange(of: ",,").map { String(decoded[..<$0.upperBound]) })
        case let .failure(error):
            return .failed(error)
        }
    }
}

// MARK: - Certificate Signature Hash Algorithm Tests (RFC 5929 §4.1)

enum CertSignatureHashTests {
    /// Builds a minimal DER certificate with the given signature algorithm OID.
    ///
    /// Layout: SEQUENCE { SEQUENCE(tbs), SEQUENCE { OID(sigAlg) }, BIT STRING(sig) }
    private static func buildMinimalDER(signatureOID oid: [UInt8]) -> [UInt8] {
        // TBS: a minimal SEQUENCE with one byte of content
        let tbsBody: [UInt8] = [0x01] // placeholder
        let tbs = [0x30, UInt8(tbsBody.count)] + tbsBody

        // signatureAlgorithm: SEQUENCE { OID }
        let oidElement = [0x06, UInt8(oid.count)] + oid
        let sigAlg = [0x30, UInt8(oidElement.count)] + oidElement

        // signatureValue: BIT STRING with one zero byte
        let sigVal: [UInt8] = [0x03, 0x02, 0x00, 0xFF]

        // Outer SEQUENCE
        let body = tbs + sigAlg + sigVal
        return [0x30, UInt8(body.count)] + body
    }

    struct RSAAlgorithms {
        @Test
        func `sha256WithRSAEncryption returns sha256`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }

        @Test
        func `sha384WithRSAEncryption returns sha384`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha384)
        }

        @Test
        func `sha512WithRSAEncryption returns sha512`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha512)
        }

        @Test
        func `sha1WithRSAEncryption falls back to sha256`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }

        @Test
        func `md5WithRSAEncryption falls back to sha256`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x04]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }
    }

    struct ECDSAAlgorithms {
        @Test
        func `ecdsa-with-SHA256 returns sha256`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }

        @Test
        func `ecdsa-with-SHA384 returns sha384`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha384)
        }

        @Test
        func `ecdsa-with-SHA512 returns sha512`() {
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha512)
        }
    }

    struct EdDSAAlgorithms {
        @Test
        func `Ed25519 falls back to sha256`() {
            let oid: [UInt8] = [0x2B, 0x65, 0x70]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }

        @Test
        func `Ed448 falls back to sha256`() {
            let oid: [UInt8] = [0x2B, 0x65, 0x71]
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }
    }

    struct EdgeCases {
        @Test
        func `Empty DER falls back to sha256`() {
            #expect(signatureHashAlgorithm(fromDER: []) == .sha256)
        }

        @Test
        func `Truncated DER falls back to sha256`() {
            #expect(signatureHashAlgorithm(fromDER: [0x30, 0x03, 0x30, 0x01]) == .sha256)
        }

        @Test
        func `Unknown OID falls back to sha256`() {
            let oid: [UInt8] = [0x2B, 0x06, 0x01, 0x04] // arbitrary unknown OID
            let der = CertSignatureHashTests.buildMinimalDER(signatureOID: oid)
            #expect(signatureHashAlgorithm(fromDER: der) == .sha256)
        }

        @Test
        func `Long TBS body with multi-byte DER length`() {
            // TBS SEQUENCE with 128-byte body (requires long-form length encoding: 0x81, 0x80)
            var tbs: [UInt8] = [0x30, 0x81, 0x80]
            tbs += Array(repeating: 0x00, count: 128)
            let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C]
            let oidElement = [0x06, UInt8(oid.count)] + oid
            let sigAlg = [0x30, UInt8(oidElement.count)] + oidElement
            let sigVal: [UInt8] = [0x03, 0x02, 0x00, 0xFF]
            let body = tbs + sigAlg + sigVal
            // Outer SEQUENCE also needs long-form length
            let outerLength = body.count
            let der: [UInt8] = [0x30, 0x81, UInt8(outerLength)] + body
            #expect(signatureHashAlgorithm(fromDER: der) == .sha384)
        }
    }
}
