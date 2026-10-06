# Contributing to Ducko

## Reporting a Bug

- Ensure you're running the latest version of Ducko.
- Check whether the bug is [already reported](https://github.com/ducko-im/ducko/issues).
- If not, [open a new issue](https://github.com/ducko-im/ducko/issues/new) with reproduction steps.

## Proposing a Feature

[Open an issue](https://github.com/ducko-im/ducko/issues/new) describing the change before writing code, then open a PR against `main` that references the issue.

## Development Setup

See the [README](../README.md) for prerequisites, building, running, testing, and code style setup. Full conventions live in [`AGENTS.md`](../AGENTS.md) (Module Boundaries, Code Conventions). At a glance:

- Module boundaries are strict and enforced at build time.
- Pure Swift — no `@objc`, no NSObject subclasses.
- Swift Testing (`@Test`, `#expect`, `#require`), not XCTest.
- All types must be `Sendable`; use actors for mutable shared state.
- Never use `default:` on project-defined enums.

Run `./Scripts/format.sh`, `./Scripts/lint.sh`, and `swift test` before pushing.

## Use of Generative AI

AI tools may assist your work, but every contribution must be fully understood, reviewed, and tested by you. Only submit changes you can clearly explain and justify. Unverified or low-quality AI output will be closed without further review.

## Code of Conduct

Help us keep Ducko open and inclusive. Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

