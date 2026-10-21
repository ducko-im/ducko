import Testing
@testable import DuckoXMPP

private extension JingleInitiatorHarness {
    /// Expects the IQ `id` to get one error of `type` holding stanza `condition` and, when given, Jingle `jingleCondition`.
    func expectSingleError(
        to id: String, sid: String = "sid-1", type: String = "cancel", condition: String, jingleCondition: String? = nil
    ) async throws {
        let reply = try #require(try await expectSingleReply(to: id, type: "error", sid: sid))
        let error = try #require(reply.child(named: "error"))
        #expect(error.attribute("type") == type)
        #expect(error.child(named: condition, namespace: XMPPNamespaces.stanzas) != nil)
        if let jingleCondition {
            #expect(error.child(named: jingleCondition, namespace: XMPPNamespaces.jingleErrors) != nil)
        }
    }

    /// Delivers the peer's offer for `sid-1` and switches it to IBB stream `ibb-sid` with 4096-byte blocks.
    func receiveIBBSession() throws {
        try receiveOffer(sid: "sid-1")
        try receive(action: JingleAction.transportReplace.rawValue, sid: "sid-1", payload: [Self.ibbContent()])
    }

    func deliverIBBOpen(_ attributes: [String: String], id: String = "open") throws {
        try deliver(Self.ibbOpen(attributes: attributes), id: id)
    }
}

/// A content holding the parts named in `parts`, out of `description`, `transport`, `name` and `creator`.
private func content(_ parts: Set<String>, disposition: String? = nil) -> XMLElement {
    var attributes = ["name": "a-file-offer", "creator": "initiator"].filter { parts.contains($0.key) }
    attributes["disposition"] = disposition
    var content = XMLElement(name: "content", attributes: attributes)
    if parts.contains("description") {
        content.addChild(JingleFileDescription(name: "test.txt", size: 3).toXML())
    }
    if parts.contains("transport") {
        content.addChild(SOCKS5Transport(sid: "transport-sid").toXML())
    }
    return content
}

private let completeContent: Set = ["description", "transport", "name", "creator"]

enum JingleRequestValidationTests {
    struct JingleRequests {
        @Test(arguments: [
            ["sid": "sid-1"],
            ["action": "session-dance", "sid": "sid-1"],
            ["action": JingleAction.sessionTerminate.rawValue]
        ])
        func `A request without a known action or a sid gets bad-request`(attributes: [String: String]) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            try harness.deliver(XMLElement(name: "jingle", namespace: XMPPNamespaces.jingle, attributes: attributes), id: "bad")
            try await harness.expectSingleError(to: "bad", condition: "bad-request")
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test(arguments: [
            [],
            [content(completeContent.subtracting(["description"]))],
            [content(completeContent.subtracting(["transport"]))],
            [content(completeContent.subtracting(["name"]))],
            [content(completeContent.subtracting(["creator"]))],
            [content(completeContent, disposition: "early-session")]
        ])
        func `A malformed session-initiate gets bad-request and no session`(contents: [XMLElement]) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-1", payload: contents, id: "initiate")

            try await harness.expectSingleError(to: "initiate", condition: "bad-request")
            #expect(harness.receivedOffers().isEmpty)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        @Test
        func `A session-initiate whose session content follows an early-session content is offered`() async throws {
            let harness = JingleInitiatorHarness()
            let payload = [content(completeContent, disposition: "early-session"), content(completeContent)]
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-1", payload: payload, id: "initiate")

            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "initiate", type: "result")) != nil)
            #expect(harness.receivedOffers().count == 1)
        }

        @Test
        func `An empty session-info is acknowledged as a ping`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            try harness.receive(action: JingleAction.sessionInfo.rawValue, sid: "sid-1", id: "ping")
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "ping", type: "result")) != nil)
        }

        @Test(arguments: [
            (JingleAction.sessionInfo, XMLElement(name: "ringing", namespace: "urn:xmpp:jingle:apps:rtp:info:1")),
            (JingleAction.transportInfo, JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate", attributes: ["cid": "c1"]))),
            (JingleAction.transportInfo, content(["name", "creator"])),
            (JingleAction.descriptionInfo, XMLElement(name: "content", attributes: ["name": "a-file-offer", "creator": "initiator"])),
            (JingleAction.securityInfo, XMLElement(name: "content", attributes: ["name": "a-file-offer", "creator": "initiator"]))
        ])
        func `An informational payload this side does not process gets unsupported-info`(action: JingleAction, payload: XMLElement) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            try harness.receive(action: action.rawValue, sid: "sid-1", payload: [payload], id: "info")
            try await harness.expectSingleError(to: "info", condition: "feature-not-implemented", jingleCondition: "unsupported-info")
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test
        func `A responder's transport-replace during this side's own gets a tie-break and this side's stands`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            try harness.receive(action: JingleAction.transportReplace.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()], id: "duplicate")
            try await harness.expectSingleError(to: "duplicate", sid: sid, condition: "conflict", jingleCondition: "tie-break")
            #expect(harness.sentJingleCount(action: JingleAction.transportAccept.rawValue) == 0)

            try harness.receive(action: JingleAction.transportAccept.rawValue, sid: sid, id: "accept")
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "accept", type: "result")) != nil)
            try await harness.module.awaitTransportReady(sid: sid)
        }

        @Test
        func `A content-modify is refused and the session continues`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            let modify = XMLElement(name: "content", attributes: ["name": "a-file-offer", "creator": "initiator", "senders": "responder"])
            try harness.receive(action: JingleAction.contentModify.rawValue, sid: "sid-1", payload: [modify], id: "modify")
            try await harness.expectSingleError(to: "modify", condition: "not-acceptable")
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }
    }

    struct IBBRequests {
        @Test
        func `An unknown IBB child gets bad-request`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            try harness.deliver(XMLElement(name: "pause", namespace: XMPPNamespaces.ibb, attributes: ["sid": "ibb-sid"]), id: "pause")
            try await harness.expectSingleError(to: "pause", condition: "bad-request")
        }

        @Test(arguments: [
            ["block-size": "4096"],
            ["sid": "ibb-sid"],
            ["sid": "ibb-sid", "block-size": "0"],
            ["sid": "ibb-sid", "block-size": "65536"],
            ["sid": "ibb-sid", "block-size": "4096", "stanza": "presence"]
        ])
        func `A malformed IBB open gets bad-request`(attributes: [String: String]) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            try harness.deliverIBBOpen(attributes)
            try await harness.expectSingleError(to: "open", condition: "bad-request")
        }

        @Test
        func `An IBB open that would send its data in messages is refused`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            try harness.deliverIBBOpen(["sid": "ibb-sid", "block-size": "4096", "stanza": "message"])
            try await harness.expectSingleError(to: "open", condition: "not-acceptable")
        }

        @Test
        func `An IBB open with larger blocks than the transport negotiated gets resource-constraint`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            try harness.deliver(JingleInitiatorHarness.ibbOpen(blockSize: 8192), id: "larger")
            try await harness.expectSingleError(to: "larger", type: "modify", condition: "resource-constraint")

            try harness.deliver(JingleInitiatorHarness.ibbOpen(blockSize: 2048), id: "smaller")
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "smaller", type: "result")) != nil)
        }

        @Test(arguments: [
            (["seq": "0"], "AQID"),
            (["sid": "ibb-sid"], "AQID"),
            (["sid": "ibb-sid", "seq": "65536"], "AQID"),
            (["sid": "ibb-sid", "seq": "0"], "")
        ])
        func `IBB data without a sid, a valid seq or data gets bad-request`(attributes: [String: String], text: String) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            var data = XMLElement(name: "data", namespace: XMPPNamespaces.ibb, attributes: attributes)
            data.addText(text)
            try harness.deliver(data, id: "data")
            try await harness.expectSingleError(to: "data", condition: "bad-request")
        }

        @Test
        func `An IBB close without a sid gets bad-request`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveIBBSession()

            try harness.deliver(XMLElement(name: "close", namespace: XMPPNamespaces.ibb), id: "close")
            try await harness.expectSingleError(to: "close", condition: "bad-request")
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }
    }
}
