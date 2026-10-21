import Foundation
import Testing
@testable import DuckoXMPP

@MainActor
struct RoomSearchProcessTests {
    @Test
    func `room list --search prints the wait a rate-limiting service asks for and exits non-zero`() async throws {
        try await withLoopbackServer(responder: RateLimitingSearchResponder(), profile: "room-search") { _, profile in
            let run = try await profile.run(["room", "list", "--search", "ducks", "--output", "plain"])

            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(run.exitCode != 0)
            #expect(run.errors.contains("The server is limiting channel searches, try again in 30 s"), Comment(rawValue: run.output + run.errors))
        }
    }
}

/// Lists `search.example.com` as the server's channel search service, which rate-limits every search for 30 seconds.
private struct RateLimitingSearchResponder: LoopbackIQResponder {
    func reply(to element: DuckoXMPP.XMLElement, id: String) -> String? {
        let to = element.attribute("to")
        if element.child(named: "query", namespace: XMPPNamespaces.discoItems) != nil, to == "example.com" {
            return """
            <iq type='result' id='\(id)' from='example.com'><query xmlns='\(XMPPNamespaces.discoItems)'>\
            <item jid='search.example.com'/></query></iq>
            """
        }
        guard to == "search.example.com" else { return nil }
        if element.child(named: "query", namespace: XMPPNamespaces.discoInfo) != nil {
            return """
            <iq type='result' id='\(id)' from='search.example.com'><query xmlns='\(XMPPNamespaces.discoInfo)'>\
            <feature var='\(XMPPNamespaces.channelSearch)'/></query></iq>
            """
        }
        guard element.child(named: "search", namespace: XMPPNamespaces.channelSearch) != nil else { return nil }
        return """
        <iq type='error' id='\(id)' from='search.example.com'><error type='wait'>\
        <resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
        <rate-limit xmlns='urn:xmpp:channel-search:0:error' retry-after='30'/></error></iq>
        """
    }
}
