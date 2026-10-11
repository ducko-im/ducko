import AppKit
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    /// Lives under `UILayer` for the layer's location gate. The script's own
    /// gate mirrors it, so the script gets past that gate to the process check
    /// this case covers. Nesting here also inherits `.enabled(if: TestCredentials.isAvailable)`,
    /// so this case skips without credentials even though the script failure it
    /// covers needs none; the always-on, credential-free script coverage is
    /// `DuckoScriptTests`'s job in the main package.
    struct UIScriptTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && AppAccessor.noTestCopyRunning,
            "Ducko.app missing, AX trust not granted, or a DuckoUITest copy is running"
        ))
        @MainActor func `import script reports when no app is running`() throws {
            let result = try Self.runImportScript()
            #expect(result.exitCode != 0)

            // The `DuckoUITest is not running` message comes from the osascript
            // `System Events` branch, which needs Automation
            // (`kTCCServiceAppleEvents`) permission — distinct from the
            // Accessibility trust the gate checks. When Automation is ungranted,
            // osascript fails with a permission error first and the substring
            // never appears, though the script still exits nonzero. Treat the
            // substring as a tolerated soft check so a missing Automation grant
            // doesn't flake the suite; the nonzero exit is the hard assertion.
            withKnownIssue(
                "DuckoUITest-not-running message requires Automation (kTCCServiceAppleEvents) permission",
                isIntermittent: true
            ) {
                #expect(result.stderr.contains("DuckoUITest is not running"))
            }
        }

        /// Spawns `Skills/ducko-ui/scripts/ducko-import.sh` under `/bin/bash` and
        /// returns its exit code and stderr. A local `Process` spawn — the
        /// `ScriptRunner` lives in the main package's `DuckoScriptTests`
        /// target, which is not a product and so cannot be imported here.
        private static func runImportScript() throws -> (exitCode: Int32, stderr: String) {
            let script = AppAccessor.scriptsDirectory.appending(path: "ducko-import.sh")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice

            try process.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: stderrData, as: UTF8.self))
        }
    }
}
