import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct BlockListFormatterTests {
    @Test func `a block-list entry prints its whole address in every formatter`() throws {
        let entry = try BlockListEntry(.full(#require(FullJID.parse("alice@example.com/laptop"))))

        #expect(PlainFormatter().formatBlockListEntry(entry) == "alice@example.com/laptop")
        #expect(ANSIFormatter().formatBlockListEntry(entry) == "\u{001B}[1malice@example.com/laptop\u{001B}[0m")
        let json = try #require(JSONSerialization.jsonObject(with: Data(JSONFormatter().formatBlockListEntry(entry).utf8)) as? [String: String])
        #expect(json == ["type": "block_list_entry", "jid": "alice@example.com/laptop"])
    }
}
