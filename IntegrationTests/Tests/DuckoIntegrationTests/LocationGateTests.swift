import Foundation
import Testing

/// Pins `AppAccessor.mayDriveGUI` to the ducko-ui scripts' own location gate,
/// so the two cannot drift apart on whichever machine runs this. Top-level
/// `enum` to opt out of the parent suite's
/// `.enabled(if: TestCredentials.isAvailable)` trait.
enum LocationGateTests {
    struct Agreement {
        @Test func `mayDriveGUI agrees with the scripts' location gate`() throws {
            let gate = Process()
            gate.executableURL = URL(fileURLWithPath: "/bin/bash")
            gate.arguments = [
                "-c", "source \"$1\"; ducko_require_vm_or_host_opt_in", "bash",
                AppAccessor.scriptsDirectory.appending(path: "ducko-helpers.sh").path
            ]
            gate.standardError = FileHandle.nullDevice

            try gate.run()
            gate.waitUntilExit()

            // The gate passes with 0 and refuses with 1. Any other status means it never ran.
            try #require([0, 1].contains(gate.terminationStatus))
            #expect((gate.terminationStatus == 0) == AppAccessor.mayDriveGUI)
        }
    }
}
