import DuckoXMPP
import Foundation

// DuckoXMPP must not import Foundation, so its error types gain `LocalizedError` here. Without it,
// `error.localizedDescription` renders as "The operation couldn't be completed. (DuckoXMPP.XMPPClientError error 4.)".

extension XMPPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .alreadyConnected: "Already connected to the server"
        case let .connectionFailed(reason): "Could not connect to the server: \(reason)"
        case let .sendFailed(reason): "Could not send data to the server: \(reason)"
        case .tlsRequired: "The server does not offer a secure connection"
        case let .tlsNegotiationFailed(reason): "Secure connection failed: \(reason)"
        case let .untrustedCertificate(reason): "The server's certificate is not trusted: \(reason.displayText)"
        case let .authenticationFailed(failure): "Authentication failed: \(failure.message)"
        case .plainSignInRefused:
            "Sign-in refused: the server offers only a sign-in that sends the password, and this account has signed in without sending it before"
        case let .bindingFailed(reason): "The server did not bind a resource: \(reason)"
        case let .sessionFailed(reason): "The server did not establish a session: \(reason)"
        case let .unexpectedStreamState(reason): "Unexpected response from the server: \(reason)"
        case let .sessionSetupFailed(error): error.localizedDescription
        case .timeout: "The server did not respond in time"
        case .streamManagementBusy: "Stream management is busy"
        case let .invalidDomain(domain): "Invalid server domain: \(domain)"
        }
    }
}

extension XMPPStanzaError: LocalizedError {
    public var errorDescription: String? {
        "Request failed: \(displayText)"
    }
}

extension XMPPRegistrationClient.RegistrationClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(reason): "Could not connect to the server: \(reason)"
        case .tlsNegotiationFailed: "Could not establish a secure connection to the server"
        case .registrationNotSupported: "The server does not support account registration"
        case let .registrationFailed(reason): "Registration failed: \(reason)"
        case .unexpectedResponse: "Unexpected response from the server"
        case .connectionClosed: "The server closed the connection, try registering again"
        }
    }
}

extension RegistrationModule.RegistrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .registrationNotSupported: "The server does not support account registration"
        }
    }
}

extension BlockingModule.BlockingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .blockingNotSupported: "The server does not support blocking"
        }
    }
}

extension MUCModule.MUCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidNickname(nickname): "Invalid nickname: \(nickname)"
        }
    }
}

extension HTTPUploadModule.HTTPUploadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .noUploadServiceFound: "The server does not offer file uploads"
        case let .fileTooLarge(maxSize):
            "The file is too large: the server accepts up to \(ByteCountFormatter.string(fromByteCount: maxSize, countStyle: .file))"
        case let .slotRequestFailed(reason): "Could not request an upload slot: \(reason)"
        }
    }
}

extension JingleModule.JingleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected, .noConnectedJID: notConnectedDescription
        case .sessionNotFound: "The file transfer session was not found"
        case .alreadyAccepted: "The file transfer was already accepted"
        case let .transportNegotiationFailed(reason): "File transfer negotiation failed: \(reason)"
        case let .transportFailed(reason): "File transfer failed: \(reason)"
        }
    }
}

extension ChannelSearchModule.ChannelSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .noSearchServiceFound: "The server does not offer channel search"
        case .rateLimited: "The server is limiting channel searches"
        }
    }
}

extension OMEMOModuleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSetUp: "OMEMO encryption is not set up"
        case .bundleNotFound: "The recipient's encryption keys were not found"
        case .noSession: "No encryption session exists for the sending device"
        case .notForThisDevice: "The message was not encrypted for this device"
        case .unknownPreKey: "The encrypted message uses a key this device no longer has"
        case .replayedKeyExchange: "The encrypted message repeats one already received"
        case .invalidKeyData: "The encrypted message contains invalid key data"
        case .invalidHeader: "The encrypted message has an invalid header"
        case .invalidPayload: "The encrypted message has an invalid payload"
        case .noUsableRecipientDevices: "None of the recipient's devices can receive encrypted messages"
        case let .cryptographicFailure(reason): "Encryption error: \(reason)"
        }
    }
}
