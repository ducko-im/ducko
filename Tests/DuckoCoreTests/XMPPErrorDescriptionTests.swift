import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

struct XMPPErrorDescriptionTests {
    @Test func `XMPPClientError.unexpectedStreamState renders a readable message`() {
        let error: any Error = XMPPClientError.unexpectedStreamState("Expected stream opened")
        #expect(error.localizedDescription == "Unexpected response from the server: Expected stream opened")
    }

    @Test func `XMPPClientError.timeout renders a readable message`() {
        let error: any Error = XMPPClientError.timeout
        #expect(error.localizedDescription == "The server did not respond in time")
    }

    @Test(arguments: [
        (XMPPClientError.connectionFailed("Connection refused"), "Could not connect to the server: Connection refused"),
        (XMPPClientError.sendFailed("Broken pipe"), "Could not send data to the server: Broken pipe"),
        (XMPPClientError.tlsNegotiationFailed("SSL protocol error"), "Secure connection failed: SSL protocol error")
    ])
    func `XMPPClientError transport cases render a readable message`(error: XMPPClientError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (XMPPRegistrationClient.RegistrationClientError.connectionFailed("Invalid domain: bad"), "Could not connect to the server: Invalid domain: bad"),
        (XMPPRegistrationClient.RegistrationClientError.tlsNegotiationFailed, "Could not establish a secure connection to the server"),
        (XMPPRegistrationClient.RegistrationClientError.registrationNotSupported, "The server does not support account registration"),
        (XMPPRegistrationClient.RegistrationClientError.registrationFailed("The username is already taken"), "Registration failed: The username is already taken"),
        (XMPPRegistrationClient.RegistrationClientError.unexpectedResponse, "Unexpected response from the server")
    ])
    func `RegistrationClientError renders a readable message`(
        error: XMPPRegistrationClient.RegistrationClientError, expected: String
    ) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (RegistrationModule.RegistrationError.notConnected, "Not connected to the server"),
        (RegistrationModule.RegistrationError.registrationNotSupported, "The server does not support account registration")
    ])
    func `RegistrationError renders a readable message`(error: RegistrationModule.RegistrationError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test func `MUCError renders a readable message`() {
        let error: any Error = MUCModule.MUCError.invalidNickname("@bad")
        #expect(error.localizedDescription == "Invalid nickname: @bad")
    }

    @Test(arguments: [
        (HTTPUploadModule.HTTPUploadError.notConnected, "Not connected to the server"),
        (HTTPUploadModule.HTTPUploadError.noUploadServiceFound, "The server does not offer file uploads"),
        (HTTPUploadModule.HTTPUploadError.fileTooLarge(maxSize: 1_000_000), "The file is too large: the server accepts up to 1 MB"),
        (HTTPUploadModule.HTTPUploadError.slotRequestFailed("Missing PUT URL"), "Could not request an upload slot: Missing PUT URL")
    ])
    func `HTTPUploadError renders a readable message`(error: HTTPUploadModule.HTTPUploadError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (JingleModule.JingleError.notConnected, "Not connected to the server"),
        (JingleModule.JingleError.sessionNotFound, "The file transfer session was not found"),
        (JingleModule.JingleError.noConnectedJID, "Not connected to the server"),
        (JingleModule.JingleError.alreadyAccepted, "The file transfer was already accepted"),
        (
            JingleModule.JingleError.transportNegotiationFailed("The contact rejected the connection method"),
            "File transfer negotiation failed: The contact rejected the connection method"
        ),
        (JingleModule.JingleError.transportFailed("Broken pipe"), "File transfer failed: Broken pipe")
    ])
    func `JingleError renders a readable message`(error: JingleModule.JingleError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (ChannelSearchModule.ChannelSearchError.notConnected, "Not connected to the server"),
        (ChannelSearchModule.ChannelSearchError.noSearchServiceFound, "The server does not offer channel search")
    ])
    func `ChannelSearchError renders a readable message`(error: ChannelSearchModule.ChannelSearchError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (OMEMOModuleError.notSetUp, "OMEMO encryption is not set up"),
        (OMEMOModuleError.bundleNotFound, "The recipient's encryption keys were not found"),
        (OMEMOModuleError.noSession, "No encryption session exists for the sending device"),
        (OMEMOModuleError.notForThisDevice, "The message was not encrypted for this device"),
        (OMEMOModuleError.invalidKeyData, "The encrypted message contains invalid key data"),
        (OMEMOModuleError.invalidHeader, "The encrypted message has an invalid header"),
        (OMEMOModuleError.invalidPayload, "The encrypted message has an invalid payload"),
        (OMEMOModuleError.noUsableRecipientDevices, "None of the recipient's devices can receive encrypted messages"),
        (OMEMOModuleError.cryptographicFailure("Message authentication failed"), "Encryption error: Message authentication failed")
    ])
    func `OMEMOModuleError renders a readable message`(error: OMEMOModuleError, expected: String) {
        let error: any Error = error
        #expect(error.localizedDescription == expected)
    }

    @Test func `XMPPStanzaError prefers the server text`() {
        let error: any Error = XMPPStanzaError(errorType: .cancel, condition: .itemNotFound, text: "No such node")
        #expect(error.localizedDescription == "Request failed: No such node")
    }

    @Test func `XMPPStanzaError falls back to the condition`() {
        let error: any Error = XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
        #expect(error.localizedDescription == "Request failed: The requested item was not found")
    }
}
