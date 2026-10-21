/// Why an encrypted message shows a notice in place of its text.
public enum UndecryptableReason: Codable, Sendable, Equatable {
    case decryptionFailed
    /// The sender did not encrypt it for this device.
    case notForThisDevice
    /// Its encryption names another sender, recipient or time than the message.
    case mismatchedEnvelope
    /// A room message whose sender the room does not reveal, so it cannot be decrypted.
    case senderHidden
    /// It is encrypted with a method Ducko cannot decrypt, called `name`.
    case otherMethod(name: String)

    public var text: String {
        switch self {
        case .decryptionFailed: "This message could not be decrypted"
        case .notForThisDevice: "This message was not encrypted for this device"
        case .mismatchedEnvelope: "This message could not be trusted, because its encryption names another sender, recipient or time"
        case .senderHidden: "This message could not be decrypted, because the room does not reveal who sent it"
        case let .otherMethod(name): "This message is encrypted with \(name), which Ducko cannot decrypt"
        }
    }
}
