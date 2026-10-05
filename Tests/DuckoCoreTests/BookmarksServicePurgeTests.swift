import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let resumedJID = FullJID.parse("alice@example.com/ducko")!

enum BookmarksServicePurgeTests {
    struct Purge {
        @Test
        @MainActor
        func `A requested disconnect drops the account's bookmarks for good`() async {
            let service = BookmarksService()
            let accountID = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)
            #expect(!service.bookmarks.isEmpty)

            await service.handleEvent(.disconnected(.requested), accountID: accountID)
            #expect(service.bookmarks.isEmpty)

            await service.handleEvent(.streamResumed(resumedJID), accountID: accountID)
            #expect(service.bookmarks.isEmpty)
        }

        @Test
        @MainActor
        func `A dropped stream hides the account's bookmarks until it resumes`() async {
            let service = BookmarksService()
            let accountID = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)

            await service.handleEvent(.disconnected(.connectionLost("Stream ended")), accountID: accountID)
            #expect(service.bookmarks.isEmpty)

            await service.handleEvent(.streamResumed(resumedJID), accountID: accountID)
            #expect(service.bookmarks.map(\.jidString) == ["room@conference.example.com"])
        }

        @Test
        @MainActor
        func `A fresh session drops the bookmarks kept through a drop`() async {
            let service = BookmarksService()
            let accountID = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)
            await service.handleEvent(.disconnected(.connectionLost("Stream ended")), accountID: accountID)

            await service.handleEvent(.connected(resumedJID), accountID: accountID)

            #expect(service.bookmarks.isEmpty)
        }

        @Test
        @MainActor
        func `purgeAccount clears only the targeted account's bookmarks`() async {
            let service = BookmarksService()
            let accountA = UUID()
            let accountB = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room-a@conference.example.com")], accountID: accountA)
            service.setBookmarksForTesting([RoomBookmark(jidString: "room-b@conference.example.com")], accountID: accountB)
            #expect(service.bookmarks.count == 2)

            await service.handleEvent(.disconnected(.connectionLost("Stream ended")), accountID: accountA)

            service.purgeAccount(accountA)
            await service.handleEvent(.streamResumed(resumedJID), accountID: accountA)

            #expect(service.bookmarks.count == 1)
            #expect(service.bookmarks.first?.jidString == "room-b@conference.example.com")
        }
    }
}
