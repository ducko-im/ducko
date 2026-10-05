import AppKit
import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import SwiftUI
import Testing
@testable import DuckoUI

@MainActor
struct ContactListOwnersTests {
    private func room(name: String = "Room") -> Conversation {
        Conversation(
            id: UUID(), accountID: UUID(), jid: BareJID(localPart: "room", domainPart: "conference.example.com")!,
            type: .groupchat, displayName: name, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
    }

    private func environment() -> AppEnvironment {
        AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
    }

    @Test
    func `width measurement follows names compact rows bounds and manual width`() {
        let measurement = ContactListMeasurement()
        var inputs = ContactListTableInputs(environment: environment())
        inputs.maxWidthPreference = 800
        inputs.incomingRows = [.room(room(name: "Short"))]
        let short = measurement.contentWidth(inputs: inputs, manualWidth: 300)
        inputs.incomingRows = [.room(room(name: String(repeating: "W", count: 12)))]
        let fitted = measurement.contentWidth(inputs: inputs, manualWidth: 300)
        inputs.isCompact = true
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 300) == fitted - AvatarView.defaultSize)
        inputs.isCompact = false
        inputs.incomingRows = [.room(room(name: String(repeating: "W", count: 35)))]
        let wide = measurement.contentWidth(inputs: inputs, manualWidth: 300)
        #expect(wide > short)
        inputs.maxWidthPreference = 320
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 300) <= 320)
        inputs.autoSizeHorizontal = false
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 407) == 407)
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 463) == 463)
    }

    @Test
    func `height measurement invalidates for caption width compact rows and row count`() {
        let environment = environment()
        let measurement = ContactListMeasurement()
        var conversation = room()
        var inputs = ContactListTableInputs(environment: environment, incomingRows: [.room(conversation)])
        var measures = 0
        let content: (ContactListRow) -> ContactListCellContent? = { row in
            measures += 1
            return ContactListCellContent(row: row, environment: environment, isCompact: inputs.isCompact, openChat: OpenChatAction { _, _ in }, toggle: { _ in }, showMenu: {})
        }
        let first = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(first.newHeights.count == 1)
        #expect(first.newHeights[0] > 0)
        _ = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(measures == 1)
        conversation.roomSubject = "A second line"
        inputs.incomingRows = [.room(conversation)]
        let caption = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(measures == 2)
        #expect(caption.newHeights[0] >= first.newHeights[0])
        _ = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 3)
        inputs.isCompact = true
        let compact = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 4)
        #expect(compact.newHeights[0] < caption.newHeights[0])
        inputs.incomingRows.append(.room(room(name: "Second room")))
        let two = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 6)
        #expect(two.newHeights.count == 2)
    }

    @Test
    func `a compact room row is as tall with an unread badge as without`() {
        let environment = environment()
        let height = { (unreadCount: Int) -> CGFloat in
            var conversation = room()
            conversation.unreadCount = unreadCount
            let inputs = ContactListTableInputs(environment: environment, incomingRows: [.room(conversation)], isCompact: true)
            return ContactListMeasurement().heights(inputs: inputs, contentWidth: 320, maxListHeight: 600) { row in
                ContactListCellContent(row: row, environment: environment, isCompact: true, openChat: OpenChatAction { _, _ in }, toggle: { _ in }, showMenu: {})
            }.newHeights[0]
        }

        #expect(height(3) == height(0))
    }

    @Test
    func `menu actions preserve row identity across a reorder and retain accessibility identifiers`() throws {
        let environment = environment()
        let target = NSView()
        var opened: ConversationKey?
        var sheet: ContactListRowSheet?
        let builder = ContactListMenuBuilder(
            openChat: OpenChatAction { jid, accountID in opened = ConversationKey(accountID: accountID, jid: jid) },
            openWindow: nil, transcriptScope: nil, presentSheet: { sheet = $0 }, requestRemoval: { _ in }, target: target, action: Selector(("unused:"))
        )
        let selectedRoom = room()
        var rows: [ContactListRow] = [.room(selectedRoom), .room(room(name: "Other"))]
        let menu = try #require(builder.menu(for: rows[0], environment: environment))
        rows.reverse()
        try #require(menu.items.first?.representedObject as? MenuCommand).run()
        #expect(opened == ConversationKey(accountID: selectedRoom.accountID, jid: selectedRoom.jid.description))
        try #require(menu.items.first { $0.title == "Invite User…" }?.representedObject as? MenuCommand).run()
        if case let .invite(conversation) = sheet {
            #expect(conversation.id == selectedRoom.id)
        } else {
            Issue.record("Expected an invitation for the selected room")
        }
        let contact = try Contact(id: UUID(), accountID: UUID(), jid: #require(BareJID(localPart: "peer", domainPart: "example.com")), name: nil, subscription: .both, groups: [], isBlocked: false, createdAt: Date())
        let contactMenu = try #require(builder.menu(for: .contact(sectionName: "Friends", contact: contact), environment: environment))
        #expect(contactMenu.items.first { $0.title == "Get Info" }?.accessibilityIdentifier() == "contact-context-get-info")
        #expect(contactMenu.items.first { $0.title == "History" }?.accessibilityIdentifier() == "contact-context-history")
        #expect(contactMenu.items.allSatisfy { $0.isSeparatorItem || $0.target === target })
    }
}
