/// Wraps an `AsyncStream` iterator for cross-isolation event consumption.
///
/// `@unchecked Sendable` because `AsyncStream.Iterator.next()` is nonisolated async,
/// requiring the iterator to cross actor isolation boundaries. Safe because all access
/// is sequential — only one caller consumes events at a time (handshake then dispatch).
final class EventReader: @unchecked Sendable {
    private var iterator: AsyncStream<XMLStreamEvent>.Iterator
    /// The `xml:lang` of the last stream header read, which the stanzas on that stream inherit (RFC 6120 §4.7.4).
    private(set) var streamLang: String?

    init(_ stream: AsyncStream<XMLStreamEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> XMLStreamEvent? {
        await iterator.next()
    }

    func awaitNextEvent() async throws -> XMLStreamEvent {
        guard let event = await iterator.next() else {
            throw XMPPClientError.unexpectedStreamState("Stream ended unexpectedly")
        }
        return event
    }

    func awaitFeatures() async throws -> XMLElement {
        let openEvent = try await awaitNextEvent()
        guard case let .streamOpened(attributes) = openEvent else {
            throw XMPPClientError.unexpectedStreamState("Expected stream opened")
        }
        // RFC 6120 §4.7.5: reject unsupported stream versions.
        if let version = attributes["version"], version != "1.0" {
            throw XMPPClientError.unexpectedStreamState("Unsupported stream version: \(version)")
        }
        streamLang = attributes["xml:lang"]
        return try await awaitFeaturesElement()
    }

    /// Awaits a `<features>` element on the current stream, without a preceding stream header.
    func awaitFeaturesElement() async throws -> XMLElement {
        let featuresEvent = try await awaitNextEvent()
        guard case let .stanzaReceived(features) = featuresEvent, features.name == "features" else {
            throw XMPPClientError.unexpectedStreamState("Expected stream features")
        }
        return features
    }

    func awaitStanza() async throws -> XMLElement {
        let event = try await awaitNextEvent()
        guard case let .stanzaReceived(element) = event else {
            throw XMPPClientError.unexpectedStreamState("Expected stanza")
        }
        return element
    }
}
