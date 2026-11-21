import DuckoTestSupport
import Testing

/// An archive query the service sent: the IQ, its id, and the query id its results carry.
struct ArchiveQuery {
    let iq: String
    let iqID: String
    let queryID: String
}

/// Waits, within `awaitSent`'s deadline, for an archive query sent on `transport` whose IQ id is not in `answered`
/// yet, and adds that id to it.
func nextArchiveQuery(on transport: MockTransport, answered: inout Set<String>) async throws -> ArchiveQuery {
    let seen = answered
    let iq = try await awaitSent(on: transport) { $0.contains("urn:xmpp:mam:2") && !seen.contains(extractIQID(from: $0) ?? "") }
    let iqID = try #require(extractIQID(from: iq))
    answered.insert(iqID)
    return try ArchiveQuery(iq: iq, iqID: iqID, queryID: #require(extractQueryID(from: iq)))
}
