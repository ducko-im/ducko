import Foundation
import Testing

/// Pins which process the ducko-ui scripts launch, drive and stop: the
/// `DuckoUITest` copy under its own profile, never an installed Ducko or
/// another checkout's copy.
struct ScriptTargetingTests {
    @Test func `ducko_app_pid takes DUCKO_PID without asking pgrep`() throws {
        let result = try runHelper("ducko_app_pid", pgrepOutput: "1\n2", pid: "4242")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "4242\n")
    }

    @Test(arguments: zip(["777", "1\n2", ""], ["777\n", nil, nil] as [String?]))
    func `ducko_app_pid resolves exactly one DuckoUITest`(_ pgrepOutput: String, _ expected: String?) throws {
        let result = try runHelper("ducko_app_pid", pgrepOutput: pgrepOutput)
        if let expected {
            #expect(result.exitCode == 0)
            #expect(result.stdout == expected)
        } else {
            #expect(result.exitCode == 1)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("DuckoUITest"))
        }
    }

    @Test(arguments: zip(["777", "1\n2", ""], [true, false, true]))
    func `ducko_require_single_app refuses only with several copies running`(_ pgrepOutput: String, _ passes: Bool) throws {
        let result = try runHelper("ducko_require_single_app", pgrepOutput: pgrepOutput)
        #expect((result.exitCode == 0) == passes)
    }

    @Test func `ducko-stop stops the copy launched from its own checkout and no other`() throws {
        try ScriptRunner.withCheckout(skill: "ducko-ui", scripts: ["ducko-helpers.sh", "ducko-stop.sh"]) { checkout in
            try ScriptRunner.withCheckout(skill: "ducko-ui", scripts: []) { other in
                let target = try startCopy(in: checkout)
                defer { target.terminate() }
                let decoy = try startCopy(in: other)
                defer { decoy.terminate() }

                // Run through the path as created, which the script has to resolve to match the copy's command line.
                let result = try ScriptRunner.bash([checkout.script("ducko-stop.sh")], environment: ScriptRunner.hostEnvironment)

                #expect(result.exitCode == 0, "ducko-stop failed: \(result.stderr)")
                #expect(result.stdout.contains("DuckoUITest stopped"))
                #expect(waitUntil { !target.isRunning })
                #expect(decoy.isRunning)
            }
        }
    }

    @Test(arguments: zip([nil, "custom"] as [String?], ["uitest", "custom"]))
    func `ducko-launch starts a renamed copy under its own profile that ducko-stop finds`(_ profile: String?, _ expected: String) throws {
        try withLaunchFixture(packaging: Self.packagingStub) { checkout, environment in
            var environment = environment
            environment["DUCKO_PROFILE"] = profile
            defer { _ = try? ScriptRunner.bash([checkout.script("ducko-stop.sh")], environment: environment) }

            let launch = try ScriptRunner.bash([checkout.script("ducko-launch.sh")], environment: environment)
            #expect(launch.exitCode == 0, "ducko-launch failed: \(launch.stderr)")
            #expect(launch.stdout == "77\n")

            let copy = URL(fileURLWithPath: "\(checkout.resolved)/.build/ducko-ui/DuckoUITest.app/Contents")
            // A release build ignores DUCKO_PROFILE and would use the production store.
            let packaging = try String(contentsOf: copy.appendingPathComponent("packaging"), encoding: .utf8)
            #expect(packaging == "debug SIGNING_MODE=adhoc")

            let recorded = copy.appendingPathComponent("MacOS/profile")
            #expect(waitUntil { FileManager.default.fileExists(atPath: recorded.path) })
            #expect(try String(contentsOf: recorded, encoding: .utf8) == expected)
            // Without it, the copy restores the windows of the run ducko-stop ended instead of opening Contacts.
            let arguments = try String(contentsOf: copy.appendingPathComponent("MacOS/arguments"), encoding: .utf8)
            #expect(arguments == "-ApplePersistenceIgnoreState YES")

            let info = try #require(NSDictionary(contentsOf: copy.appendingPathComponent("Info.plist")))
            #expect(info["CFBundleExecutable"] as? String == "DuckoUITest")
            #expect(info["CFBundleIdentifier"] as? String == "im.ducko.uitest")
            #expect(info["SUEnableAutomaticChecks"] as? Bool == false)

            let signed = try String(contentsOf: URL(fileURLWithPath: "\(checkout.resolved)/codesign.log"), encoding: .utf8)
            #expect(signed.contains("--entitlements"))
            #expect(!signed.contains("--deep"))

            // The stand-in takes its final command line a moment after it records the profile.
            let stopped = waitUntil {
                (try? ScriptRunner.bash([checkout.script("ducko-stop.sh")], environment: environment))?.stdout.contains("DuckoUITest stopped") == true
            }
            #expect(stopped, "ducko-stop never found the launched copy")
        }
    }

    @Test func `ducko-launch stops the copy already running before it launches another`() throws {
        try withLaunchFixture(packaging: Self.packagingStub) { checkout, environment in
            let earlier = try startCopy(in: checkout)
            defer { earlier.terminate() }
            defer { _ = try? ScriptRunner.bash([checkout.script("ducko-stop.sh")], environment: environment) }

            let launch = try ScriptRunner.bash([checkout.script("ducko-launch.sh")], environment: environment)

            #expect(launch.exitCode == 0, "ducko-launch failed: \(launch.stderr)")
            #expect(waitUntil { !earlier.isRunning })
        }
    }

    @Test func `ducko-launch reports a failed build and launches nothing`() throws {
        try withLaunchFixture(packaging: "#!/bin/bash\necho packaging-broke >&2\nexit 1\n") { checkout, environment in
            let launch = try ScriptRunner.bash([checkout.script("ducko-launch.sh")], environment: environment)
            #expect(launch.exitCode == 1)
            #expect(launch.stdout.isEmpty)
            #expect(launch.stderr.contains("packaging-broke"))
            #expect(launch.stderr.contains("building the DuckoUITest copy failed"))
        }
    }

    /// Records how it was asked to package, then writes a bundle with a
    /// stand-in executable. The executable records its arguments and the
    /// profile it was launched under, then stays alive with its own path as its
    /// command line. The profile is written under another name and moved into
    /// place, so a test that finds it reads it whole.
    private static let packagingStub = #"""
    #!/bin/bash
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    printf '%s' "$* SIGNING_MODE=${SIGNING_MODE-unset}" > "$APP_BUNDLE/Contents/packaging"
    cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>DuckoApp</string>
    <key>CFBundleIdentifier</key><string>im.ducko</string>
    </dict></plist>
    PLIST
    cat > "$APP_BUNDLE/Contents/MacOS/DuckoApp" <<'APP'
    #!/bin/bash
    printf '%s' "$*" > "$(dirname "$0")/arguments"
    printf '%s' "${DUCKO_PROFILE-unset}" > "$(dirname "$0")/profile.partial"
    mv "$(dirname "$0")/profile.partial" "$(dirname "$0")/profile"
    exec -a "$0" /bin/sleep 100
    APP
    chmod +x "$APP_BUNDLE/Contents/MacOS/DuckoApp"
    """#

    /// A stand-in checkout with the launch and stop scripts, a packaging
    /// script, a window lookup that answers at once, and a `codesign` that
    /// only records its arguments.
    private func withLaunchFixture(packaging: String, _ body: (ScriptRunner.Checkout, [String: String]) throws -> Void) throws {
        try ScriptRunner.withCheckout(skill: "ducko-ui", scripts: ["ducko-helpers.sh", "ducko-launch.sh", "ducko-stop.sh"]) { checkout in
            let scripts = checkout.root.appendingPathComponent("Scripts")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try ScriptRunner.writeExecutable(packaging, to: scripts.appendingPathComponent("package_app.sh"))
            try ScriptRunner.writeExecutable("#!/bin/bash\necho 77\n", to: URL(fileURLWithPath: checkout.script("ducko-window-id.sh")))
            let codesign = "#!/bin/bash\nprintf '%s\\n' \"$*\" > \"$CODESIGN_LOG\"\n"
            try ScriptRunner.withStubs(["codesign": codesign]) { stubs in
                var environment = ScriptRunner.hostEnvironment
                environment["PATH"] = "\(stubs.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
                environment["CODESIGN_LOG"] = "\(checkout.resolved)/codesign.log"
                try body(checkout, environment)
            }
        }
    }

    /// Runs one `ducko-helpers.sh` function with a `pgrep` that answers only
    /// the lookup for the copy's process name.
    private func runHelper(_ call: String, pgrepOutput: String, pid: String? = nil) throws -> ScriptResult {
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let pgrep = """
        #!/bin/bash
        [[ "$*" == "-x DuckoUITest" && -n "$PGREP_OUTPUT" ]] || exit 1
        printf '%s\\n' "$PGREP_OUTPUT"
        """
        return try ScriptRunner.withStubs(["pgrep": pgrep]) { stubs in
            var environment = ["PATH": stubs.path, "PGREP_OUTPUT": pgrepOutput]
            environment["DUCKO_PID"] = pid
            return try ScriptRunner.bash(["-c", "source \"$1\"; \(call)", "bash", helpers], environment: environment)
        }
    }

    /// Starts a process whose command line is the copy's executable path
    /// under `checkout`, and waits until the process list shows it that way.
    private func startCopy(in checkout: ScriptRunner.Checkout) throws -> Process {
        let executable = "\(checkout.resolved)/.build/ducko-ui/DuckoUITest.app/Contents/MacOS/DuckoUITest"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a \"$1\" /bin/sleep 100", "bash", executable]
        try process.run()
        let listed = waitUntil {
            let command = try? ScriptRunner.bash(["-c", "ps -o command= -p \"$1\"", "bash", String(process.processIdentifier)])
            return command?.stdout.hasPrefix("\(executable) ") == true
        }
        if !listed {
            process.terminate()
        }
        try #require(listed, "The process list never showed the stand-in copy")
        return process
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            usleep(50000)
        }
        return condition()
    }
}
