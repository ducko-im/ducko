import Foundation
import Testing

/// Hermetic coverage for the guards in `Skills/lume-vm/scripts/vm.sh`, run
/// from a stand-in checkout against a `lume` that records the guest commands
/// instead of reaching a VM.
struct VMScriptTests {
    @Test func `sync refuses a VM started from another checkout`() throws {
        let run = try runVM(["sync"], servesThisCheckout: false)
        #expect(run.result.exitCode == 1)
        #expect(run.result.stderr.contains("the VM is serving /elsewhere"))
        #expect(!run.guestCommands.contains { $0.contains("rsync") })
    }

    @Test func `sync copies the tree when the VM serves this checkout`() throws {
        let run = try runVM(["sync"], servesThisCheckout: true)
        #expect(run.result.exitCode == 0, "sync failed: \(run.result.stderr)")
        #expect(run.guestCommands.contains { $0.contains("rsync -an") && $0.contains("rsync -a --delete") })
    }

    @Test(arguments: zip([[], ["--skip", "Foo"], ["--filter", "Foo"], ["--filter=Foo"]], [true, true, false, false]))
    func `itest runs only the UI layer unless the caller names a filter`(_ arguments: [String], _ addsDefault: Bool) throws {
        let run = try runVM(["itest"] + arguments, servesThisCheckout: true)
        #expect(run.result.exitCode == 0, "itest failed: \(run.result.stderr)")
        let test = try #require(run.guestCommands.last { $0.contains("swift test") })
        #expect(test.contains("UILayer") == addsDefault)
        for argument in arguments {
            #expect(test.contains(argument))
        }
    }

    @Test func `the zsh runner keeps startup files from changing the stub PATH`() throws {
        // zsh reads `$ZDOTDIR/.zshenv` on every start unless told not to.
        let result = try ScriptRunner.withStubs([".zshenv": "PATH=/startup-file:$PATH\n"]) { startup in
            try ScriptRunner.zsh(["-c", "print -r -- $PATH"], environment: ["ZDOTDIR": startup.path, "PATH": "/stubs"])
        }
        #expect(result.stdout == "/stubs\n")
    }

    @Test func `a changed helper source runs under a new binary name`() throws {
        let swiftc = """
        #!/bin/zsh -f
        while (( $# )); do [[ $1 == -o ]] && { : > $2; chmod +x $2; }; shift; done
        """
        let commands = try ScriptRunner.withCheckout(skill: "lume-vm", scripts: ["vm.sh", "axbuttons.swift"]) { checkout in
            let log = checkout.root.appendingPathComponent("guest.log")
            try ScriptRunner.withStubs(["lume": lumeStub, "swiftc": swiftc]) { stubs in
                let environment = ["PATH": "\(stubs.path):/usr/bin:/bin", "LUME_LOG": log.path, "LUME_CHECKOUT": checkout.resolved]
                let first = try ScriptRunner.zsh([checkout.script("vm.sh"), "ax", "list"], environment: environment)
                #expect(first.exitCode == 0, "ax failed: \(first.stderr)")
                let source = try FileHandle(forWritingTo: URL(fileURLWithPath: checkout.script("axbuttons.swift")))
                try source.seekToEnd()
                try source.write(contentsOf: Data("// changed\n".utf8))
                try source.close()
                let second = try ScriptRunner.zsh([checkout.script("vm.sh"), "ax", "list"], environment: environment)
                #expect(second.exitCode == 0, "ax failed: \(second.stderr)")
            }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        try #require(commands.count == 2)
        #expect(commands[0] != commands[1])
    }

    /// Runs a copy of `vm.sh` placed in a stand-in checkout, so the paths it
    /// derives from its own location stay inside the temporary folder.
    private func runVM(_ arguments: [String], servesThisCheckout: Bool) throws -> (result: ScriptResult, guestCommands: [String]) {
        try ScriptRunner.withCheckout(skill: "lume-vm", scripts: ["vm.sh"]) { checkout in
            let log = checkout.root.appendingPathComponent("guest.log")
            let result = try ScriptRunner.withStubs(["lume": lumeStub]) { stubs in
                try ScriptRunner.zsh(
                    [checkout.script("vm.sh")] + arguments,
                    environment: [
                        "PATH": "\(stubs.path):/usr/bin:/bin",
                        "LUME_LOG": log.path,
                        "LUME_CHECKOUT": servesThisCheckout ? checkout.resolved : "/elsewhere"
                    ]
                )
            }
            let commands = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            return (result, commands)
        }
    }
}

/// `ssh <vm> --storage <storage> -t <timeout> <command>` puts the guest command seventh.
private let lumeStub = """
#!/bin/zsh -f
case $1 in
ls) print "ducko macOS running" ;;
ssh)
    print -r -- "$7" >> "$LUME_LOG"
    [[ $7 == cat*vm-checkout* ]] && print -r -- "$LUME_CHECKOUT"
    ;;
esac
exit 0
"""
