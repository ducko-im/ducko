import Foundation

/// Captured result of a `Skills/ducko-ui/scripts/*.sh` invocation. The scripts
/// report failures (usage text, "not running") on stderr.
struct ScriptResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Spawns the ducko-ui automation scripts under `/bin/bash`, and the lume-vm
/// driver under `/bin/zsh`, for hermetic, credential-free assertions on their
/// argument validation, generated AppleScript and guards. The skills directory
/// is resolved relative to this file via `#filePath`, so checkout location
/// does not matter.
enum ScriptRunner {
    /// `Tests/DuckoScriptTests/ScriptRunner.swift` → `<repo>/Skills`.
    static var skillsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DuckoScriptTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Skills")
    }

    static var scriptsDirectory: URL {
        skillsDirectory.appendingPathComponent("ducko-ui").appendingPathComponent("scripts")
    }

    /// Runs `script` (a bare filename under `scriptsDirectory`) with `arguments`
    /// and returns its exit code and captured streams.
    static func run(_ script: String, arguments: [String] = []) throws -> ScriptResult {
        try bash([scriptsDirectory.appendingPathComponent(script).path] + arguments, environment: hostEnvironment)
    }

    /// The inherited environment with the opt-in that lets the scripts run on this Mac.
    static var hostEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["DUCKO_UI_HOST": "1"]) { _, value in value }
    }

    /// Runs `/bin/bash` with the given argument vector. Callers pass paths as
    /// positional parameters (`bash -c '… "$1" …' bash <path>`) rather than
    /// interpolating them into the command string, so a checkout path with
    /// spaces needs no shell quoting.
    static func bash(_ arguments: [String], environment: [String: String]? = nil) throws -> ScriptResult {
        try spawn("/bin/bash", arguments, environment: environment)
    }

    /// Runs `/bin/zsh`, which the lume-vm driver script is written for. `-f`
    /// keeps the user's startup files out of the run: zsh reads `~/.zshenv`
    /// even under a replaced environment, and it can reorder `PATH`.
    static func zsh(_ arguments: [String], environment: [String: String]? = nil) throws -> ScriptResult {
        try spawn("/bin/zsh", ["-f"] + arguments, environment: environment)
    }

    /// A stand-in checkout. The scripts resolve their own root with symlinks
    /// expanded, so `resolved` is what they see when run from under `root`.
    struct Checkout {
        let root: URL
        let resolved: String
        let skill: String

        func script(_ name: String) -> String {
            root.appendingPathComponent("Skills/\(skill)/scripts/\(name)").path
        }
    }

    /// Runs `body` with a temporary checkout holding copies of the named
    /// scripts of one skill. Its name carries a space and regular-expression
    /// characters, which the scripts must take literally.
    static func withCheckout<T>(skill: String, scripts: [String], _ body: (Checkout) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Ducko (checkout) + \(UUID().uuidString)")
        let folder = root.appendingPathComponent("Skills/\(skill)/scripts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for script in scripts {
            try FileManager.default.copyItem(
                at: skillsDirectory.appendingPathComponent("\(skill)/scripts/\(script)"), to: folder.appendingPathComponent(script)
            )
        }
        let resolved = try bash(["-c", "cd \"$1\" && pwd -P", "bash", root.path]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return try body(Checkout(root: root, resolved: resolved, skill: skill))
    }

    /// Runs `body` with a temporary directory holding one executable per entry
    /// of `stubs` (name to script text), for use as a `PATH` of stand-ins.
    static func withStubs<T>(_ stubs: [String: String], _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ducko stubs \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in stubs {
            try writeExecutable(text, to: directory.appendingPathComponent(name))
        }
        return try body(directory)
    }

    static func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func spawn(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Both streams stay far below the pipe buffer, so a sequential drain
        // cannot deadlock the child.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

struct CapturedAppleScript {
    let result: ScriptResult
    /// One entry per osascript call, in call order.
    let sources: [String]
    let argumentsByCall: [[String]]
    let compilerExitCode: Int32
    let compilerErrors: String
    let invocations: [String]
}

extension ScriptRunner {
    /// Only the selected wrapper and real helpers run. Sibling scripts and app commands
    /// are inert, and osascript captures and compiles its input without executing it.
    /// `hostOptIn: false` leaves `DUCKO_UI_HOST` unset, and the stub PATH has no `sysctl`, so the location gate fails.
    static func capture(
        _ script: String, arguments: [String], response: String = "ok", hostOptIn: Bool = true, environment extra: [String: String] = [:]
    ) throws -> CapturedAppleScript {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ducko script fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try installCaptureFixture(in: directory, script: script)
        let captureDirectory = directory.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        var environment = [
            "PATH": directory.appendingPathComponent("bin").path,
            "CAPTURE_DIR": captureDirectory.path,
            "CAPTURE_RESPONSE": response
        ]
        if hostOptIn {
            environment["DUCKO_UI_HOST"] = "1"
        }
        environment.merge(extra) { _, value in value }
        let result = try bash([directory.appendingPathComponent(script).path] + arguments, environment: environment)
        func read(_ name: String) -> String {
            (try? String(contentsOf: captureDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let invocations = read("invocations").split(separator: "\n").map(String.init)
        let calls = 1 ..< invocations.count { $0 == "osascript" } + 1
        return CapturedAppleScript(
            result: result,
            sources: calls.map { read("source.applescript.\($0)") },
            argumentsByCall: calls.map { read("argv.\($0)").split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) },
            compilerExitCode: Int32(read("compile-status").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            compilerErrors: read("compile-errors"),
            invocations: invocations
        )
    }

    private static func installCaptureFixture(in directory: URL, script: String) throws {
        let manager = FileManager.default
        let bin = directory.appendingPathComponent("bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let scripts = try manager.contentsOfDirectory(at: scriptsDirectory, includingPropertiesForKeys: nil)
        for source in scripts where source.pathExtension == "sh" {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if source.lastPathComponent == script || source.lastPathComponent == "ducko-helpers.sh" {
                try manager.copyItem(at: source, to: destination)
            } else {
                try writeExecutable(captureNoOp, to: destination)
            }
        }
        for command in ["sleep", "pgrep", "open", "pkill", "killall", "swift"] {
            try writeExecutable(captureNoOp, to: bin.appendingPathComponent(command))
        }
        for (name, target) in [("cat", "/bin/cat"), ("dirname", "/usr/bin/dirname")] {
            try manager.createSymbolicLink(atPath: bin.appendingPathComponent(name).path, withDestinationPath: target)
        }
        try writeExecutable(captureOSAScript, to: bin.appendingPathComponent("osascript"))
    }
}

/// Records its own name, and fails when `CAPTURE_FAILING` lists that name.
private let captureNoOp = #"""
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$CAPTURE_DIR/invocations"
[[ " ${CAPTURE_FAILING:-} " == *" ${0##*/} "* ]] && exit 1
exit 0
"""#

private let captureOSAScript = #"""
#!/bin/bash
printf '%s\n' osascript >> "$CAPTURE_DIR/invocations"
n=1
while [[ -e "$CAPTURE_DIR/source.applescript.$n" ]]; do n=$((n + 1)); done
if [[ $# -gt 0 ]]; then printf '%s\0' "$@" > "$CAPTURE_DIR/argv.$n"; else : > "$CAPTURE_DIR/argv.$n"; fi
/bin/cat > "$CAPTURE_DIR/source.applescript.$n"
/usr/bin/osacompile -o "$CAPTURE_DIR/compiled.scpt" "$CAPTURE_DIR/source.applescript.$n" > /dev/null 2> "$CAPTURE_DIR/compile-errors"
status=$?
printf '%s\n' "$status" > "$CAPTURE_DIR/compile-status"
printf '%s\n' "$CAPTURE_RESPONSE"
exit "$status"
"""#
