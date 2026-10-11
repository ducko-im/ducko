import Testing

/// Root suite for all live-server integration tests.
///
/// `.serialized` enforces serial execution across all nested suites — a single
/// `XMPPClient` connection per account at a time avoids cross-test interference.
/// `.enabled(if:)` skips the entire tree when test credentials are not configured,
/// keeping the target buildable in CI without secrets.
@Suite(.serialized, .enabled(if: TestCredentials.isAvailable, "XMPP test credentials not set"))
enum DuckoIntegrationTests {
    /// XMPP protocol-layer tests that drive `AppEnvironment` directly.
    enum ProtocolLayer {}

    // periphery:ignore - reserved for CLI integration tests
    /// CLI integration tests that exercise the `ducko` binary.
    @Suite(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
    enum CLILayer {}

    // periphery:ignore - reserved for UI integration tests
    /// UI integration tests that drive the GUI app.
    @Suite(.enabled(
        if: AppAccessor.mayDriveGUI,
        "UI suites run in the Lume VM (zsh Skills/lume-vm/scripts/vm.sh itest); set DUCKO_UI_HOST=1 to run them on this Mac"
    ))
    enum UILayer {}
}
