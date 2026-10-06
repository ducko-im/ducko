<p align="center">
  <img src="AppIcon.png" width="128" height="128" alt="Ducko app icon">
</p>

<h1 align="center">Ducko</h1>

<p align="center">
  A modern macOS XMPP client – spiritual successor to <a href="https://github.com/adium/adium">Adium</a>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS_26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/swift-6.2-orange" alt="Swift 6.2">
  <img src="https://img.shields.io/github/license/ducko-im/ducko" alt="License">
</p>

---

Ducko carries forward the spirit of Adium: personality-driven and unapologetically Mac-native. Where Adium unified dozens of protocols through libpurple, Ducko starts focused on XMPP and builds outward from a modern Swift foundation.

## Getting Started

Requires macOS 26 or later on a Mac with Apple Silicon.

```sh
swift build               # Build all modules
swift run DuckoApp        # Run the GUI
swift run DuckoCLI        # Run the CLI
swift test                # Run tests
```

### Integration Tests

Integration tests live in a sibling SwiftPM package at `IntegrationTests/` so a plain `swift test` at the repo root never runs them. They run against a live XMPP server and skip when credentials are not configured:

```sh
cp IntegrationTests/.env.test.example IntegrationTests/.env.test   # Fill in real credentials
swift test --package-path IntegrationTests                          # All suites
swift test --package-path IntegrationTests --filter AvatarTests     # One suite
```

`IntegrationTests/.env.test` is loaded automatically on first use; sourcing it in the shell is optional and still overrides.

## Code Style

[SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and [SwiftLint](https://github.com/realm/SwiftLint) enforce code style, and Periphery Pro flags unused code. Install them via Homebrew:

```sh
brew install swiftlint swiftformat periphery-pro/tap/periphery-cli
periphery auth login              # Periphery Pro license, free for open source
./Scripts/install-hooks.sh        # Pre-commit hook (run once after cloning)
./Scripts/format.sh               # Auto-format + autocorrect
./Scripts/lint.sh                 # Check format + lint + unused code (read-only)
```

## Agent Skills

Project-specific [agent skills](https://agentskills.io/) live in `Skills/`. See individual `SKILL.md` files for details.

## Architecture

Six SwiftPM modules with clear dependency boundaries:

```
DuckoXMPP  (standalone XMPP protocol implementation)
    ^
    |
DuckoCore  (domain types, services, business logic)
    ^            ^
    |            |
DuckoData    DuckoUI
    ^            ^
    |            |
    +-- DuckoApp --+  (+ Sparkle)

DuckoCLI  →  depends on DuckoCore, DuckoData, DuckoXMPP  (+ swift-argument-parser)
```

| Module | Purpose |
|--------|---------|
| **DuckoXMPP** | Standalone, reusable XMPP library. Connection, stream parsing, SASL auth, stanza types, JID types, XEP modules. |
| **DuckoCore** | Domain layer. Account/Contact/Conversation types, service objects, message filter pipeline. |
| **DuckoData** | Persistence layer. SwiftData models, mapping to/from domain types, query helpers. |
| **DuckoUI** | View layer. SwiftUI views, view models, window management. |
| **DuckoApp** | GUI entry point. Dependency wiring, menu bar, Sparkle updates, lifecycle. |
| **DuckoCLI** | CLI entry point. Subcommands, interactive REPL, terminal output formatting. |

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Platform | macOS 26+, Apple Silicon | Focus. Adium was Mac-only and beloved for it. |
| Language | Swift 6.2 | Latest concurrency features, strict sendability |
| Protocol | XMPP only (v1) | Start focused, expand later |
| Build system | SwiftPM | No Xcode project. Clean, reproducible builds. |
| Distribution | Direct (Sparkle) | No App Store sandbox constraints |
| Persistence | SwiftData (metadata) + JSONL transcripts | Declarative metadata store; append-only message log keeps history portable |
| UI | SwiftUI + separate windows | Adium-style multi-window UX |
| CLI | swift-argument-parser | Scriptable + interactive access alongside GUI |

## License

Distributed under the GNU General Public License v3.0 with an additional permission to link with BoringSSL. See the [LICENSE](LICENSE) file for details. Bundled dependency licences are in [Resources/ThirdPartyLicenses](Resources/ThirdPartyLicenses).
