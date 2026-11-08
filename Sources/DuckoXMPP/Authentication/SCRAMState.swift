import CryptoKit

/// Channel binding configuration for SCRAM mechanisms (RFC 5802 §6).
enum ChannelBindingMode {
    /// No channel binding support (GS2 header `n,,`).
    case none
    /// Client supports CB but server didn't offer -PLUS (GS2 header `y,,`).
    case clientSupportsButNotUsed
    /// Active channel binding (GS2 header `p=<type>,,` with binding data).
    case bound(type: String, data: [UInt8])
}

/// Generic SCRAM state machine per RFC 5802.
struct SCRAMState<H: HashFunction>: SCRAMSession where H.Digest: Sendable {
    private var phase: Phase = .initial
    private var password = ""
    private var clientNonce = ""
    private var clientFirstMessageBare = ""
    private var serverSignature: [UInt8] = []
    private let nonceGenerator: @Sendable () -> String
    private let channelBindingMode: ChannelBindingMode
    private let downgradeContext: SCRAMDowngradeContext

    /// Minimum PBKDF2 iteration count per RFC 5802 §5.1.
    static var minimumIterationCount: Int {
        4096
    }

    init(
        channelBindingMode: ChannelBindingMode = .none,
        downgradeContext: SCRAMDowngradeContext = .empty,
        nonceGenerator: @Sendable @escaping () -> String = randomNonce
    ) {
        self.channelBindingMode = channelBindingMode
        self.downgradeContext = downgradeContext
        self.nonceGenerator = nonceGenerator
    }

    // MARK: - Client Messages

    /// Produces the `client-first-message` and transitions to `.waitingForServerFirst`.
    mutating func clientFirstMessage(authcid: String, password: String) -> String {
        self.password = password
        clientNonce = nonceGenerator()

        let escapedUser = escapeUsername(authcid)
        clientFirstMessageBare = "n=\(escapedUser),r=\(clientNonce)"
        phase = .waitingForServerFirst

        // gs2-header per RFC 5802 §7
        let gs2Header = switch channelBindingMode {
        case .none: "n,,"
        case .clientSupportsButNotUsed: "y,,"
        case let .bound(type, _): "p=\(type),,"
        }
        return "\(gs2Header)\(clientFirstMessageBare)"
    }

    /// Processes `server-first-message` and produces `client-final-message`.
    mutating func clientFinalMessage(serverFirstMessage: String) -> Result<String, SASLAuthError> {
        guard phase == .waitingForServerFirst else {
            return .failure(.invalidState("Expected waitingForServerFirst, got \(phase)"))
        }

        // Parse server-first-message: r=<nonce>,s=<salt>,i=<iterations>
        let attrs = parseAttributes(serverFirstMessage)
        guard let combinedNonce = attrs["r"],
              let saltB64 = attrs["s"],
              let iterStr = attrs["i"],
              let iterations = Int(iterStr)
        else {
            return .failure(.malformedChallenge("Missing r, s, or i in server-first-message"))
        }

        // Server nonce must start with our client nonce
        guard combinedNonce.hasPrefix(clientNonce) else {
            return .failure(.invalidServerNonce)
        }

        if let error = downgradeError(in: attrs) {
            return .failure(error)
        }

        guard iterations >= Self.minimumIterationCount else {
            return .failure(.iterationCountTooLow(iterations))
        }

        guard let salt = Base64.decode(saltB64) else {
            return .failure(.invalidBase64)
        }

        // Derive keys via PBKDF2
        let saltedPassword = pbkdf2(password: Array(password.utf8), salt: salt, iterations: iterations)
        let clientKey = hmac(key: saltedPassword, data: Array("Client Key".utf8))
        let storedKey = Array(H.hash(data: clientKey))
        let serverKey = hmac(key: saltedPassword, data: Array("Server Key".utf8))

        // Build auth message with channel binding per RFC 5802 §7
        let gs2HeaderBytes: [UInt8] = switch channelBindingMode {
        case .none: Array("n,,".utf8)
        case .clientSupportsButNotUsed: Array("y,,".utf8)
        case let .bound(type, _): Array("p=\(type),,".utf8)
        }
        let cbPayload: [UInt8] = switch channelBindingMode {
        case .none, .clientSupportsButNotUsed: gs2HeaderBytes
        case let .bound(_, data): gs2HeaderBytes + data
        }
        let channelBinding = Base64.encode(cbPayload)
        let clientFinalWithoutProof = "c=\(channelBinding),r=\(combinedNonce)"
        let authMessage = "\(clientFirstMessageBare),\(serverFirstMessage),\(clientFinalWithoutProof)"

        // Client signature and proof
        let clientSignature = hmac(key: storedKey, data: Array(authMessage.utf8))
        let clientProof = zip(clientKey, clientSignature).map { $0 ^ $1 }

        // Server signature for later verification
        serverSignature = hmac(key: serverKey, data: Array(authMessage.utf8))

        phase = .waitingForServerFinal

        let proof = Base64.encode(clientProof)
        return .success("\(clientFinalWithoutProof),p=\(proof)")
    }

    /// Verifies `server-final-message`.
    mutating func verifyServerFinal(serverFinalMessage: String) -> Result<Void, SASLAuthError> {
        guard phase == .waitingForServerFinal else {
            return .failure(.invalidState("Expected waitingForServerFinal, got \(phase)"))
        }

        let attrs = parseAttributes(serverFinalMessage)

        if let error = attrs["e"] {
            return .failure(.malformedChallenge(error))
        }

        guard let verifier = attrs["v"],
              let serverSig = Base64.decode(verifier)
        else {
            return .failure(.malformedChallenge("Missing v in server-final-message"))
        }

        guard serverSig == serverSignature else {
            return .failure(.serverSignatureMismatch)
        }

        phase = .completed
        return .success(())
    }

    /// Checks the server's view of the offer (XEP-0474 `h`) and of the TLS version (XEP-0515 `t`) against what this
    /// side received and negotiated, so a mismatch in either fails before the proof goes out.
    private func downgradeError(in attrs: [String: String]) -> SASLAuthError? {
        if let hash = attrs["h"], hash != Base64.encode(Array(H.hash(data: xep0474HashInput(downgradeContext)))) {
            return .mechanismListTampered
        }
        if let version = attrs["t"], version != downgradeContext.tlsVersion.map(xep0515VersionAttribute) {
            return .tlsVersionTampered
        }
        return nil
    }

    private enum Phase {
        case initial
        case waitingForServerFirst
        case waitingForServerFinal
        case completed
    }

    /// PBKDF2 using HMAC<H>.
    private func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        // U1 = HMAC(password, salt || INT(1))
        var saltPlusOne = salt
        saltPlusOne.append(contentsOf: [0, 0, 0, 1])

        var u = hmac(key: password, data: saltPlusOne)
        var result = u

        for _ in 1 ..< iterations {
            u = hmac(key: password, data: u)
            for j in 0 ..< result.count {
                result[j] ^= u[j]
            }
        }

        return result
    }

    /// HMAC<H> producing raw bytes.
    private func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<H>.authenticationCode(for: data, using: symmetricKey)
        return Array(mac)
    }

    /// Parses comma-separated `key=value` attributes from a SCRAM message.
    ///
    /// SCRAM attribute values don't contain unescaped commas, so a simple split works.
    private func parseAttributes(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",", omittingEmptySubsequences: true) {
            guard let eqIndex = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex ..< eqIndex])
            let value = String(part[part.index(after: eqIndex)...])
            result[key] = value
        }
        return result
    }

    /// Escapes `=` → `=3D` and `,` → `=2C` in SCRAM usernames per RFC 5802 §5.1.
    private func escapeUsername(_ username: String) -> String {
        var result = ""
        for char in username {
            switch char {
            case "=": result += "=3D"
            case ",": result += "=2C"
            default: result.append(char)
            }
        }
        return result
    }

    /// Default nonce generator: 24 random bytes, base64-encoded.
    static func randomNonce() -> String {
        Base64.encode((0 ..< 24).map { _ in UInt8.random(in: 0 ... 255) })
    }
}
