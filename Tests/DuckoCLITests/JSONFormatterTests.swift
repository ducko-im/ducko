import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct JSONFormatterTests {
    let formatter = JSONFormatter()

    @Test func `output is valid JSON`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "message")
        #expect(json["from"] == "alice@example.com")
        #expect(json["body"] == "Hello!")
        #expect(json["direction"] == "incoming")
    }

    @Test func `undecryptable message is flagged and carries no body`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["undecryptable"] == "true")
        #expect(json["body"]?.isEmpty == true)
    }

    @Test func `account output is valid JSON`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "account")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["id"] == accountID.uuidString)
        #expect(json["isEnabled"] == "true")
    }

    // MARK: - formatContactWithPresence

    @Test func `contact with presence is valid JSON`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            subscription: .both,
            groups: ["Friends"],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "contact")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["presence"] == "available")
        #expect(json["name"] == "Alice")
        #expect(json["groups"] == "Friends")
    }

    @Test func `contact nil presence shows offline`() throws {
        let jid = try #require(BareJID.parse("bob@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            subscription: .to,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: nil)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["presence"] == "offline")
    }

    // MARK: - formatGroupHeader

    @Test func `group header is valid JSON`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "group_header")
        #expect(json["name"] == "Friends")
        #expect(json["count"] == "3")
    }

    // MARK: - formatEvent

    @Test func `event connected contains account field`() throws {
        let accountID = UUID()
        let jid = try #require(FullJID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.connected(jid), accountID: accountID))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "connected")
        #expect(json["account"] == accountID.uuidString)
    }

    @Test func `jingle transfer failed event keeps the raw reason token`() throws {
        let accountID = UUID()
        let event = XMPPEvent.jingleFileTransferFailed(sid: "sid-789", reason: .transportReject)
        let output = try #require(formatter.formatEvent(event, accountID: accountID))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "jingle_transfer_failed")
        #expect(json["reason"] == "transport-reject")
        #expect(json["account"] == accountID.uuidString)
    }

    @Test func `iq event returns nil`() {
        let iq = XMPPIQ(type: .result)
        let output = formatter.formatEvent(.iqReceived(iq), accountID: UUID())
        #expect(output == nil)
    }

    @Test func `subscription request is valid JSON`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatEvent(.presenceSubscriptionRequest(from: jid), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "subscription_request")
        #expect(json["from"] == "alice@example.com")
    }

    @Test func `presence event returns nil`() {
        let presence = XMPPPresence()
        let output = formatter.formatEvent(.presenceReceived(presence), accountID: UUID())
        #expect(output == nil)
    }

    // MARK: - Message Markers

    @Test func `message includes delivered`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["delivered"] == "true")
    }

    @Test func `message includes edited`() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "corrected",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: true,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["edited"] == "true")
    }

    // MARK: - New Event Types

    @Test func `delivery receipt event is valid JSON`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.deliveryReceiptReceived(messageID: "msg-1", from: jid), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "delivery_receipt")
        #expect(json["messageID"] == "msg-1")
        #expect(json["from"] == "alice@example.com")
    }

    // MARK: - Attachments

    @Test func `message with attachments includes attachment URLs`() throws {
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
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["attachments"] == "https://example.com/photo.jpg")
    }

    @Test func `message without attachments omits attachment key`() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Just text",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["attachments"] == nil)
    }

    // MARK: - Typing Indicator

    @Test func `typing indicator composing`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .composing))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "typing")
        #expect(json["state"] == "composing")
    }

    @Test func `typing indicator paused`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .paused))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "typing")
        #expect(json["state"] == "paused")
    }

    // MARK: - formatRegistrationForm

    @Test func `format legacy registration form as JSON`() throws {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .legacy,
            instructions: "Please register",
            isRegistered: false,
            hasUsername: true,
            hasPassword: true,
            hasEmail: true,
            dataFormFields: []
        ))
        let output = formatter.formatRegistrationForm(form)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "registration_form")
        #expect(json["form_kind"] == "legacy")
        #expect(json["is_registered"] == "false")
        #expect(json["instructions"] == "Please register")
        #expect(json["has_username"] == "true")
        #expect(json["has_password"] == "true")
        #expect(json["has_email"] == "true")
    }

    @Test func `format data form registration as JSON`() throws {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: true,
            hasUsername: false,
            hasPassword: false,
            hasEmail: false,
            dataFormFields: [
                DataFormField(variable: "nick", type: "text-single", label: "Nickname", values: ["bob"])
            ]
        ))
        let output = formatter.formatRegistrationForm(form)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "registration_form")
        #expect(json["form_kind"] == "data_form")
        #expect(json["is_registered"] == "true")
        #expect(json["field_nick"] == "bob")
    }

    /// Locks the structured envelope shape for `omemoRecipientsPartial` —
    /// it diverges from the file's flat-dict pattern intentionally so JSON
    /// consumers can read `dropped` as an array of `{jid, deviceID}` objects.
    /// A regression that flattens the envelope or renames a field would
    /// silently break downstream consumers.
    @Test func `omemo_recipients_partial event emits structured dropped array`() throws {
        let conversation = try #require(BareJID.parse("alice@example.com"))
        let dropped: [DroppedOMEMORecipient] = [
            .init(jid: conversation, deviceID: 1234),
            .init(jid: conversation, deviceID: 5678)
        ]
        let accountID = UUID()
        let event = XMPPEvent.omemoRecipientsPartial(conversation: conversation, droppedDevices: dropped)
        let output = try #require(formatter.formatEvent(event, accountID: accountID))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "omemo_recipients_partial")
        #expect(json["conversation"] as? String == "alice@example.com")
        #expect(json["account"] as? String == accountID.uuidString)
        #expect(json["droppedCount"] as? Int == 2)
        let droppedArray = try #require(json["dropped"] as? [[String: Any]])
        #expect(droppedArray.count == 2)
        #expect(droppedArray[0]["jid"] as? String == "alice@example.com")
        #expect(droppedArray[0]["deviceID"] as? Int == 1234)
        #expect(droppedArray[1]["deviceID"] as? Int == 5678)
    }
}
