import CryptoKit

/// A legacy message's `<payload>`: its body encrypted with AES-128-GCM under a fresh key. The key travels to each
/// recipient device inside the ratchet message, together with the GCM tag, and the nonce travels as the header's `<iv>`.
package struct OMEMOLegacyPayload {
    static let keyLength = 16
    static let tagLength = 16

    package let ciphertext: [UInt8]
    /// The GCM nonce: 12 bytes as Ducko and current clients send it, or 16 as some older clients do.
    package let iv: [UInt8]
    /// The key followed by the GCM tag (32 bytes): what each recipient's ratchet message carries.
    package let keyMaterial: [UInt8]

    init(ciphertext: [UInt8], iv: [UInt8], keyMaterial: [UInt8]) {
        self.ciphertext = ciphertext
        self.iv = iv
        self.keyMaterial = keyMaterial
    }

    /// Encrypts `body` under a fresh random key, with the 12-byte nonce CryptoKit generates.
    package init(encrypting body: String) throws {
        let key = SymmetricKey(size: .bits128)
        let sealed = try AES.GCM.seal(Array(body.utf8), using: key)
        self.ciphertext = Array(sealed.ciphertext)
        self.iv = sealed.nonce.withUnsafeBytes { Array($0) }
        self.keyMaterial = key.withUnsafeBytes { Array($0) } + Array(sealed.tag)
    }

    /// Verifies the tag and decrypts the body, without the spaces and tabs a sender pads it with at either end. Throws
    /// `invalidPayload` when the parts are malformed or the body is not UTF-8, and `hmacVerificationFailed` when the tag
    /// does not match.
    func decryptBody() throws -> String {
        guard keyMaterial.count == Self.keyLength + Self.tagLength, [12, 16].contains(iv.count), !ciphertext.isEmpty
        else { throw OMEMOModuleError.invalidPayload }
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: Array(keyMaterial.dropFirst(Self.keyLength))
        )
        let plaintext: [UInt8]
        do {
            plaintext = try Array(AES.GCM.open(sealedBox, using: SymmetricKey(data: Array(keyMaterial.prefix(Self.keyLength)))))
        } catch CryptoKitError.authenticationFailure {
            throw OMEMOCryptoError.hmacVerificationFailed
        }
        guard let body = String(validating: Self.trimmingPadding(plaintext), as: UTF8.self) else {
            throw OMEMOModuleError.invalidPayload
        }
        return body
    }

    /// Only spaces and tabs count as padding, so a body's leading and trailing line breaks stay.
    private static func trimmingPadding(_ plaintext: [UInt8]) -> ArraySlice<UInt8> {
        let isPadding: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        guard let start = plaintext.firstIndex(where: { !isPadding($0) }),
              let end = plaintext.lastIndex(where: { !isPadding($0) })
        else { return [] }
        return plaintext[start ... end]
    }
}

package extension OMEMOLegacyPayload {
    /// The key material and `<iv>` of an `<encrypted>` element without a `<payload>`, which only advances the session.
    struct KeyTransport {
        package let keyMaterial: [UInt8]
        package let iv: [UInt8]

        /// A fresh random key as the whole key material and a fresh random 12-byte IV, as the reference implementation
        /// and Conversations send them.
        package init() {
            self.keyMaterial = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
            self.iv = AES.GCM.Nonce().withUnsafeBytes { Array($0) }
        }

        /// Throws `invalidPayload` unless the key material received in an element without a `<payload>` is a key alone
        /// or a key followed by a tag. Nothing is decrypted with it.
        static func validate(receivedKeyMaterial keyMaterial: [UInt8]) throws {
            guard [keyLength, keyLength + tagLength].contains(keyMaterial.count) else {
                throw OMEMOModuleError.invalidPayload
            }
        }
    }
}
