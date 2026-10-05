import Foundation

/// Centralized timeout values for live-server integration tests.
///
/// Constants are tuned for a real XMPP server in steady state. Increase only
/// when a slow path is justified — flaky tests should fix the underlying race,
/// not pad the timeout.
enum TestTimeout {
    /// Account connection to a live server (DNS, TCP, TLS, SASL, bind, roster).
    static let connect: Duration = .seconds(15)

    /// Single XMPP event wait (e.g., message delivery, room join).
    static let event: Duration = .seconds(10)

    /// A dropped connection coming back with its stream resumed (reconnect delay, handshake, resume).
    static let streamResume: Duration = .seconds(30)

    /// Jingle file transfer end-to-end completion.
    static let fileTransfer: Duration = .seconds(30)

    /// OMEMO session establishment (device list fetch + bundle fetch + key exchange).
    static let omemoSession: Duration = .seconds(20)

    // periphery:ignore - reserved for UI integration tests
    /// UI element appearance via accessibility queries.
    static let uiElement: Duration = .seconds(10)

    /// CLI command completion (one-shot subcommand).
    ///
    /// Each one-shot CLI invocation does a full TLS+SASL+bind+roster sync
    /// against a live server, which can take 5–10 s on its own.
    static let cliCommand: Duration = .seconds(30)

    /// REPL output wait after issuing a command.
    static let replOutput: Duration = .seconds(10)

    /// Probe window for the inbound `presenceSubscriptionRequest` in
    /// `SubscriptionDance`. A timeout here is the signal that the server
    /// suppressed the re-subscribe (subscription='both' already holds), so
    /// this is intentionally shorter than `event`.
    static let subscriptionRequestProbe: Duration = .seconds(3)
}
