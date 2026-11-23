import Foundation
import Testing

/// Hermetic, credential-free coverage for the `ducko-ui` automation scripts'
/// argument validation and generated AppleScript. These run on a plain
/// `swift test` with no GUI, accessibility trust, or running app — the
/// UI integration tests are the live backstop for the AX surfaces the scripts
/// drive; this suite tests the scripts themselves.
struct ScriptValidationTests {
    @Test(arguments: [[], ["only-jid"]])
    func `ducko-login rejects missing arguments`(_ arguments: [String]) throws {
        // The bash `${1:?…}` / `${2:?…}` guards fire before any osascript runs.
        let result = try ScriptRunner.run("ducko-login.sh", arguments: arguments)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["server"], ["server", "user"]])
    func `ducko-register rejects fewer than three arguments`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-register.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-register points to the next script when the server asks for more`() throws {
        let captured = try ScriptRunner.capture("ducko-register.sh", arguments: ["example.com", "juliet", "secret"], response: "MORE")
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.result.stdout.contains("ducko-register-fields.sh"))
    }

    @Test(arguments: [[], ["submit"], ["fill", "nick"], ["redirect", "extra"]])
    func `ducko-register-fields rejects an unknown action or an unpaired field`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-register-fields.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-register-fields prints the page the server names`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-register-fields.sh", arguments: ["redirect"], response: "URL:https://example.com/register"
        )
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.result.stdout == "https://example.com/register\n")
    }

    /// Wrappers whose AppleScript defines no handlers, so they sit outside `handlerScriptCases`.
    @Test(arguments: [
        ("ducko-account-status.sh", ["alice@example.com", "xa"], ["-", "alice@example.com", "Extended Away"], ["osascript"]),
        ("ducko-status-menu.sh", ["away"], ["-", "away", "Away"], ["osascript"]),
        ("ducko-status-menu.sh", ["toggle"], ["-", "toggle", ""], ["osascript"]),
        ("ducko-room-config-save.sh", ["room@example.com"], [], ["ducko-room-settings.sh", "osascript"])
    ])
    func `wrappers without shared handlers compile and pass their arguments`(
        _ script: String, _ arguments: [String], _ appleScriptArguments: [String], _ invocations: [String]
    ) throws {
        let captured = try ScriptRunner.capture(script, arguments: arguments)
        #expect(captured.result.exitCode == 0, "Wrapper failed: \(captured.result.stderr)")
        #expect(captured.compilerExitCode == 0, "AppleScript failed: \(captured.compilerErrors)")
        #expect(captured.argumentsByCall == [appleScriptArguments])
        #expect(captured.invocations == invocations)
    }

    @Test(arguments: [
        ("ducko-room-config-save.sh", ["room@example.com"]),
        ("ducko-destroy-room.sh", ["room@example.com"]),
        ("ducko-add-affiliation.sh", ["room@example.com", "bob@example.com"])
    ])
    func `room wrappers open Room Settings for their room`(_ script: String, _ arguments: [String]) throws {
        let captured = try ScriptRunner.capture(script, arguments: arguments)
        #expect(captured.result.exitCode == 0, "Wrapper failed: \(captured.result.stderr)")
        #expect(captured.siblingArguments["ducko-room-settings.sh"] == ["room@example.com"])
    }

    @Test(arguments: [[], ["busy"]])
    func `ducko-status-menu rejects a missing or unknown action`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-status-menu.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["alice@example.com"], ["alice@example.com", "busy"]])
    func `ducko-account-status rejects a missing account or unknown status`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-account-status.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["bob@example.com"], ["bob@example.com", "block"]])
    func `ducko-contact-menu rejects a missing or unknown action`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-contact-menu.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["block"], ["add"], ["remove"], ["open", "bob@example.com"], ["list", "bob@example.com"]])
    func `ducko-blocked-contacts rejects an unknown action or a misplaced address`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-blocked-contacts.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-blocked-contacts prints the addresses the sheet lists`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-blocked-contacts.sh", arguments: ["list"], response: "LIST:bob@example.com\nbob@example.com/laptop\n"
        )
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.result.stdout == "bob@example.com\nbob@example.com/laptop\n")
        #expect(captured.invocations == ["osascript"])
    }

    @Test(arguments: [[], ["reset"], ["all", "123"], ["device"]])
    func `ducko-omemo-reset rejects an unknown action or a misplaced device ID`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-omemo-reset.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["keep"]])
    func `ducko-sign-in-security rejects a missing or unknown action`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-sign-in-security.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-history-search rejects a missing query`() throws {
        let result = try ScriptRunner.run("ducko-history-search.sh", arguments: [])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-history-search parses as valid bash`() throws {
        let script = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-history-search.sh").path
        let result = try ScriptRunner.bash(["-n", script])
        #expect(result.exitCode == 0, "bash -n failed: \(result.stderr)")
    }

    @Test func `ducko-history-search compiles and hands its query to the AppleScript as an argument`() throws {
        let captured = try ScriptRunner.capture("ducko-history-search.sh", arguments: [scriptSpecialArgument])
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.compilerExitCode == 0, "AppleScript failed: \(captured.compilerErrors)")
        #expect(captured.argumentsByCall.last == ["-", scriptSpecialArgument])
    }

    @Test func `ducko-import parses as valid bash`() throws {
        // `ducko-import.sh` probes for a running app, so it has no hermetic
        // argument-validation surface like login/register. A `bash -n` parse is
        // its deterministic syntax backstop — the live `UIScriptTests` only
        // asserts a nonzero exit, which a syntax error would also produce.
        let script = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-import.sh").path
        let result = try ScriptRunner.bash(["-n", script])
        #expect(result.exitCode == 0, "bash -n failed: \(result.stderr)")
    }

    @Test func `ducko_as_handlers compiles as standalone AppleScript`() throws {
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }

        // Positional `$1`/`$2` carry the paths so a spaced checkout path needs
        // no quoting. Handler-only AppleScript is valid and compiles standalone,
        // so a clean `osacompile` exit proves the emitted handlers parse.
        let result = try ScriptRunner.bash([
            "-c",
            "source \"$1\"; ducko_as_handlers | osacompile -o \"$2\" -",
            "bash", helpers, output.path
        ])
        #expect(result.exitCode == 0, "osacompile failed: \(result.stderr)")
    }

    @Test(arguments: [("", true), ("continue", false)])
    func `ducko_as_click_context_menu_item returns only in its default mode`(_ mode: String, _ expectsReturn: Bool) throws {
        // `ducko-change-password.sh` keeps filling the sheet after the click, so
        // an `ok` return emitted in continue mode would end the script early
        // while reporting success.
        let emitted = try emitContextMenuSnippet(mode: mode)
        #expect(emitted.contains("click menuItem"))
        #expect(emitted.contains("return \"ok\"") == expectsReturn)
    }

    @Test func `ducko_as_click_context_menu_item falls back to AXPress`() throws {
        // A `Menu` hosted in a grouped `Form` advertises no AXShowMenu and
        // returns success without opening the menu, so losing this branch would
        // leave the Actions pull-down shut and every item lookup failing.
        let emitted = try emitContextMenuSnippet(mode: "")
        #expect(emitted.contains("if \"AXShowMenu\" is in (name of actions of targetElem)"))
        #expect(emitted.contains("perform action \"AXPress\" of targetElem"))
    }

    @Test func `ducko_as_click_context_menu_item reports a missing item`() throws {
        let emitted = try emitContextMenuSnippet(mode: "")
        #expect(emitted.contains("return \"ERROR: Reply menu item not found\""))
        #expect(emitted.contains("if frontmost then key code 53"))
    }

    @Test func `ducko-change-password keeps filling the sheet after the menu click`() throws {
        let captured = try ScriptRunner.capture("ducko-change-password.sh", arguments: ["pw"])
        let source = try #require(captured.sources.last)
        #expect(source.contains("keystroke newPw"))
        #expect(source.components(separatedBy: "return \"ok\"").count - 1 == 1)
    }

    @Test(arguments: zip([("0", nil), ("1", nil), ("0", "1"), ("0", "0")] as [(String, String?)], [false, true, true, false]))
    func `location gate passes only in the VM or with the host opt-in`(_ environment: (hypervisor: String, hostOptIn: String?), _ passes: Bool) throws {
        let (hypervisor, hostOptIn) = environment
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let result = try ScriptRunner.withStubs(["sysctl": "#!/bin/bash\necho \(hypervisor)\n"]) { stubs in
            var environment = ["PATH": stubs.path]
            environment["DUCKO_UI_HOST"] = hostOptIn
            return try ScriptRunner.bash(
                ["-c", "source \"$1\"; ducko_require_vm_or_host_opt_in", "bash", helpers],
                environment: environment
            )
        }

        #expect((result.exitCode == 0) == passes)
        if !passes {
            #expect(result.stderr.contains("vm.sh ui"))
            #expect(result.stderr.contains("DUCKO_UI_HOST"))
        }
    }

    @Test func `no script targets the DuckoApp process by name`() throws {
        for script in try automationScripts() {
            let source = try String(contentsOf: ScriptRunner.scriptsDirectory.appendingPathComponent(script), encoding: .utf8)
            #expect(!source.contains("process \"DuckoApp\""), "\(script) can reach an installed Ducko")
        }
    }

    @Test func `every script is executable`() throws {
        // The other tests run each script as `/bin/bash <path>`, which ignores the executable bit, but `vm.sh ui` and
        // direct runs execute the file itself.
        for script in try automationScripts() {
            let path = ScriptRunner.scriptsDirectory.appendingPathComponent(script).path
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            #expect(permissions & 0o100 != 0, "\(script) lacks the user-executable bit")
        }
    }

    @Test(arguments: try automationScripts())
    func `every script stops at the location gate before running anything`(_ script: String) throws {
        let captured = try ScriptRunner.capture(script, arguments: [], hostOptIn: false)
        #expect(captured.result.exitCode != 0)
        #expect(captured.result.stderr.contains("vm.sh ui"))
        #expect(captured.invocations.isEmpty)
    }

    @Test func `ducko-attach leaves the panel helper alone when opening the panel failed`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-attach.sh", arguments: ["/etc/hosts"], response: "ERROR: attachment-button not found", environment: ["DUCKO_PID": "4242"]
        )
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("attachment-button not found"))
        #expect(!captured.result.stdout.contains("File attached"))
        #expect(captured.invocations == ["osascript"])
    }

    @Test func `ducko-attach reports no success when the panel stayed open`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-attach.sh", arguments: ["/etc/hosts"], environment: ["DUCKO_PID": "4242", "CAPTURE_FAILING": "swift"]
        )
        #expect(captured.result.exitCode == 1)
        #expect(!captured.result.stdout.contains("File attached"))
        #expect(captured.invocations == ["osascript", "swift"])
    }

    @Test func `ducko-room-topic refuses a topic with a line break before typing`() throws {
        let captured = try ScriptRunner.capture("ducko-room-topic.sh", arguments: ["two\nlines"])
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("Usage:"))
        #expect(captured.invocations.isEmpty)
    }

    @Test func `ducko-import-account refuses to seed outside the VM even with the host opt-in`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-import-account.sh", arguments: ["seed", "alice@example.com"], environment: ["DUCKO_PROFILE": "import-smoke"]
        )
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("vm.sh ui"))
        #expect(captured.invocations.isEmpty)
    }

    @Test(arguments: [["seed", "alice@example.com"], ["clean"]], [nil, "uitest", "UITEST", "UiTest", "../x"] as [String?])
    func `ducko-import-account refuses to seed or clean without a fresh profile of its own`(_ arguments: [String], _ profile: String?) throws {
        var environment: [String: String] = [:]
        environment["DUCKO_PROFILE"] = profile
        let captured = try ScriptRunner.capture("ducko-import-account.sh", arguments: arguments, vmPresent: true, environment: environment)
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("DUCKO_PROFILE"))
        #expect(captured.invocations.isEmpty)
    }

    /// Runs the real seed helper in its check-only mode, which stops after the argument checks.
    @Test(arguments: [
        (["seed", "UITEST", "alice@example.com"], "PROFILE must be"),
        (["clean", "uitest"], "PROFILE must be"),
        (["clean", "UiTest"], "PROFILE must be"),
        (["seed", "../x", "alice@example.com"], "PROFILE must be"),
        (["seed", checkOnlyProfile], "usage:"),
        (["clean", checkOnlyProfile, "extra"], "usage:"),
        (["seed", checkOnlyProfile, "alice@example.com,host"], "UID or UID,SERVER,PORT"),
        (["seed", checkOnlyProfile, ",example.com,5222"], "UID or UID,SERVER,PORT"),
        (["seed", checkOnlyProfile, "alice@example.com,1234,5222"], "SERVER must be"),
        (["seed", checkOnlyProfile, "alice@example.com,example.com,0"], "PORT must be"),
        (["seed", checkOnlyProfile, "alice@example.com,example.com,65536"], "PORT must be")
    ] as [([String], String)])
    func `ducko-import-seed refuses bad arguments before it checks for the VM`(_ arguments: [String], _ message: String) throws {
        let result = try runSeedHelperCheckOnly(arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains(message), "Unexpected refusal: \(result.stderr)")
        #expect(!result.stdout.contains("arguments accepted"))
    }

    @Test(arguments: [["seed", checkOnlyProfile, "alice@example.com", "other@example.com,127.0.0.1,1"], ["clean", checkOnlyProfile]])
    func `ducko-import-seed accepts valid arguments in its check-only mode`(_ arguments: [String]) throws {
        let result = try runSeedHelperCheckOnly(arguments)
        #expect(result.exitCode == 0, "Helper refused: \(result.stderr)")
        #expect(result.stdout == "arguments accepted\n")
    }

    @Test func `ducko-import-account seeds through the Swift helper alone`() throws {
        let accounts = ["alice@example.com", "other@example.com,127.0.0.1,1"]
        let captured = try ScriptRunner.capture(
            "ducko-import-account.sh", arguments: ["seed"] + accounts, vmPresent: true, environment: ["DUCKO_PROFILE": "import-smoke"]
        )
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.invocations == ["swift"])
        // The fixture runs the wrapper from its own folder, so the helper must sit beside the wrapper, as it does in the repo.
        let helper = try URL(fileURLWithPath: #require(captured.swiftArguments.first))
        #expect(helper.lastPathComponent == "ducko-import-seed.swift")
        #expect(helper.deletingLastPathComponent().path == captured.scriptDirectory.path)
        #expect(FileManager.default.fileExists(atPath: ScriptRunner.scriptsDirectory.appendingPathComponent(helper.lastPathComponent).path))
        #expect(Array(captured.swiftArguments.dropFirst()) == ["seed", "import-smoke"] + accounts)
    }

    @Test func `ducko-import-account stops the app before cleaning`() throws {
        let captured = try ScriptRunner.capture(
            "ducko-import-account.sh", arguments: ["clean"], vmPresent: true, environment: ["DUCKO_PROFILE": "import-smoke"]
        )
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.invocations == ["ducko-stop.sh", "swift"])
        let helper = try #require(captured.swiftArguments.first)
        #expect(helper.hasSuffix("/ducko-import-seed.swift"))
        #expect(Array(captured.swiftArguments.dropFirst()) == ["clean", "import-smoke"])
    }

    @Test(arguments: ["contacts", "\"$DUCKO_SETTINGS_SCENE\""])
    func `ducko_as_await_sheet_closed compiles and reports a sheet left open or its error`(_ scene: String) throws {
        let compiled = try compileSnippet("ducko_as_await_sheet_closed targetWin \(scene) '\"field-id\"' '\"error-id\"' 5 \"Sheet stayed open\"")
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        #expect(compiled.source.contains("return \"ERROR: Sheet stayed open\""))
        #expect(compiled.source.contains("set sheetError to my findInSheets(targetWin, \"error-id\")"))
        #expect(!compiled.source.contains("return \"ok\""))
    }

    @Test(arguments: ["window", "sheets"])
    func `ducko_as_await_element compiles and reports an element that never appears`(_ scope: String) throws {
        let compiled = try compileSnippet("ducko_as_await_element '\"field-id\"' targetWin \(scope) 5 'field-id not found' foundField")
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        #expect(compiled.source.contains("return \"ERROR: field-id not found\""))
        #expect(compiled.source.contains(scope == "sheets" ? "my findInSheets(targetWin, \"field-id\")" : "my findByAttr(targetWin, \"AXIdentifier\", \"field-id\", 0, 30)"))
        // A sheet settles before the wait ends, and the element is looked up again after the settle.
        #expect(compiled.source.contains("if elementSettled then exit repeat") == (scope == "sheets"))
    }

    /// The Room Settings opener refuses while a sheet is open, then waits for the sheet its menu item opens.
    @Test func `ducko-room-settings waits for its sheet after the menu click`() throws {
        let captured = try ScriptRunner.capture("ducko-room-settings.sh", arguments: ["room@example.com"])
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        let source = try #require(captured.sources.first)
        let refusal = try #require(source.range(of: "a Room Settings sheet is open already"))
        let click = try #require(source.range(of: "Room Settings\u{2026}", range: refusal.upperBound ..< source.endIndex))
        let wait = try #require(source.range(of: "my findInSheets(contactWin, \"room-settings-view\")", range: click.upperBound ..< source.endIndex))
        #expect(source.range(of: "return \"ok\"", range: wait.upperBound ..< source.endIndex) != nil)
    }

    /// A window found by its scene id is held by its title, so a wait given the scene finds the window again inside its
    /// loop, before each lookup.
    @Test func `ducko_as_await_element given a scene finds the window again on each pass`() throws {
        let compiled = try compileSnippet("ducko_as_await_element '\"field-id\"' chatWin sheets 5 'field-id not found' foundField '\"chat\"'")
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        let source = compiled.source
        let deadline = try #require(source.range(of: "set elementDeadline"))
        let loop = try #require(source.range(of: "\n            repeat\n", range: deadline.upperBound ..< source.endIndex))
        let refind = try #require(source.range(of: "set chatWin to contents of candidateWin", range: loop.upperBound ..< source.endIndex))
        let lookup = try #require(source.range(of: "set foundField to my findInSheets(chatWin, \"field-id\")", range: refind.upperBound ..< source.endIndex))
        let loopEnd = try #require(source.range(of: "\n            end repeat", range: lookup.upperBound ..< source.endIndex))
        #expect(lookup.upperBound <= loopEnd.lowerBound)
        #expect(source.contains("if chatWin is not missing value then set foundField to"))
    }

    /// A loop that matches nothing leaves its variable at the last window, so the lookups must not loop with the
    /// variable they set.
    @Test(arguments: ["ducko_as_raise_scene_window welcome 'Welcome window not found' win", "ducko_as_find_window_by_id contact-list 'Contacts window not found' win"])
    func `window lookups keep their loop variable apart from the window they set`(_ helperCall: String) throws {
        let compiled = try compileSnippet(helperCall)
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        #expect(compiled.source.contains("set win to missing value"))
        #expect(!compiled.source.contains("repeat with win in"))
    }

    @Test func `ducko-status refuses an unknown status before osascript`() throws {
        let captured = try ScriptRunner.capture("ducko-status.sh", arguments: ["busy"])
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("unknown status: busy"))
        #expect(captured.invocations.isEmpty)
    }

    @Test func `ducko-room-topic refuses a topic with a carriage return before typing`() throws {
        let captured = try ScriptRunner.capture("ducko-room-topic.sh", arguments: ["two\rlines"])
        #expect(captured.result.exitCode == 1)
        #expect(captured.result.stderr.contains("Usage:"))
        #expect(captured.invocations.isEmpty)
    }

    @Test func `ducko_as_fill_element compiles and clears the field for an empty value`() throws {
        let compiled = try compileSnippet("ducko_as_fill_element typedField typedText")
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        #expect(compiled.source.contains("if typedText is \"\" then\n                key code 51\n            else\n                keystroke typedText"))
        #expect(compiled.source.contains("return \"ERROR: the field did not take the keyboard focus\""))
    }

    @Test func `ducko_as_await_field_value compiles and reports a field without the typed text`() throws {
        let compiled = try compileSnippet("ducko_as_await_field_value typedField typedText")
        #expect(compiled.exitCode == 0, "AppleScript failed: \(compiled.errors)")
        #expect(compiled.source.contains("return \"ERROR: the field does not hold the typed text\""))
    }

    @Test(arguments: [
        ("DONE:Import Complete\nAccounts connected: 1/1", true),
        ("DONE:Import Complete", true),
        ("ERROR: No Accounts Connected\nunreach@example.com: Connection refused", false),
        ("ERROR: 1: the server offers only PLAIN", false)
    ])
    func `ducko-import reports the outcome of the import`(_ response: String, _ succeeds: Bool) throws {
        let captured = try ScriptRunner.capture("ducko-import.sh", arguments: [], response: response)
        #expect((captured.result.exitCode == 0) == succeeds)
        if succeeds {
            #expect(captured.result.stdout == "\(response.dropFirst("DONE:".count))\n")
        } else {
            #expect(captured.result.stderr == "\(response)\n")
        }
    }

    @Test(arguments: [
        ("REPORT:room@muc.example.com\nother@muc.example.com\n", "room@muc.example.com\nother@muc.example.com\n", true),
        ("REPORT:0 results\n", "0 results\n", true),
        ("ERROR: The server is limiting channel searches, try again in 30 s", "ERROR: The server is limiting channel searches, try again in 30 s\n", false)
    ])
    func `ducko-channel-search prints the rooms found or the reason it failed`(_ response: String, _ shown: String, _ succeeds: Bool) throws {
        let captured = try ScriptRunner.capture("ducko-channel-search.sh", arguments: ["ducko"], response: response)
        #expect((captured.result.exitCode == 0) == succeeds)
        #expect((succeeds ? captured.result.stdout : captured.result.stderr) == shown)
    }

    /// Runs the row choice of ducko-join-room through osascript.
    @Test(arguments: [
        RoomRowCase(matching: ["room-row-a@x"], prior: [], isJid: true, pastDeadline: false, picked: "room-row-a@x"),
        RoomRowCase(matching: ["room-row-a@x"], prior: ["room-row-a@x"], isJid: true, pastDeadline: false, picked: "room-row-a@x"),
        RoomRowCase(matching: [], prior: [], isJid: true, pastDeadline: false, picked: ""),
        RoomRowCase(matching: [], prior: [], isJid: true, pastDeadline: true, picked: "none"),
        RoomRowCase(matching: ["room-row-a@x", "room-row-a@y"], prior: ["room-row-a@x"], isJid: false, pastDeadline: false, picked: "room-row-a@y"),
        RoomRowCase(matching: ["room-row-a@x"], prior: ["room-row-a@x"], isJid: false, pastDeadline: false, picked: ""),
        RoomRowCase(matching: ["room-row-a@x"], prior: ["room-row-a@x"], isJid: false, pastDeadline: true, picked: "room-row-a@x"),
        RoomRowCase(matching: ["room-row-a@x", "room-row-a@y"], prior: ["room-row-a@x", "room-row-a@y"], isJid: false, pastDeadline: true, picked: "ambiguous"),
        RoomRowCase(matching: [], prior: [], isJid: false, pastDeadline: true, picked: "none"),
        RoomRowCase(
            matching: ["room-row-lobby@x", "room-row-lobby@x", "room-row-lobby@y"], prior: ["room-row-lobby@x", "room-row-lobby@y"],
            isJid: false, pastDeadline: false, picked: "room-row-lobby@x"
        ),
        RoomRowCase(matching: ["room-row-a@x", "room-row-a@x"], prior: ["room-row-a@x", "room-row-a@x"], isJid: false, pastDeadline: true, picked: "room-row-a@x")
    ])
    func `ducko-join-room picks the row its join produced`(_ fixture: RoomRowCase) throws {
        func list(_ ids: [String]) -> String {
            "{" + ids.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        }
        let call = "return my pickRoomRow(\(list(fixture.matching)), \(list(fixture.prior)), \(fixture.isJid), \(fixture.pastDeadline))"
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let result = try ScriptRunner.bash([
            "-c", "source \"$1\"; { ducko_as_handlers; echo 'on run'; echo \"$2\"; echo 'end run'; } | /usr/bin/osascript -",
            "bash", helpers, call
        ])
        #expect(result.exitCode == 0, "osascript failed: \(result.stderr)")
        #expect(result.stdout == "\(fixture.picked)\n")
    }

    @Test func `ducko-search prints the match total`() throws {
        let captured = try ScriptRunner.capture("ducko-search.sh", arguments: ["nonsense"], response: "MATCHES:0")
        #expect(captured.result.exitCode == 0, "Script failed: \(captured.result.stderr)")
        #expect(captured.result.stdout == "Matches: 0\n")
    }

    /// On a host that is a VM, as CI runners are, a helper whose check-only exit regressed gets past its VM check. So
    /// this points Foundation's home folder at an empty temporary one, where such a run writes its folders. That leaves
    /// the defaults domain where it is, which is why the cases that pass the profile check use `checkOnlyProfile`.
    private func runSeedHelperCheckOnly(_ arguments: [String]) throws -> ScriptResult {
        let helper = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-import-seed.swift").path
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Ducko seed home \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessInfo.processInfo.environment
        environment["DUCKO_IMPORT_SEED_CHECK_ONLY"] = "1"
        environment["CFFIXED_USER_HOME"] = home.path
        return try ScriptRunner.bash(["-c", "exec swift \"$@\"", "bash", helper] + arguments, environment: environment)
    }

    /// Wraps a helper's output in a script that targets the app's process, as the scripts emit it, and compiles it.
    private func compileSnippet(_ helperCall: String) throws -> CompiledSnippet {
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let emitted = try ScriptRunner.bash([
            "-c",
            "source \"$1\"; ducko_as_handlers; echo 'on run'; echo 'tell application \"System Events\"'; echo 'tell process \"DuckoUITest\"'; eval \"$2\"; echo 'end tell'; echo 'end tell'; echo 'end run'",
            "bash", helpers, helperCall
        ])
        let compiled = try ScriptRunner.bash([
            "-c", "printf '%s' \"$1\" | osacompile -o \"$2\" -", "bash", emitted.stdout, output.path
        ])
        return CompiledSnippet(source: emitted.stdout, exitCode: compiled.exitCode, errors: compiled.stderr)
    }

    private func emitContextMenuSnippet(mode: String) throws -> String {
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let result = try ScriptRunner.bash([
            "-c",
            "source \"$1\"; ducko_as_click_context_menu_item Reply targetElem targetWin \"\" \"$2\"",
            "bash", helpers, mode
        ])
        return result.stdout
    }
}

private extension ScriptValidationTests {
    @Test(arguments: handlerScriptCases)
    func `shared handler wrappers compile and preserve argv without running the app`(_ fixture: HandlerScriptCase) throws {
        let result = try ScriptRunner.capture(
            fixture.script, arguments: fixture.arguments, response: fixture.response, vmPresent: fixture.vmPresent, environment: fixture.environment
        )
        #expect(result.result.exitCode == 0, "Wrapper failed: \(result.result.stderr)")
        #expect(result.compilerExitCode == 0, "AppleScript failed: \(result.compilerErrors)")
        #expect(result.argumentsByCall == fixture.earlierCallArguments + [fixture.appleScriptArguments])
        #expect(result.invocations == fixture.invocations)
        for source in result.sources {
            #expect(source.contains("on findByAttr("))
            #expect(source.contains("on findByRoleAndName("))
            #expect(!source.contains(scriptSpecialArgument))
            #expect(!source.contains(scriptSpecialLine))
            // osacompile accepts a call to a handler nobody defines, which fails only when it runs.
            for call in source.matches(of: /my ([A-Za-z][A-Za-z0-9]*)\(/) {
                #expect(source.contains("on \(call.1)("), "\(fixture.script) calls an undefined handler \(call.1)")
            }
        }
    }

    @Test(arguments: handlerScriptCases)
    func `wrappers cannot bypass the inert command path`(_ fixture: HandlerScriptCase) throws {
        let source = try String(contentsOf: ScriptRunner.scriptsDirectory.appendingPathComponent(fixture.script), encoding: .utf8)
        let body = source.split(separator: "\n").dropFirst().joined(separator: "\n")
        for prefix in ["/bin/", "/sbin/", "/usr/", "/Applications/", "/System/"] {
            #expect(!body.contains(prefix), "Absolute execution needs a fixture safety review: \(fixture.script)")
        }
        #expect(body.contains("source \"$SCRIPT"))
        #expect(body.contains("$(ducko_as_handlers)"))
    }
}

/// A helper's output wrapped in a script for the app's process, with the result of compiling it.
private struct CompiledSnippet {
    let source: String
    let exitCode: Int32
    let errors: String
}

/// The matching row ids, the ids listed before the submit, whether the input was a room JID, whether the deadline has
/// passed, and the row ducko-join-room should pick.
struct RoomRowCase {
    let matching: [String]
    let prior: [String]
    let isJid: Bool
    let pastDeadline: Bool
    let picked: String
}

private struct HandlerScriptCase {
    let script: String
    let arguments: [String]
    let appleScriptArguments: [String]
    var response = "ok"
    var invocations = ["osascript"]
    /// Arguments of the osascript calls before the last, for scripts that call it more than once.
    var earlierCallArguments: [[String]] = []
    var environment: [String: String] = [:]
    var vmPresent = false
}

/// Every `ducko-*.sh` the skill runs, leaving out the sourced helper library.
private func automationScripts() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: ScriptRunner.scriptsDirectory.path)
        .filter { $0.hasPrefix("ducko-") && $0.hasSuffix(".sh") && $0 != "ducko-helpers.sh" }
        .sorted()
}

/// A profile name no workflow uses, for the seed helper's check-only runs.
private let checkOnlyProfile = "import-check-only"

private let scriptSpecialArgument = "quote\" and ' newline\n dollar$ backtick` backslash\\ $(not-a-command)"

/// The same characters on one line, for a script that types its argument and refuses a line break.
private let scriptSpecialLine = "quote\" and ' dollar$ backtick` backslash\\ $(not-a-command)"

private let handlerScriptCases: [HandlerScriptCase] = [
    HandlerScriptCase(script: "ducko-add-affiliation.sh", arguments: ["room@example.com", scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-room-settings.sh", "ducko-room-settings-tab.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-add-bookmark.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument], invocations: ["ducko-bookmarks.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-add-contact.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-attach.sh", arguments: ["/etc/hosts"], appleScriptArguments: [], invocations: ["osascript", "swift"], environment: ["DUCKO_PID": "4242"]),
    HandlerScriptCase(script: "ducko-avatar.sh", arguments: ["/etc/hosts"], appleScriptArguments: [], invocations: ["ducko-profile.sh", "osascript", "swift"], environment: ["DUCKO_PID": "4242"]),
    HandlerScriptCase(script: "ducko-avatar-remove.sh", arguments: [], appleScriptArguments: [], invocations: ["ducko-profile.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-bookmarks.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-blocked-contacts.sh", arguments: ["open"], appleScriptArguments: ["-", "open", ""], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-blocked-contacts.sh", arguments: ["add", scriptSpecialArgument], appleScriptArguments: ["-", "add", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-blocked-contacts.sh", arguments: ["remove", scriptSpecialArgument], appleScriptArguments: ["-", "remove", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-channel-search.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], response: "REPORT:0 results\n"),
    HandlerScriptCase(script: "ducko-chat-header.sh", arguments: ["history"], appleScriptArguments: ["-", "history-button"]),
    HandlerScriptCase(script: "ducko-chat-tabs.sh", arguments: ["close-all"], appleScriptArguments: ["-", "close-all", ""]),
    HandlerScriptCase(script: "ducko-chat-tabs.sh", arguments: ["select", scriptSpecialArgument], appleScriptArguments: ["-", "select", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-change-nickname.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-change-password.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-contact-info.sh", arguments: [scriptSpecialArgument, "remove"], appleScriptArguments: ["-", "contact-info-remove", "remove"], invocations: ["pgrep", "osascript", "osascript"], earlierCallArguments: [["-", scriptSpecialArgument, "remove"]]),
    HandlerScriptCase(script: "ducko-contact-menu.sh", arguments: [scriptSpecialArgument, "history"], appleScriptArguments: ["-", scriptSpecialArgument, "history", "History"]),
    HandlerScriptCase(script: "ducko-contact-menu.sh", arguments: [scriptSpecialArgument, "remove"], appleScriptArguments: ["-", scriptSpecialArgument, "remove", "Remove Contact…"], invocations: ["pgrep", "osascript"]),
    HandlerScriptCase(script: "ducko-contact-search.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], response: "REPORT:Matches: 0\n"),
    HandlerScriptCase(script: "ducko-destroy-room.sh", arguments: [scriptSpecialArgument], appleScriptArguments: [], invocations: ["ducko-room-settings.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-device-trust.sh", arguments: [scriptSpecialArgument, "trust"], appleScriptArguments: ["-", scriptSpecialArgument, "trust"]),
    HandlerScriptCase(script: "ducko-edit-account.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-edit-profile.sh", arguments: ["--fullname", scriptSpecialArgument, "--nickname", scriptSpecialArgument, "--email", scriptSpecialArgument, "--save"], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, "yes"], invocations: ["ducko-profile.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-encrypt.sh", arguments: ["fingerprints"], appleScriptArguments: ["-", "fingerprints"], response: "ok"),
    HandlerScriptCase(script: "ducko-focus-contacts.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-history-search.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-import.sh", arguments: [], appleScriptArguments: [], response: "DONE:Import Complete"),
    HandlerScriptCase(script: "ducko-import-account.sh", arguments: ["fill", "1", scriptSpecialArgument], appleScriptArguments: ["-", "1", scriptSpecialArgument], vmPresent: true),
    HandlerScriptCase(script: "ducko-invite-user.sh", arguments: ["room@example.com", scriptSpecialArgument], appleScriptArguments: ["-", "room@example.com", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-join-room.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument.replacingOccurrences(of: " ", with: "-"), scriptSpecialArgument, "room-row-\(scriptSpecialArgument.replacingOccurrences(of: " ", with: "-"))@"], response: "JOINED:room@example.com"),
    HandlerScriptCase(script: "ducko-join-room.sh", arguments: ["  My  Room  ", ""], appleScriptArguments: ["-", "My--Room", "", "room-row-My--Room@"], response: "JOINED:my--room@muc.example.com"),
    HandlerScriptCase(script: "ducko-join-room.sh", arguments: ["  room@muc.example.com "], appleScriptArguments: ["-", "room@muc.example.com", "", "room-row-room@muc.example.com"], response: "JOINED:room@muc.example.com"),
    HandlerScriptCase(script: "ducko-join-room.sh", arguments: ["Room@muc.example.com"], appleScriptArguments: ["-", "Room@muc.example.com", "", "room-row-Room@muc.example.com"], response: "JOINED:Room@muc.example.com"),
    HandlerScriptCase(script: "ducko-leave-room.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-login.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-message-list.sh", arguments: ["jump"], appleScriptArguments: ["-", "jump-to-newest"]),
    HandlerScriptCase(script: "ducko-new-chat.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-omemo-reset.sh", arguments: ["all"], appleScriptArguments: ["-", "all", ""]),
    HandlerScriptCase(script: "ducko-omemo-reset.sh", arguments: ["device", scriptSpecialArgument], appleScriptArguments: ["-", "device", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-register.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-register-fields.sh", arguments: ["fill", "nick", scriptSpecialArgument], appleScriptArguments: ["-", "fill", "nick", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-remove-contact.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-"], invocations: ["pgrep", "osascript", "osascript"], earlierCallArguments: [["-", scriptSpecialArgument]]),
    HandlerScriptCase(script: "ducko-remove-bookmark.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-bookmarks.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-preferences.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-preferences-tab.sh", arguments: ["Accounts"], appleScriptArguments: ["-", "Accounts"]),
    HandlerScriptCase(script: "ducko-profile.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-room-settings.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-room-settings-tab.sh", arguments: ["Members"], appleScriptArguments: ["-", "Members"]),
    HandlerScriptCase(script: "ducko-room-topic.sh", arguments: [scriptSpecialLine], appleScriptArguments: ["-", scriptSpecialLine, scriptSpecialLine]),
    HandlerScriptCase(script: "ducko-room-topic.sh", arguments: [], appleScriptArguments: ["-"], response: "TOPIC:No topic set"),
    HandlerScriptCase(script: "ducko-room-topic.sh", arguments: [" \t topic  "], appleScriptArguments: ["-", " \t topic  ", "topic"]),
    HandlerScriptCase(script: "ducko-room-topic.sh", arguments: ["  "], appleScriptArguments: ["-", "  ", "No topic set"]),
    HandlerScriptCase(script: "ducko-search.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], response: "MATCHES:0"),
    HandlerScriptCase(script: "ducko-select-mode.sh", arguments: ["Register"], appleScriptArguments: ["-", "Register"]),
    HandlerScriptCase(script: "ducko-send.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-send-unencrypted.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-sign-in-security.sh", arguments: ["dont-allow"], appleScriptArguments: ["-", "dont-allow"]),
    HandlerScriptCase(script: "ducko-sign-in-security.sh", arguments: ["allow"], appleScriptArguments: ["-", "allow"], invocations: ["pgrep", "osascript"]),
    HandlerScriptCase(script: "ducko-status.sh", arguments: ["away", scriptSpecialArgument], appleScriptArguments: ["-", "Away", scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-status.sh", arguments: ["dnd", "  busy \n"], appleScriptArguments: ["-", "Do Not Disturb", "  busy \n", "busy"]),
    HandlerScriptCase(script: "ducko-status.sh", arguments: ["xa", "   "], appleScriptArguments: ["-", "Extended Away", "   ", "Extended Away"]),
    HandlerScriptCase(script: "ducko-status.sh", arguments: ["offline", "gone"], appleScriptArguments: ["-", "Offline", "gone", "Offline"]),
    HandlerScriptCase(script: "ducko-sort.sh", arguments: ["byStatus"], appleScriptArguments: ["-", "byStatus"]),
    HandlerScriptCase(script: "ducko-reply.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-connection-info.sh", arguments: [], appleScriptArguments: [], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "osascript"])
]
