# Ducko

A native macOS XMPP client — spiritual successor to Adium.

## Tech Stack

- Swift 6.2, macOS 26+ on Apple Silicon (arm64), SwiftPM (no Xcode project)
- SwiftUI, SwiftData (metadata only), Sparkle
- Custom XMPP implementation (no libpurple, no XMPPFramework)
- All types use Swift strict concurrency (`Sendable`, actors, structured concurrency)
- Messages stored as append-only JSONL transcript files (`FileTranscriptStore`), not SwiftData

## Module Boundaries

```
DuckoXMPP   # standalone XMPP library, depends on CLibxml2 + CDnssd (system libs), swift-log, SwiftNIO + NIOSSL
DuckoCore   # depends on DuckoXMPP only
DuckoData   # depends on DuckoCore
DuckoUI     # depends on DuckoCore
DuckoApp    # depends on all + Sparkle
DuckoCLI    # depends on DuckoCore, DuckoData, DuckoXMPP + swift-argument-parser
```

These boundaries are strict:
- DuckoXMPP must never import other Ducko modules
- DuckoCore must never import DuckoData or DuckoUI
- DuckoUI must never import DuckoData or DuckoXMPP
- DuckoCLI must never import DuckoUI or Sparkle

## Feature Parity

DuckoApp (GUI) and DuckoCLI (CLI) are independent consumers of DuckoCore. When adding features:

- **CLI formatters**: Update `ANSIFormatter`, `PlainFormatter`, and `JSONFormatter` for any new `XMPPEvent` cases or changed event semantics.
- **REPL commands**: Add corresponding REPL commands (e.g., `/pm`, `/moderate`) when the GUI gets new interactive features. Add the case to `REPLCommand` in `Sources/DuckoCLI/REPL/`, then the handler in the matching `REPL*Commands.swift` file there, which `REPL.swift` dispatches to.
- **ducko-ui scripts**: Add automation scripts in `Skills/ducko-ui/scripts/` for new UI elements (buttons, context menu items, sheets). Update the ducko-ui skill's script inventory and accessibility identifier list.

## Build & Test

```
swift build
swift build --build-tests            # compile test targets without running them
swift test
swift test --filter DuckoXMPPTests   # run a specific test target
swift run DuckoApp                   # run GUI
swift run DuckoCLI                   # run CLI
```

Note: `swift build` only compiles executable and library targets. Use `swift build --build-tests` to verify test target compilation.

After `swift build`, binaries are directly runnable from `.build/debug/` (e.g., `.build/debug/DuckoCLI`).

`Sources/DuckoTestSupport/` is a regular library target that hosts shared test mocks and helpers (`MockPersistenceStore`, `MockTranscriptStore`, `NullCredentialStore`, `boundedOutcome`). Multiple test targets (`DuckoCoreTests`, `DuckoUITests`) depend on it via plain `import DuckoTestSupport`. Add new shared fakes here when more than one test target needs them — single-target fakes stay in the target's own folder.

### TLS integration fixtures

Transport fixtures use a local Python peer and fresh test certificates. Run the TLS policy cases with a Python linked to modern OpenSSL (including TLS 1.3):

```sh
DUCKO_TLS_PYTHON=/opt/homebrew/bin/python3 swift test --filter 'NIO|Transport|TLSInfo'
```

`NIOProtocolVersionTests` is skipped when `DUCKO_TLS_PYTHON` is unset; report that skip rather than treating it as policy coverage.

The other opt-in fixtures require a disposable environment: `DUCKO_TLS_INSTALLED_ROOT=1` exercises a root already installed there, `DUCKO_TLS_EXPECT_UNTRUSTED=1` checks its removal, and `DUCKO_TLS_SRV_FIXTURE=1` exercises a configured local SRV fixture. `DUCKO_TLS_FIXTURE_DIRECTORY` selects that environment's certificate files.

Never install fixture trust into a developer's normal keychains. Ordinary tests inject roots without modifying trust stores.

### Integration Tests

Integration tests live in a sibling SwiftPM package at `IntegrationTests/` so a plain `swift test` at the repo root never runs them. They run against a live XMPP server and skip automatically when credentials are not set.

Credentials live in `IntegrationTests/.env.test` (git-ignored; copy `IntegrationTests/.env.test.example`). `TestCredentials` auto-loads that file on first access. A linked git worktree has no copy, so the suites skip there; symlink the main checkout's file into the worktree rather than copying or reading it.

```
swift test --package-path IntegrationTests
swift test --package-path IntegrationTests --filter AvatarTests
swift test --package-path IntegrationTests --filter "Alice connects to server"
```

Sourcing the file in the shell still works and overrides any value from the file.

When the live test server has drifted (OMEMO devicelist past `pruneProbeCap = 64`, or the seeded `subscription=both` baseline lost), run the env-gated reset suite to retract devicelists and reseed roster subscriptions:

```
DUCKO_RESET_FIXTURES=1 swift test --package-path IntegrationTests --filter ResetTestServerState
```

It is skipped by default and requires all four `DUCKO_TEST_*` credential pairs.

`DUCKO_TEST_REGISTRATION=1` opts into the destructive `account register`/`unregister` round-trip in `CLIAccountTests` (off by default, like `DUCKO_RESET_FIXTURES`). It registers a randomized ephemeral `ducko-it-*` account and immediately unregisters it, so enable it only against a server whose XEP-0077 in-band registration is known-good:

```
DUCKO_TEST_REGISTRATION=1 swift test --package-path IntegrationTests --filter CLIAccount
```

`TestHarness` runs a bootstrap probe before the first test executes and auto-runs the OMEMO reset when any account's PEP devicelist crosses `autoResetDevicelistThreshold` (32 entries). The env-gated suite remains useful for non-OMEMO drift (roster subscription baselines, the dave-empty invariant) since the auto-reset only touches the OMEMO devicelist path.

## Packaging

Ducko packages the app and embedded CLI for arm64 only. Upstream Sparkle binaries retain their supplied architecture slices.

`version.env` is the single source of truth for app metadata (`APP_NAME`, `BUNDLE_ID`, `EXEC_NAME`, `CLI_NAME`). All scripts source it.

```
Scripts/package_app.sh [debug|release]   # build + assemble .app bundle
Scripts/compile_and_run.sh               # package + launch (dev loop)
Scripts/create_dmg.sh                    # wrap .app in DMG
Scripts/release.sh                       # build, sign, notarize, DMG, zip
```

`Resources/Entitlements.plist` holds app entitlements. `Resources/Assets.car` is the precompiled Liquid Glass icon.

`Scripts/package_app.sh` injects `<key>DuckoBuildConfiguration</key><string>${CONF}</string>` (`debug` or `release`) into the bundle's `Info.plist`. The integration-test UI harness (`AppAccessor.assertDebugBundle`) reads this pre-launch and refuses to spawn a release-built bundle, since release ignores `DUCKO_PROFILE` and would route test credentials into the production Keychain and `~/Library/Application Support/Ducko/`.

## Logging

Uses `swift-log` as a facade with dual backends:

- **OSLog backend** (`OSLogHandler`) — forwards to Apple's unified logging for Console.app/Xcode debugging, with message text left at OSLog's default `<private>` redaction so JIDs and stanza fragments stay out of Console.app and sysdiagnose archives (use the file log for message text)
- **File backend** (`FileLogHandler`) — writes to `~/Library/Application Support/<app-dir>/Logs/ducko.log` with size-based rotation (5 MB, 5 archives)

Logger labels use dot notation: `Logger(label: "im.ducko.xmpp.client")` — last component is the category (flat lowercase), rest is the subsystem.

`LoggingConfiguration.bootstrap()` is called once at launch (DuckoApp.init / CLIBootstrap.setUp). File log verbosity is controlled by the `advancedLogLevel` UserDefaults key (UI: Preferences > Advanced > Log Level) — "default" → info, "debug" → debug, "verbose" → trace.

**Privacy policy**: error/warning/info/notice must never contain sensitive data (passwords, tokens, keys). Only debug/trace may contain JIDs, stanza fragments. Ultra-sensitive data is never logged.

**Export**: `ducko logs` CLI subcommand, Help > Export Logs… in GUI.

## Dev/Prod Isolation

`BuildEnvironment` (in DuckoCore) centralizes `#if DEBUG` config. Debug builds use separate storage to avoid polluting production data:

| Component | Prod | Dev |
|-----------|------|-----|
| SwiftData (metadata) | `~/Library/Application Support/Ducko/` | `~/Library/Application Support/Ducko-Dev/` |
| Transcripts (JSONL) | `~/Library/Application Support/Ducko/Transcripts/` | `~/Library/Application Support/Ducko-Dev/Transcripts/` |
| Credentials | macOS Keychain | `Ducko-Dev/credentials.json` (file-based) |
| UserDefaults | `.standard` | `UserDefaults(suiteName: "im.ducko.dev")` |

Set `DUCKO_USE_KEYCHAIN=1` to use real Keychain in debug builds.

Set `DUCKO_PROFILE=<name>` to run multiple isolated instances side by side:

| Component | Default Dev | `DUCKO_PROFILE=alice` |
|-----------|-------------|----------------------|
| SwiftData (metadata) | `Ducko-Dev/` | `Ducko-Dev-alice/` |
| Transcripts (JSONL) | `Ducko-Dev/Transcripts/` | `Ducko-Dev-alice/Transcripts/` |
| Credentials | `Ducko-Dev/credentials.json` | `Ducko-Dev-alice/credentials.json` |
| UserDefaults | `im.ducko.dev` | `im.ducko.dev.alice` |

## Lint & Format

SwiftFormat and SwiftLint are installed via Homebrew. SwiftLint is pinned exactly via `swiftlint_version` in `.swiftlint.yml`, and CI installs that release's portable binary. When Homebrew moves past the pin, bump it and fix any new violations in the same commit.

`file_length` and `type_body_length` are a ratchet. A `// swiftlint:disable` marker for either rule names that file or type as a split candidate, not an exemption, and the set of markers only shrinks. When code trips a limit, split it rather than raising the limit or adding a marker. Both counts exclude comment-only and blank lines, so `wc -l` overstates them.

Periphery is the commercial Periphery Pro CLI, free for open-source projects. Install it with `brew install periphery-pro/tap/periphery-cli`, which conflicts with the archived `periphery` formula, so uninstall that first. Every scan validates the license over the network, so sign in once locally with `periphery auth login`. The tap only offers the latest release, so CI installs the exact version pinned as `PERIPHERY_VERSION` in `ci.yml`. When the tap moves past the pin, bump it and fix any new findings in the same commit. CI authenticates with the `PERIPHERY_TOKEN` repo secret. GitHub withholds secrets from fork pull requests, so CI sets `SKIP_PERIPHERY` for them and `lint.sh` skips the scan.

```
./Scripts/format.sh            # Auto-format + autocorrect
./Scripts/lint.sh              # Check format + lint + unused code (read-only)
./Scripts/install-hooks.sh     # install pre-commit hook (runs lint.sh before commit)
```

Lint needs Xcode 27. The macOS 27 SDK declares `@State` as a macro, so Periphery reports different unused properties than under Xcode 26, and `--strict` fails on either toolchain's leftovers. CI (`ci.yml`, `release.yml`) runs on the `xcode-27` runner image; bump both workflows together with the local Xcode.

## Agent Skills

All project-visible agent skills live under `Skills/`. `.claude/skills` and `.agents/skills` are single top-level symlinks pointing at `../Skills`, so adding a new skill is just `mkdir Skills/<name>` — nothing else to wire up.

The set is a mix of Ducko-original skills written for this repo and upstream-derived skills merged from open-source catalogs. See `Skills/ATTRIBUTION.md` for per-skill upstream sources and MIT copyright notices.

`AGENTS.md` is the shared instructions file; `.claude/CLAUDE.md` is symlinked to it so Claude Code picks up the same content.

`.mcp.json` configures `sosumi` (`https://sosumi.ai/mcp`) for live Apple developer documentation lookups.

## Code Conventions

- **No Objective-C**: pure Swift, no `@objc`, no NSObject subclasses. The exceptions:
  - NSObject subclasses conforming to AppKit/Foundation delegate protocols (e.g. `AppDelegate`, `NotificationManager`, the contact-list `Coordinator`)
  - AppKit view subclasses where an override or a hosted cell is the only hook (e.g. `HostingTableCellView`, `ContactListTableControl`, `QuickLookHostView`, `JumpButtonHost`)
  - A minimal `@objc` target/action trampoline where AppKit requires a selector (e.g. `NSMenuItem.action`, which can't take a closure)
- **Value types preferred**: structs and enums over classes, except where reference semantics are required (`@Observable`, `@Model`, actors)
- **XMLElement naming**: our `XMLElement` struct (in DuckoXMPP) conflicts with Foundation's `NSXMLElement`. In DuckoXMPP files, do not `import Foundation` — use stdlib alternatives instead. In DuckoCore files (which always import Foundation), use `DuckoXMPP.XMLElement` to disambiguate.
- **Testing**: use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest. Struct-based suites, parameterized tests via `@Test(arguments:)`.
- **Concurrency**: value types (struct/enum) are automatically `Sendable`. Never use `@unchecked Sendable`. Use actors for mutable shared state.
- **libxml2 / CLibxml2**: DuckoXMPP uses libxml2 via a `CLibxml2` system library target (`Sources/CLibxml2/`). For C callbacks that need a back-reference to a Swift class, use the `Unmanaged.passUnretained(self).toOpaque()` pattern — do not use NSObject or `@objc`.
- **CryptoKit**: On macOS 26 it does not re-export Foundation, so `some DataProtocol` is out of scope in DuckoXMPP. Use `[UInt8]` for parameters that feed `HashFunction.hash(data:)`.
- **Exhaustive switches**: Never use `default:` when switching on project-defined enums. List all cases explicitly so the compiler catches new cases at build time.
- **SIGPIPE**: DuckoApp does not ignore SIGPIPE, so a send on a peer-reset socket would terminate it. NIO owns XMPP channel sockets and their SIGPIPE suppression. Open raw TCP/SOCKS5 sockets through `connectTCPSocket` and call `disableSIGPIPE` on accepted sockets. Never call `signal(SIGPIPE, SIG_IGN)` in tests, since it masks that crash.
- **User-facing error text**: each layer adds only context it uniquely knows. DuckoXMPP error payloads and `displayText` carry bare, readable detail, including the phrases for its typed protocol conditions and failure reasons. That detail has no API names, no numeric status codes, and no repeated failure label. The DuckoCore `LocalizedError` extension adds the single summary label. DuckoUI and DuckoCLI show that text without an operation label like "Error:" or "Failed:" and signal error state visually instead. The CLI's human-readable formatters add only a single lowercase `error:` severity marker, and JSON signals severity through its `type` field. swift-argument-parser's own `Error: ` prefix on errors thrown out of a command is left to that library. When an event carries raw pieces that must be combined into one message (e.g. a stream error's condition and text), DuckoCore composes it once in a helper that GUI and CLI share, while JSON output keeps the raw structured fields.
