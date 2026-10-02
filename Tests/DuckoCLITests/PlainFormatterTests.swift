import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct PlainFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatMessage

    @Test func `format message incoming`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Hello!",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("<-"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("Hello!"))
    }

    @Test func `format message outgoing`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi there",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("->"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("Hi there"))
    }

    @Test func `format message undecryptable`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            isEncrypted: true,
            isUndecryptable: true
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("alice@example.com: error: This message could not be decrypted"))
    }

    // MARK: - formatAccount

    @Test func `format account`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let accountID = UUID()
        let account = Account(
            id: accountID,
            jid: jid,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        let output = formatter.formatAccount(account)
        #expect(output.contains("alice@example.com"))
        #expect(output.contains(accountID.uuidString))
    }

    // MARK: - formatContactWithPresence

    @Test func `format contact with presence available`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        #expect(output.contains("[+]"))
        #expect(output.contains("Alice"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("[both]"))
    }

    @Test func `format contact with presence away`() throws {
        let jid = try #require(BareJID.parse("bob@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Bob",
            subscription: .to,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .away)
        #expect(output.contains("[~]"))
    }

    @Test func `format contact with presence DND`() throws {
        let jid = try #require(BareJID.parse("carol@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Carol",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .dnd)
        #expect(output.contains("[-]"))
    }

    @Test func `format contact with presence offline`() throws {
        let jid = try #require(BareJID.parse("dave@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Dave",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: nil)
        #expect(output.contains("[ ]"))
    }

    @Test func `format contact with presence uses local alias`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            localAlias: "Ally",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        #expect(output.contains("Ally"))
        #expect(!output.hasPrefix("[+] Alice"))
    }

    // MARK: - formatGroupHeader

    @Test func `format group header`() throws {
        let group = try ContactGroup(id: "friends", name: "Friends", contacts: [
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("a@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            ),
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("b@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            ),
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("c@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            )
        ])
        let output = formatter.formatGroupHeader(group)
        #expect(output.contains("Friends"))
        #expect(output.contains("3"))
    }

    // MARK: - formatPresence

    @Test func `format presence with message`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = formatter.formatPresence(jid: jid, status: "away", message: "Gone fishing")
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("away"))
        #expect(output.contains("Gone fishing"))
    }

    @Test func `format presence without message`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = formatter.formatPresence(jid: jid, status: "available", message: nil)
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("available"))
    }

    // MARK: - formatError

    @Test func `format error`() {
        let output = formatter.formatError(CLIError.noAccounts)
        #expect(output.hasPrefix("error:"))
    }

    // MARK: - formatEvent

    @Test func `format event connected`() throws {
        let jid = try #require(FullJID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.connected(jid), accountID: UUID()))
        #expect(output.contains("connected"))
    }

    @Test func `format event disconnected`() throws {
        let output = try #require(formatter.formatEvent(.disconnected(.requested), accountID: UUID()))
        #expect(output.contains("disconnected"))
    }

    @Test func `format event disconnected by stream error`() throws {
        let output = try #require(formatter.formatEvent(.disconnected(.streamError(.systemShutdown, text: nil)), accountID: UUID()))
        #expect(output.contains("disconnected: The server is shutting down"))
        #expect(!output.contains("stream error"))
    }

    @Test func `format event subscription request`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatEvent(.presenceSubscriptionRequest(from: jid), accountID: UUID()))
        #expect(output.contains("Subscription request from"))
        #expect(output.contains("alice@example.com"))
    }

    @Test func `format event IQ returns nil`() {
        let iq = XMPPIQ(type: .result)
        let output = formatter.formatEvent(.iqReceived(iq), accountID: UUID())
        #expect(output == nil)
    }

    @Test func `format event delivery receipt`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.deliveryReceiptReceived(messageID: "msg-1", from: jid), accountID: UUID()))
        #expect(output.contains("delivery receipt"))
        #expect(output.contains("msg-1"))
        #expect(output.contains("alice@example.com"))
    }

    @Test func `format event message corrected`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.messageCorrected(originalID: "msg-1", newBody: "fixed", from: jid), accountID: UUID()))
        #expect(output.contains("corrected"))
        #expect(output.contains("fixed"))
    }

    @Test func `format event message error`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let error = XMPPStanzaError(errorType: .modify, condition: .notAllowed, text: "not allowed")
        let output = try #require(formatter.formatEvent(.messageError(messageID: "msg-1", from: jid, error: error), accountID: UUID()))
        #expect(output.contains("error"))
        #expect(output.contains("not allowed"))
    }

    // MARK: - formatMessage /me

    @Test func `format me action outgoing uses account JID`() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "recipient@example.com",
            body: "/me waves",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let accountJID = try #require(BareJID.parse("me@example.com"))
        let output = formatter.formatMessage(message, accountJID: accountJID)
        #expect(output.contains("* me@example.com waves"))
        #expect(!output.contains("recipient@example.com"))
    }

    @Test func `format me action outgoing falls back to fromJID without accountJID`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "recipient@example.com",
            body: "/me waves",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("* recipient@example.com waves"))
    }

    @Test func `format me action incoming uses fromJID`() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "/me waves",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let accountJID = try #require(BareJID.parse("me@example.com"))
        let output = formatter.formatMessage(message, accountJID: accountJID)
        #expect(output.contains("* alice@example.com waves"))
        #expect(!output.contains("me@example.com"))
    }

    // MARK: - formatMessage Markers

    @Test func `format message delivered`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("[delivered]"))
    }

    @Test func `format message delivered not shown for incoming`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(!output.contains("[delivered]"))
    }

    @Test func `format message edited`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "corrected text",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: true,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("[edited]"))
    }

    @Test func `format message error`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "failed message",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            errorText: "service unavailable"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("[error: service unavailable]"))
    }

    // MARK: - Attachments

    /// A received file carries no body of its own, so the sender line is the only place its name can appear, and it
    /// must appear there once.
    @Test func `file-only message names the file once, on the sender line`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [Attachment(id: UUID(), url: "file:///tmp/report.pdf", fileName: "report.pdf")]
        )
        let output = formatter.formatMessage(message)
        let senderLine = output.components(separatedBy: "\n")[0]
        #expect(senderLine.contains("report.pdf"))
        #expect(output.components(separatedBy: "report.pdf").count - 1 == 1)
    }

    /// Only the attachment the sender line names is skipped; the rest of an empty-body message still gets its lines.
    @Test func `file-only message with several attachments lists the ones after the first`() {
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "alice@example.com", body: "",
            timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat",
            attachments: [
                Attachment(id: UUID(), url: "https://example.com/first.pdf", fileName: "first.pdf"),
                Attachment(id: UUID(), url: "https://example.com/second.pdf", fileName: "second.pdf")
            ]
        )
        let output = formatter.formatMessage(message)
        #expect(output.components(separatedBy: "first.pdf").count - 1 == 1)
        #expect(output.contains("second.pdf"))
    }

    @Test func `message with attachments includes file info`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Check this out",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [Attachment(id: UUID(), url: "https://example.com/photo.jpg", fileName: "photo.jpg")]
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("https://example.com/photo.jpg"))
        #expect(output.contains("photo.jpg"))
    }

    @Test func `message with multiple attachments includes all`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Two files",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [
                Attachment(id: UUID(), url: "https://example.com/a.jpg", fileName: "a.jpg"),
                Attachment(id: UUID(), url: "https://example.com/b.pdf", fileName: "b.pdf")
            ]
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("https://example.com/a.jpg"))
        #expect(output.contains("https://example.com/b.pdf"))
    }

    // MARK: - formatTypingIndicator

    @Test func `format typing indicator typing`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .composing))
        #expect(output.contains("typing"))
        #expect(output.contains("alice@example.com"))
    }

    @Test func `format typing indicator not typing`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = formatter.formatTypingIndicator(from: jid, state: .paused)
        #expect(output == nil)
    }

    // MARK: - formatRegistrationForm

    @Test func `format legacy registration form`() {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .legacy,
            instructions: "Please provide credentials",
            isRegistered: false,
            hasUsername: true,
            hasPassword: true,
            hasEmail: true,
            dataFormFields: []
        ))
        let output = formatter.formatRegistrationForm(form)
        #expect(output.contains("Legacy"))
        #expect(output.contains("Not registered"))
        #expect(output.contains("Please provide credentials"))
        #expect(output.contains("Username"))
        #expect(output.contains("Password"))
        #expect(output.contains("Email"))
    }

    @Test func `format data form registration`() {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: true,
            hasUsername: false,
            hasPassword: false,
            hasEmail: false,
            dataFormFields: [
                DataFormField(variable: "username", type: "text-single", label: "Username", values: ["alice"]),
                DataFormField(variable: "FORM_TYPE", type: "hidden", values: ["jabber:iq:register"])
            ]
        ))
        let output = formatter.formatRegistrationForm(form)
        #expect(output.contains("Data Form"))
        #expect(output.contains("Registered"))
        #expect(output.contains("Username: alice"))
        #expect(!output.contains("FORM_TYPE"))
    }

    /// Locks the user-visible wording for `omemoRecipientsPartial`. The line
    /// must include the dropped count, the conversation JID, and the
    /// "bundles missing" reason so operators can correlate to peer state.
    @Test func `omemoRecipientsPartial event renders count, conversation, reason`() throws {
        let conversation = try #require(BareJID.parse("alice@example.com"))
        let dropped: [DroppedOMEMORecipient] = [
            .init(jid: conversation, deviceID: 1234),
            .init(jid: conversation, deviceID: 5678)
        ]
        let event = XMPPEvent.omemoRecipientsPartial(conversation: conversation, droppedDevices: dropped)
        let output = try #require(formatter.formatEvent(event, accountID: UUID()))
        #expect(output.contains("OMEMO"))
        #expect(output.contains("2 device"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("bundles missing"))
    }
}
