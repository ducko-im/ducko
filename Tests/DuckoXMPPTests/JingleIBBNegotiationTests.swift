import Testing
@testable import DuckoXMPP

/// A content offering a 3-byte file over IBB stream `ibb-sid` from the start.
private let ibbFirstContent = JingleContent(
    name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
    transport: .ibb(IBBTransport(sid: "ibb-sid", blockSize: 4096))
).toXML()

private func isIBB(_ child: String, seq: Int? = nil) -> @Sendable (XMLElement) -> Bool {
    { iq in
        guard let element = iq.child(named: child, namespace: XMPPNamespaces.ibb) else { return false }
        return seq == nil || element.attribute("seq") == seq.map(String.init)
    }
}

enum JingleIBBNegotiationTests {
    struct IBBFirstOffers {
        @Test
        func `An offer that opens over IBB completes without a SOCKS5 candidate-error`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-1", payload: [ibbFirstContent])
            try await harness.module.acceptFileTransfer(sid: "sid-1")

            try harness.deliver(JingleInitiatorHarness.ibbOpen(), id: "open")
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "open", type: "result")) != nil)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount { if case .jingleFileTransferCompleted("sid-1", .ibb) = $0 { true } else { false } } == 1)
            #expect(harness.sentJingleCount(action: JingleAction.transportInfo.rawValue) == 0)
        }

        @Test
        func `An offer naming another session's IBB stream is refused`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try harness.receive(action: JingleAction.transportReplace.rawValue, sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])

            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-2", payload: [ibbFirstContent])
            let terminate = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)?.child(named: "jingle"))
            #expect(terminate.attribute("sid") == "sid-2")
            #expect(terminate.child(named: "reason")?.child(named: "failed-transport") != nil)
            #expect(harness.receivedOffers().map(\.sid) == ["sid-1"])
        }
    }

    struct BlockSize {
        /// A responder may only lower the offer's 4096-byte block-size (XEP-0261).
        @Test(arguments: [(2048, [2048, 2048, 904]), (8192, [4096, 904])])
        func `A transport-accept's block-size bounds the blocks only downward`(acceptedBlockSize: Int, expectedBlocks: [Int]) async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))])
            let replace = try #require(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue))
            let ibbSID = try #require(replace.child(named: "jingle")?.child(named: "content")?.child(named: "transport")?.attribute("sid"))

            var accepted = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            accepted.addChild(IBBTransport(sid: ibbSID, blockSize: acceptedBlockSize).toXML())
            try harness.receive(action: JingleAction.transportAccept.rawValue, sid: sid, payload: [accepted])
            try await harness.module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 5000))

            let open = try #require(try await harness.sentIQ(matching: isIBB("open")))
            #expect(open.child(named: "open")?.attribute("block-size") == String(expectedBlocks[0]))
            var blockSizes: [Int] = []
            for seq in expectedBlocks.indices {
                let data = try #require(try await harness.sentIQ(matching: isIBB("data", seq: seq))?.child(named: "data")?.textContent)
                try blockSizes.append(#require(Base64.decode(data)).count)
            }
            #expect(blockSizes == expectedBlocks)
        }
    }

    struct DataEncoding {
        @Test
        func `IBB data holding a newline is answered bad-request`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try await harness.module.acceptFileTransfer(sid: "sid-1")
            try harness.receive(action: JingleAction.transportReplace.rawValue, sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])

            var data = XMLElement(name: "data", namespace: XMPPNamespaces.ibb, attributes: ["sid": "ibb-sid", "seq": "0"])
            data.addText("AQ\nID")
            try harness.deliver(data, id: "data-0")

            let reply = try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "data-0", type: "error"))
            #expect(reply?.child(named: "error")?.child(named: "bad-request", namespace: XMPPNamespaces.stanzas) != nil)
        }
    }
}
