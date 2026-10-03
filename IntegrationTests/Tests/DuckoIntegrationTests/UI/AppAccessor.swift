// Split candidate.
// swiftlint:disable file_length
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Logging

private let log = Logger(label: "im.ducko.integrationtests.ui")

/// Drives the packaged `Ducko.app` bundle as a child process and exposes
/// identifier-keyed accessibility queries to UI integration tests.
///
/// Mirrors `CLIProcess`: the actor owns the launched-app handle, an env
/// dictionary, and two LIFO cleanup queues (one that runs while the app is
/// still alive, one that runs after exit). All public methods are
/// identifier-keyed so the non-Sendable `AXUIElement` handles never cross the
/// actor boundary; each call walks the AX tree from the application root and
/// reacquires its element, which also avoids stale handles after a SwiftUI
/// view refresh.
actor AppAccessor { // swiftlint:disable:this type_body_length
    /// Boot marker the launch helper waits for.
    enum LaunchTarget {
        /// Fresh `DUCKO_PROFILE` — the welcome screen renders the
        /// `setup-mode-picker`.
        case welcome
        /// Pre-seeded profile — the contact list auto-connects and renders.
        case contactList
    }

    /// Cleanup-action ordering bucket.
    enum CleanupPhase {
        /// Runs before `process.terminate()` so the action can drive UI
        /// (e.g. reset presence, leave a room).
        case inApp
        /// Runs after the app exits (e.g. profile-directory removal).
        case postExit
    }

    nonisolated let profile: String
    nonisolated let environment: [String: String]

    private let axDriver = AXDriver()

    /// `NSRunningApplication` instead of Foundation `Process` so the spawn
    /// goes through LaunchServices (`NSWorkspace.openApplication`). Direct
    /// `Process.run()` on `Ducko.app/Contents/MacOS/DuckoApp` produces a
    /// process that authenticates and loads the roster but never registers
    /// any visible NSWindow with the WindowServer — `CGWindowList` returns
    /// zero windows for the PID, the AX walker never finds `contact-list`,
    /// and every UI test times out at the launch barrier. LaunchServices
    /// performs the missing GUI registration so `kAXIdentifierAttribute`
    /// lookups succeed.
    private var process: NSRunningApplication? {
        didSet { axDriver.pid = process?.processIdentifier }
    }

    private var inAppCleanupActions: [@Sendable () async -> Void] = []
    private var postExitCleanupActions: [@Sendable () async -> Void] = []

    init(profile: String) {
        self.profile = profile

        // Mirror CLIProcess's environment allowlist: only the keys the app
        // needs to find Foundation bundles, locales, and the user's home
        // directory. Importantly we never inherit DUCKO_USE_KEYCHAIN, so a
        // stray "1" in the developer's shell cannot route test passwords
        // into the real macOS Keychain.
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "DUCKO_PROFILE": profile
        ]
        for key in ["HOME", "PATH", "LANG", "LC_ALL"] {
            if let value = parent[key] {
                env[key] = value
            }
        }
        self.environment = env
    }

    // MARK: - Bundle resolution

    /// Path to the packaged `Ducko.app` bundle. Resolved relative to this
    /// file via `#filePath`; mirrors `CLIProcess.binaryPath`'s walk-up.
    /// Canonical input to `NSWorkspace.openApplication` and to
    /// `assertDebugBundle`'s `Info.plist` lookup.
    static var appBundleURL: URL {
        // AppAccessor.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/UI/AppAccessor.swift
        // The packaged app bundle lives at:
        //   <repo>/Ducko.app/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UI
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ducko.app")
    }

    /// Path to the inner executable inside `appBundleURL`. Used only for the
    /// existence-on-disk skip predicate; `NSWorkspace.openApplication` takes
    /// the bundle URL directly.
    static var executableURL: URL {
        appBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("DuckoApp")
    }

    /// Per-test skip predicate — UI tests need a packaged `.app` on disk.
    static var appBundleExists: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Per-test skip predicate — UI tests need Accessibility trust granted.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Per-test skip predicate for the `ducko-import.sh` "app not running"
    /// assertion: true only when no DuckoApp of any provenance (installed,
    /// `swift run DuckoApp`, or a test bundle) is present. The script guards on
    /// `exists process "DuckoApp"`, so the assertion is valid only when none is
    /// running; rather than terminate a developer's instance, the test skips.
    /// Matches by process name and bundle identifier to cover bundleless
    /// `swift run` instances (no `im.ducko` identifier) as well as installed
    /// builds.
    static var noDuckoAppRunning: Bool {
        NSWorkspace.shared.runningApplications.allSatisfy { app in
            app.localizedName != "DuckoApp" && app.bundleIdentifier != "im.ducko"
        }
    }

    /// Terminates any running `Ducko.app` whose bundle URL matches the one
    /// integration tests launch, then removes any
    /// `~/Library/Application Support/Ducko-Dev-inttest-ui-*` directories
    /// (UI test profiles only — CLI test profiles use `Ducko-Dev-inttest-<UUID>`
    /// and clean themselves up in `CLIProcess.tearDown`) except the one named
    /// by `keep`. Called from `withAppAccessor` before
    /// each new harness so a crashed prior run can't leave orphan sessions
    /// on the test server.
    ///
    /// `keep` excludes the active profile from the directory sweep:
    /// `UISeededApp.withSeededApp` writes credentials to
    /// `Ducko-Dev-<profile>/credentials.json` BEFORE `withAppAccessor`
    /// runs, and an unconditional reap would wipe those creds and the app
    /// would boot to the welcome screen instead of auto-connecting.
    ///
    /// Bundle-URL match — not just bundle-identifier match — so a developer's
    /// installed-from-DMG `Ducko.app` (same `im.ducko` identifier) running
    /// in the user session is never touched.
    static func reapOrphanProcessesAndProfileDirs(keep: String? = nil) async {
        let bundleURL = appBundleURL.standardizedFileURL
        let reaped = NSRunningApplication
            .runningApplications(withBundleIdentifier: "im.ducko")
            .filter { app in
                guard let appURL = app.bundleURL?.standardizedFileURL else { return false }
                return appURL == bundleURL
            }
        for app in reaped {
            app.terminate()
        }
        // Give each reaped instance its own window to honor the unavailable-
        // presence + stream-close path before falling back to forceTerminate.
        // Per-app deadline (not shared) so a slow app #1 doesn't starve app #2
        // of its budget. The 3 s budget mirrors `AppDelegate.disconnectDeadline`.
        for app in reaped where !app.isTerminated {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !app.isTerminated, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !app.isTerminated {
                app.forceTerminate()
            }
        }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: appSupport, includingPropertiesForKeys: nil
        )) ?? []
        let keepName = keep.map { "Ducko-Dev-\($0)" }
        // Scope to UI orphans only (`inttest-ui-<UUID>`). CLI tests use the
        // `inttest-<UUID>` prefix without the `ui-` infix and clean up their
        // own profile directories in `CLIProcess.tearDown` — wiping them from
        // here would cross harness ownership and delete profiles belonging to
        // tests that happen to run concurrently in the same Swift Testing
        // process. The `keep` exception below ensures the active UI profile
        // (which already had credentials written before this reap runs) is
        // preserved across the sweep.
        for entry in entries
            where entry.lastPathComponent.hasPrefix("Ducko-Dev-inttest-ui-")
            && entry.lastPathComponent != keepName {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh `AppAccessor`, awaiting cleanup on both
    /// success and failure paths. Mirrors `CLIProcess.withProcess`.
    static func withAppAccessor<T: Sendable>(
        profile: String? = nil,
        target: LaunchTarget = .contactList,
        _ body: sending (AppAccessor) async throws -> T
    ) async throws -> T {
        let resolvedProfile = profile ?? "inttest-ui-\(UUID().uuidString.prefix(8))"
        // Pre-test reap: when a prior swift-testing process crashed (signal 6
        // / 10 / 13 — observed under multi-process load), `terminate()`
        // never ran and the spawned `Ducko.app` keeps running, holding an
        // XMPP session. After 4-5 sessions the live test server saturates
        // and subsequent runs cascade into `streamClosed` / `SIGPIPE`. Reap
        // here so a fresh harness starts from a clean slate. macOS lacks a
        // PR_SET_PDEATHSIG-equivalent that would let the spawned app
        // self-terminate when its parent dies, so explicit pre-test reap is
        // the practical option. The active profile is preserved because
        // `UISeededApp.withSeededApp` writes credentials before this point.
        await reapOrphanProcessesAndProfileDirs(keep: resolvedProfile)

        let accessor = AppAccessor(profile: resolvedProfile)
        do {
            try await accessor.launch(target: target)
            let result = try await body(accessor)
            await accessor.terminate()
            return result
        } catch {
            // Local-dev diagnostic gate: hold the failed app open for AX
            // inspection (peekaboo, Accessibility Inspector). `try?` ensures
            // swift-testing's cancel-on-timeout still reaches `terminate()`.
            // MUST NOT be set in CI.
            if ProcessInfo.processInfo.environment["DUCKO_HOLD_ON_FAILURE"] == "1" {
                try? await Task.sleep(for: .seconds(60))
            }
            await accessor.terminate()
            throw error
        }
    }

    /// Spawns the packaged app, activates it, and waits for the boot marker
    /// matching `target`. Throws and rolls back the partial spawn if the
    /// boot wait fails.
    func launch(target: LaunchTarget) async throws {
        // Register the profile-directory reap FIRST so it survives a thrown
        // precondition check below. `UISeededApp.withSeededApp` writes
        // plaintext credentials to `Ducko-Dev-<profile>/credentials.json`
        // before calling launch — if `assertDebugBundle` (or any other
        // pre-launch guard) throws, those creds would otherwise leak on
        // disk. `CLIProcess.removeProfileDirectory` is idempotent
        // (`fileNoSuchFile` is swallowed) so registering early is safe even
        // when the harness exits before any directory is created.
        let profileForCleanup = profile
        postExitCleanupActions.append {
            await CLIProcess.removeProfileDirectory(profile: profileForCleanup)
        }

        let bundleURL = Self.appBundleURL
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw TestHarnessError.appBundleMissing(path: Self.executableURL.path)
        }
        guard AXIsProcessTrusted() else {
            throw TestHarnessError.axTrustMissing
        }

        // Refuse to launch a release-built bundle. A release build ignores
        // `DUCKO_PROFILE`, persists creds in the real Keychain, and stores
        // transcripts under `~/Library/Application Support/Ducko/` — typing
        // test passwords into it would pollute the developer's production
        // app data. `Scripts/package_app.sh` writes the build configuration
        // into Info.plist's `DuckoBuildConfiguration` key (`debug` vs
        // `release`); we read it pre-launch so the gate fires before any
        // process spawns or any input is dispatched.
        try Self.assertDebugBundle(at: bundleURL)

        // Argument-domain UserDefaults override: `NSUserDefaults` reads
        // `-key value` pairs from process arguments and treats them as the
        // highest-priority domain on read. NSWindow's `setFrameAutosaveName`
        // consults `standardUserDefaults`, so this override wins on read over
        // any frame persisted in `~/Library/Preferences/im.ducko.plist` — a
        // stray developer-saved Contacts frame can't reposition the test
        // window for this launch.
        //
        // The Contacts window content-sizes itself (auto-fitting width and
        // height), so the injected size is advisory: AppKit clamps it to the
        // content. The override exists to pin a deterministic on-screen
        // origin; the size only needs to be large enough that the first paint
        // isn't clipped before auto-sizing settles.
        //
        // Each pair is two argv elements (`"-<key>"`, `"<value>"`); a
        // contributor adding a second pair must keep that one-element-per-
        // token shape, otherwise the next `-` token is consumed as the
        // previous value and silently swallowed.
        let runningApp = try await Self.openApp(
            at: bundleURL,
            environment: environment,
            arguments: ["-NSWindow Frame contacts", "0 100 720 600 0 0 2560 1410"]
        )
        process = runningApp

        // Activate Ducko so its controls can establish field-editor focus.
        await Self.activateApp(pid: runningApp.processIdentifier)

        // Bound every AX read against a hung child. The timeout is per-AX-
        // object and does not transfer to equal elements created later, so
        // we set it on the system-wide accessibility object — that establishes
        // a process-wide default that subsequent `AXUIElementCreateApplication`
        // calls inherit.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

        do {
            switch target {
            case .welcome:
                try await waitForElement(identifier: "setup-mode-picker", timeout: TestTimeout.connect)
            case .contactList:
                try await waitForElement(identifier: "contact-list", timeout: TestTimeout.connect)
            }
        } catch {
            await terminate()
            throw error
        }
    }

    /// Appends a cleanup action; actions in each phase queue run in reverse
    /// order during teardown. **In-app cleanup is best-effort**: the closure
    /// signature is non-throwing, so callers must wrap UI-driving AX calls
    /// in `try?` and never propagate errors from the cleanup body — the test
    /// body's original error is what the suite needs to surface.
    func addCleanup(_ action: @escaping @Sendable () async -> Void, phase: CleanupPhase = .inApp) {
        switch phase {
        case .inApp:
            inAppCleanupActions.append(action)
        case .postExit:
            postExitCleanupActions.append(action)
        }
    }

    /// Runs in-app cleanup, terminates the launched app, then runs post-exit
    /// cleanup. Each cleanup action is bounded by a 5-second soft deadline
    /// so a hung UI cannot block teardown.
    func terminate() async {
        for action in inAppCleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "UI in-app")
        }
        inAppCleanupActions.removeAll()

        if let app = process, !app.isTerminated {
            app.terminate()
            // 5 s gives `AppDelegate.applicationShouldTerminate` time to send
            // unavailable presence + `</stream:stream>` before forceTerminate.
            let exited = await Self.waitForRunningAppExit(app, timeout: .seconds(5))
            if !exited {
                app.forceTerminate()
                _ = await Self.waitForRunningAppExit(app, timeout: .seconds(2))
            }
        }
        process = nil

        for action in postExitCleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "UI post-exit")
        }
        postExitCleanupActions.removeAll()
    }

    // MARK: - AX queries

    /// Waits for `contact`'s row to render AND for at least one account to
    /// reach `.connected`. Use as the connectivity gate at the top of a test
    /// that needs a freshly-launched app to be live on the wire.
    ///
    /// The row alone is unsafe: `RosterService.loadContacts` reads the
    /// cached roster via `store.fetchContacts`, so the row can render before
    /// the new `XMPPClient` finishes binding. The `contact-list` element
    /// exposes `kAXValueAttribute = "connected"` only when
    /// `AccountService.connectionStates` flips to `.connected` — closing the
    /// race where a roster-driven action fires against `XMPPClient.send` while
    /// state is still `.connecting`/`.authenticating`.
    func waitForContactRow(_ contact: TestCredentials.Credential) async throws {
        try await waitForElement(identifier: "contact-row-\(contact.jid)", timeout: TestTimeout.connect)
        try await pollUntil(timeout: TestTimeout.connect) {
            do {
                return try self.axDriver.readValue(identifier: "contact-list") == "connected"
            } catch TestHarnessError.elementNotFound {
                return false
            }
        }
    }

    /// Polls the AX tree for `identifier` until it appears or the timeout
    /// elapses. Catches only `elementNotFound` inside the predicate so an
    /// `axTrustMissing` raised by `resolveElement` is not silently relabelled
    /// as a generic timeout.
    func waitForElement(identifier: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                do {
                    _ = try self.axDriver.resolveElement(identifier: identifier)
                    return true
                } catch TestHarnessError.elementNotFound {
                    return false
                }
            }
        } catch TestHarnessError.timeout {
            // Identifiers may embed JIDs (e.g. `contact-row-bob@…`) and the
            // project privacy policy bars JIDs at warning/info/notice — log at
            // debug instead so the diagnostic is available in trace mode without
            // leaking sensitive data at higher levels.
            log.debug("waitForElement timeout (\(timeout)) for identifier '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls the AX tree for an element matching `identifier`+`role` (the
    /// role-aware companion to `waitForElement(identifier:)`). Use to await a
    /// control that shares a container-propagated identifier with siblings of
    /// other roles — e.g. the room-topic `AXTextField` that materializes under
    /// `room-subject-view` only after the pencil flips the view into edit mode.
    func waitForElement(identifier: String, role: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                do {
                    _ = try self.axDriver.resolveElement(identifier: identifier, role: role)
                    return true
                } catch TestHarnessError.elementNotFound {
                    return false
                }
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForElement timeout (\(timeout)) for identifier '\(identifier)' role '\(role)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls `containsDescendant(role:withSubstring:underIdentifier:)` until
    /// it returns `true` or the timeout elapses. Use this when asserting on
    /// AX state that is updated asynchronously (message bubble after
    /// `pressReturn`, room participants after a join, etc.).
    func waitForDescendant(
        role: String,
        withSubstring substring: String,
        underIdentifier identifier: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                try await self.containsDescendant(role: role, withSubstring: substring, underIdentifier: identifier)
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForDescendant timeout (\(timeout)) role '\(role)' substring '\(substring)' under '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls until `identifier` is no longer present or the timeout elapses.
    /// Use this to assert dismissal of transient UI state like the typing
    /// indicator without accepting "still visible" as passing.
    func waitForAbsence(identifier: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                do {
                    _ = try self.axDriver.resolveElement(identifier: identifier)
                    return false
                } catch TestHarnessError.elementNotFound {
                    return true
                }
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForAbsence timeout (\(timeout)) for identifier '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    func click(identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            try self.axDriver.perform(action: kAXPressAction, on: element, identifier: identifier)
        }
    }

    /// Opens the context menu attached to `identifier`. `kAXShowMenuAction`
    /// is documented-indeterminate when it returns `.cannotComplete`
    /// (per Apple's `AXUIElementPerformAction` docs), so we never retry on a
    /// non-success return — the action may have actually opened the menu,
    /// and a retry posted on top of an open menu either no-ops or closes
    /// the menu before the caller can pick an item. Instead we poll for
    /// `kAXMenuRole` to publish under the application; if the menu does
    /// appear, the action committed regardless of return code.
    func rightClick(identifier: String) async throws {
        // Retry the whole resolve → show-menu → wait sequence: a presence or
        // roster re-render can invalidate the row's AX element either before
        // the resolve or between the resolve and `kAXShowMenuAction` (the row
        // re-mounts mid-gesture, so the action lands on a stale element and no
        // menu appears). Re-posting is safe here because each retry only runs
        // after the wait below found NO menu — there's nothing open to close.
        try await retryOnStaleElement(identifier: identifier, maxAttempts: 4) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            let err = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            if err == .apiDisabled { throw TestHarnessError.axTrustMissing }
            do {
                _ = try await self.waitForShownContextMenu(timeout: .seconds(3))
            } catch TestHarnessError.elementNotFound, TestHarnessError.timeout {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
        }
    }

    /// Opens the context menu attached to the table row for the occupant whose
    /// displayed text contains `substring`. The right-click analogue of
    /// `rightClick(identifier:)` for rows that carry no `accessibilityIdentifier`
    /// of their own (e.g. participant-sidebar occupant rows, whose only stable
    /// handle is the displayed nickname).
    ///
    /// Unlike `rightClick(identifier:)`, which posts `kAXShowMenuAction`, this
    /// synthesizes a real secondary-button `CGEvent` at the row center: a
    /// SwiftUI `List` row's `.contextMenu` does not respond to `kAXShowMenuAction`
    /// (verified — the action returns but no `kAXMenuRole` publishes), whereas
    /// the AppKit contact-list table does. After the click it polls for the
    /// menu, retrying the whole find-and-click on a transient re-render.
    ///
    /// `roles` is the candidate set for the enclosing row element: a SwiftUI
    /// `List` row surfaces as `kAXRowRole`/`kAXCellRole` (NSTableView-backed) or
    /// `kAXGroupRole`. The row is found by locating the nickname text and walking
    /// up (see `findMenuRow`), since the identifier's propagation onto inner
    /// content leaves the row as an ancestor of the resolved container.
    func rightClickDescendant(
        roles: [String],
        withSubstring substring: String,
        underIdentifier identifier: String
    ) async throws {
        let rowID = "\(identifier)/row[\(substring)]"
        try await retryOnStaleElement(identifier: identifier, maxAttempts: 4) {
            let container = try self.axDriver.resolveElement(identifier: identifier)
            guard let row = self.axDriver.findMenuRow(ofTextContaining: substring, in: container, roles: roles) else {
                throw TestHarnessError.elementNotFound(identifier: rowID)
            }
            // Click the nickname text's center, not the row center: the row can
            // include empty area outside the SwiftUI interaction shape.
            let text = self.axDriver.findDescendant(in: container, role: kAXStaticTextRole, where: { element in
                self.axDriver.elementText(of: element)?.contains(substring) ?? false
            })
            guard let point = (text.flatMap { self.axDriver.elementCenter(of: $0) }) ?? self.axDriver.elementCenter(of: row) else {
                throw TestHarnessError.elementNotFound(identifier: rowID)
            }
            // Raise the row's window above any occluding sibling (e.g. the pinned
            // Contacts window) so the synthetic click hit-tests into it.
            self.axDriver.raiseWindow(of: row)
            await self.ensureFrontmost()
            guard self.axDriver.pointHitsSameWindow(as: row, at: point) else {
                throw TestHarnessError.elementNotFound(identifier: "\(rowID)/occluded")
            }
            do {
                try await self.openContextMenu(at: point, identifier: rowID)
            } catch TestHarnessError.elementNotFound, TestHarnessError.timeout {
                throw TestHarnessError.elementNotFound(identifier: rowID)
            }
        }
    }

    /// Synthesizes a SwiftUI-style double-click via two `CGEvent` click
    /// pairs at the element center. Two consecutive `kAXPressAction`s do
    /// NOT synthesize `.onTapGesture(count: 2)`, so this is the only path
    /// that wakes up double-tap recognizers like `ContactRow`. Retries on
    /// transient `elementNotFound` for the same reason as `click` and
    /// `rightClick` — the row's AX hierarchy can re-mount when presence
    /// updates land between `waitForElement` and the action.
    func doubleClick(identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            guard let pid = self.process?.processIdentifier else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            await Self.activateApp(pid: pid)

            guard let center = self.axDriver.elementCenter(of: element) else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            for clickState in [Int64(1), Int64(2)] {
                self.axDriver.postClickPair(at: center, clickState: clickState)
            }
        }
    }

    /// Selects the table row containing `identifier` with a real single click,
    /// then waits for its `kAXRowRole` ancestor to report selected.
    /// `click(identifier:)` performs `kAXPressAction`, which does not change
    /// `NSTableView` selection.
    func selectRow(identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            self.axDriver.raiseWindow(of: element)
            await self.ensureFrontmost()
            guard let point = self.axDriver.elementCenter(of: element), self.axDriver.pointHitsSameWindow(as: element, at: point) else {
                throw TestHarnessError.elementNotFound(identifier: "\(identifier)/occluded")
            }
            self.axDriver.postClickPair(at: point, clickState: 1)
        }
        try await pollUntil(timeout: TestTimeout.uiElement) {
            guard let element = try? self.axDriver.resolveElement(identifier: identifier),
                  let row = self.axDriver.findAncestor(from: element, role: kAXRowRole) else { return false }
            return (self.axDriver.readAttribute(row, kAXSelectedAttribute) as? Bool) == true
        }
    }

    /// Resolves `identifier`, focuses it, and either sets `kAXValueAttribute`
    /// or falls back to per-character keystrokes via `mapSetterError`. The
    /// fallback covers SwiftUI `TextField`s that ignore `kAXSetValueAction`.
    func type(_ text: String, intoIdentifier identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            Self.setFocused(element, identifier: identifier)
            switch Self.mapSetterError(
                AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString),
                identifier: identifier
            ) {
            case .done:
                return
            case let .error(error):
                throw error
            case .needsFallback:
                break
            }
            await self.ensureFrontmost()
            try self.typeFocusedText(text, clearFirst: false)
        }
    }

    /// Focuses `identifier` and synthesizes a hardware Return keystroke.
    /// `kAXConfirmAction` is not used because SwiftUI's `.onKeyPress(.return)`
    /// handlers only fire on real keystroke events.
    func pressReturn(intoIdentifier identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier)
            Self.setFocused(element, identifier: identifier)
            try await self.pressKey(CGKeyCode(kVK_Return), modifiers: [])
        }
    }

    /// Clears `identifier`'s current contents, types `text` (via `replaceText`),
    /// then waits for the field's `kAXValue` to reconcile. Use when the test
    /// must both replace content and prove the SwiftUI binding committed — e.g.
    /// the message field pre-populated after the Edit context-menu pick, where a
    /// stale `@State` binding would make a follow-up `pressReturn` send the
    /// pre-edit body. This is `replaceText` plus the value-reconcile assertion;
    /// for fields whose typed text never surfaces via `kAXValue` (the borderless
    /// search field), call `replaceText` directly and assert on behavior.
    func clearAndType(_ text: String, intoIdentifier identifier: String) async throws {
        try await replaceText(text, intoIdentifier: identifier)
        // Event delivery is asynchronous; under suite load
        // the AppKit field editor's `controlTextDidChange` pipeline can land
        // the typed replacement into SwiftUI's bound `@State` *after* a
        // follow-up `pressReturn` reads `.onKeyPress(.return)` from the
        // stale binding, so the test sends a no-op correction with the
        // pre-edit body. Polling for AX value equality proves the binding
        // committed before this helper returns.
        try await waitForValue(text, identifier: identifier)
    }

    /// Clears `identifier` and types `text` via hardware-style keystrokes, like
    /// `clearAndType`, but WITHOUT asserting the field's `kAXValue` reconciles.
    /// Use for SwiftUI `TextField`s whose typed text isn't surfaced via
    /// `kAXValueAttribute` at once: the `@State` binding still commits, so
    /// assert on the resulting behavior (rows appearing/disappearing) or poll
    /// the value with `waitForValue`.
    func replaceText(_ text: String, intoIdentifier identifier: String) async throws {
        await ensureFrontmost()
        try Self.setFocused(axDriver.resolveElement(identifier: identifier), identifier: identifier)
        try await pollUntil(timeout: TestTimeout.uiElement) {
            guard let pid = self.process?.processIdentifier,
                  let target = try? self.axDriver.resolveElement(identifier: identifier) else { return false }
            var focused: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused
            )
            return result == .success && focused.map { CFEqual($0, target) } == true
        }
        try typeFocusedText(text, clearFirst: true)
    }

    private func typeFocusedText(_ text: String, clearFirst: Bool) throws {
        if clearFirst {
            try postKey(CGKeyCode(kVK_ANSI_A), modifiers: .maskCommand)
            usleep(50000)
            try postKey(CGKeyCode(kVK_Delete), modifiers: [])
        }
        for character in text {
            try postKey(0, modifiers: [], text: String(character))
            // Preserve pacing so the field editor consumes each Unicode event.
            usleep(10000)
        }
    }

    /// Activates the app and returns whether it is frontmost afterwards.
    func bringToFront() async -> Bool {
        await ensureFrontmost()
        return isFrontmost()
    }

    func isFrontmost() -> Bool {
        guard let pid = process?.processIdentifier else { return false }
        return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }

    /// Brings the window holding `identifier` to the front and makes it the
    /// app's main window, as the user going to it does.
    func raiseWindow(containing identifier: String) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            try self.axDriver.raiseWindow(of: self.axDriver.resolveElement(identifier: identifier))
        }
        await ensureFrontmost()
    }

    /// The titles of the app's windows. Unlike the element helpers, which raise
    /// and focus what they act on, it only reads, so a test can assert that
    /// something the app did on its own left the keyboard where it was.
    func windowTitles() -> [String] {
        guard let pid = process?.processIdentifier else { return [] }
        let windows = axDriver.readAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { axDriver.readAttribute($0, kAXTitleAttribute) as? String }
    }

    /// Waits until the app has `count` windows. Only reads, like
    /// `windowTitles()`.
    func waitForWindowCount(_ count: Int, timeout: Duration) async throws {
        try await pollUntil(timeout: timeout) { self.windowTitles().count == count }
    }

    /// The title of the window that has the keyboard. Only reads, like
    /// `windowTitles()`.
    func focusedWindowTitle() -> String? {
        guard let pid = process?.processIdentifier,
              let window = axDriver.elementAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        return axDriver.readAttribute(window, kAXTitleAttribute) as? String
    }

    /// Whether `identifier` is the element that has the keyboard. Only reads,
    /// like `windowTitles()`.
    func hasKeyboardFocus(identifier: String) -> Bool {
        guard let pid = process?.processIdentifier else { return false }
        var element = axDriver.elementAttribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        // The element with the keyboard can be the field's editor, a level or two below the element that carries the
        // identifier.
        for _ in 0 ..< 4 {
            guard let current = element else { return false }
            if axDriver.readAttribute(current, kAXIdentifierAttribute) as? String == identifier { return true }
            element = axDriver.parentElement(of: current)
        }
        return false
    }

    /// Resolves `identifier` and reads `kAXValueAttribute` (falling back to
    /// `kAXTitleAttribute`). Retries via `retryOnStaleElement` so a SwiftUI
    /// re-render between `waitForElement` and the read does not surface as a
    /// test failure — the underlying `AXUIElement` reference becomes stale
    /// across the re-render and only a fresh `resolveElement` recovers it.
    func value(identifier: String) async throws -> String? {
        try await retryOnStaleElement(identifier: identifier) {
            try self.axDriver.readValue(identifier: identifier)
        }
    }

    /// Walks `identifier`'s subtree for an element of `role` whose value or
    /// title contains `substring`. Returns `true` on first match.
    func containsDescendant(
        role: String,
        withSubstring substring: String,
        underIdentifier identifier: String
    ) async throws -> Bool {
        try await retryOnStaleElement(identifier: identifier) {
            let container = try self.axDriver.resolveElement(identifier: identifier)
            let match = self.axDriver.findDescendant(in: container, role: role) { element in
                self.axDriver.elementText(of: element)?.contains(substring) ?? false
            }
            return match != nil
        }
    }

    /// Resolves `identifier` as a segmented picker / button group and clicks
    /// the segment whose label matches `title`. Reads `kAXTitleAttribute`
    /// first and falls back to `kAXDescriptionAttribute` — SwiftUI's
    /// `Picker(.segmented)` on macOS 26 publishes the segment label only via
    /// the description attribute, with title returning `missing value`.
    func clickSegment(title: String, identifier: String) async throws {
        // Full-body wrap: `retryOnStaleElement` rethrows the most recently
        // caught `elementNotFound`, so the qualified
        // `"\(identifier)/segment[\(title)]"` thrown by the inner predicate
        // (or by `perform` on `.invalidUIElement`) survives exhaustion.
        try await retryOnStaleElement(identifier: identifier) {
            let picker = try self.axDriver.resolveElement(identifier: identifier)
            let match = self.axDriver.findDescendant(
                in: picker,
                roles: [kAXRadioButtonRole, kAXButtonRole],
                where: { candidate in self.axDriver.segmentLabel(of: candidate) == title }
            )
            guard let segment = match else {
                throw TestHarnessError.elementNotFound(identifier: "\(identifier)/segment[\(title)]")
            }
            try self.axDriver.perform(action: kAXPressAction, on: segment, identifier: "\(identifier)/segment[\(title)]")
        }
    }

    /// Resolves `identifier`, normalizes to the nearest `kAXTabGroupRole`
    /// element, and presses the tab whose label matches `title`. NSTabView
    /// exposes its tab buttons via the dedicated `kAXTabsAttribute` rather
    /// than `kAXChildrenAttribute`, so the tabs are not reachable via the
    /// recursive descendant walker that powers the rest of the harness.
    /// SwiftUI's `.accessibilityIdentifier` on a `TabView` may also attach
    /// to the focused content pane rather than the kAXTabGroupRole parent;
    /// the ancestor walk handles that case.
    ///
    /// Falls back to a window-toolbar button traversal when no tab group is
    /// reachable. SwiftUI `Settings { TabView { ... } }` renders tabs into
    /// the window's `NSToolbar` (siblings of the content `AXGroup`) rather
    /// than as `NSTabView`, so no `kAXTabGroupRole` exists — the toolbar
    /// fallback locates the tab button by label there.
    func clickTab(title: String, identifier: String) async throws {
        // Full-body wrap: `retryOnStaleElement` rethrows the most recently
        // caught `elementNotFound`, so the qualified
        // `"\(identifier)/tab[\(title)]"` thrown by the inner branches (and
        // by `perform` on `.invalidUIElement`) survives exhaustion.
        try await retryOnStaleElement(identifier: identifier) {
            let resolved = try self.axDriver.resolveElement(identifier: identifier)
            let tabGroup = self.axDriver.elementRole(of: resolved) == kAXTabGroupRole
                ? resolved
                : self.axDriver.findDescendant(in: resolved, role: kAXTabGroupRole, where: { _ in true })
                ?? self.axDriver.findAncestor(from: resolved, role: kAXTabGroupRole)
            if let tabGroup {
                var tabsValue: AnyObject?
                let err = AXUIElementCopyAttributeValue(tabGroup, kAXTabsAttribute as CFString, &tabsValue)
                if err == .success,
                   let tabs = tabsValue as? [AXUIElement],
                   let tab = tabs.first(where: { self.axDriver.segmentLabel(of: $0) == title }) {
                    try self.axDriver.perform(action: kAXPressAction, on: tab, identifier: "\(identifier)/tab[\(title)]")
                    return
                }
            }
            if let window = self.axDriver.findAncestor(from: resolved, role: kAXWindowRole),
               let toolbar = self.axDriver.findDescendant(in: window, role: kAXToolbarRole, where: { _ in true }),
               let tabButton = self.axDriver.findDescendant(
                   in: toolbar,
                   roles: [kAXRadioButtonRole, kAXButtonRole],
                   where: { self.axDriver.segmentLabel(of: $0) == title }
               ) {
                try self.axDriver.perform(action: kAXPressAction, on: tabButton, identifier: "\(identifier)/tab[\(title)]")
                return
            }
            throw TestHarnessError.elementNotFound(identifier: "\(identifier)/tab[\(title)]")
        }
    }

    func clickMenuItem(title: String) async throws {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: "menu-item[\(title)]")
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let menuItem = axDriver.findMenuItem(in: appElement, title: title) else {
            throw TestHarnessError.elementNotFound(identifier: "menu-item[\(title)]")
        }
        try axDriver.perform(action: kAXPressAction, on: menuItem, identifier: "menu-item[\(title)]")
    }

    /// Selects a menu item inside an NSPopUpButton-backed control (e.g.
    /// SwiftUI `Picker(.menu)`) by title and commits the popup's selection.
    ///
    /// Distinct from `clickMenuItem(title:)`: that helper is for menu-bar /
    /// context-menu items reachable from the application AX root and uses
    /// `kAXPressAction` (press semantics, `NSAccessibility.Action.press`).
    /// Popup pickers need `kAXPickAction` (pick semantics,
    /// `NSAccessibility.Action.pick` / `accessibilityPerformPick()`) — pressing
    /// a menu item inside a popup highlights/expands it without committing the
    /// popup's value on macOS 26, leaving the SwiftUI `Binding(set:)` setter
    /// unfired and `kAXValueAttribute` stale.
    ///
    /// Per Apple's `AXUIElementPerformAction` docs, `kAXErrorCannotComplete`
    /// during modal callbacks (which menu tracking is) does NOT necessarily
    /// indicate failure — the action may have taken effect anyway. So we poll
    /// for the menu becoming visible after `kAXShowMenuAction`, and for the
    /// popup value reconciling after `kAXPickAction`, before falling back to
    /// alternative input synthesis.
    func pickPopUpItem(title: String, identifier: String) async throws {
        let popUp = try axDriver.resolveElement(identifier: identifier)
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }

        // Open the menu — show-menu first; press fallback only if the menu
        // doesn't appear (covers controls that don't expose show-menu and the
        // documented-indeterminate `cannotComplete` case where show-menu may
        // have actually opened the menu). Use a short poll for the
        // speculative show-menu probe (in practice menus publish in 100ms or
        // not at all) so the press fallback isn't held up for the full UI
        // timeout when show-menu silently no-ops.
        let showErr = AXUIElementPerformAction(popUp, kAXShowMenuAction as CFString)
        if showErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
        do {
            try await waitForShownMenu(on: popUp, identifier: identifier, timeout: .milliseconds(500))
        } catch TestHarnessError.timeout {
            try axDriver.perform(action: kAXPressAction, on: popUp, identifier: identifier)
            try await waitForShownMenu(on: popUp, identifier: identifier)
        }

        // Once the menu is open, an error escaping this function would leave
        // it open and eating events for subsequent helpers. Track commit state
        // and post Escape on the failure path. The committed state is
        // determined by the popup's value matching `title`, not by the AX
        // action's return code, because `cannotComplete` is indeterminate.
        var commitAttempted = false
        do {
            let menu = try axDriver.resolveShownMenu(for: popUp, identifier: identifier)
            guard let item = axDriver.findMenuItem(in: menu, title: title) else {
                throw TestHarnessError.elementNotFound(identifier: "\(identifier)/menu-item[\(title)]")
            }

            // kAXPickAction is the canonical "select this menu item" action.
            // Always poll the popup value afterward — `cannotComplete` may
            // have committed the pick anyway; fall back to a synthesized
            // CGEvent click pair only if the value never reconciles.
            let pickErr = AXUIElementPerformAction(item, kAXPickAction as CFString)
            if pickErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
            do {
                try await waitForValue(title, identifier: identifier)
                commitAttempted = true
            } catch TestHarnessError.timeout {
                guard let center = axDriver.elementCenter(of: item) else {
                    throw TestHarnessError.elementNotFound(identifier: "\(identifier)/menu-item[\(title)]")
                }
                axDriver.postClickPair(at: center, clickState: 1)
                commitAttempted = true
                do {
                    try await waitForValue(title, identifier: identifier)
                } catch TestHarnessError.timeout {
                    log.debug("pickPopUpItem timeout (\(TestTimeout.uiElement)) for identifier '\(identifier)' title '\(title)'")
                    throw TestHarnessError.timeout
                }
            }
        } catch {
            if !commitAttempted {
                try? await pressKey(CGKeyCode(kVK_Escape), modifiers: [])
            }
            throw error
        }
    }

    /// Opens the SwiftUI `Menu` (pull-down) identified by `identifier` and
    /// presses the item titled `title`. Unlike `pickPopUpItem`, it does not
    /// wait for a popup value to reconcile — use it for items that fire an
    /// action (e.g. open a sheet) rather than commit a `Picker` selection.
    /// Posts Escape and throws if the item is missing so an orphaned open
    /// menu can't poison later helpers.
    func pressMenuItem(title: String, identifier: String) async throws {
        let menu = try await showMenu(identifier: identifier)
        let itemIdentifier = "\(identifier)/menu-item[\(title)]"
        guard let item = axDriver.findMenuItem(in: menu, title: title) else {
            try? await pressKey(CGKeyCode(kVK_Escape), modifiers: [])
            throw TestHarnessError.elementNotFound(identifier: itemIdentifier)
        }
        if let error = Self.classifyContextMenuPressPick(
            press: AXUIElementPerformAction(item, kAXPressAction as CFString),
            pick: AXUIElementPerformAction(item, kAXPickAction as CFString),
            identifier: itemIdentifier
        ) {
            throw error
        }
    }

    /// Opens the pull-down `identifier`, reads its item titles in menu order
    /// without pressing any, then closes it with Escape. A separator reads as
    /// an empty title. Use it to pin items that must not be pressed, such as
    /// a destructive one.
    func menuItemTitles(identifier: String) async throws -> [String] {
        let menu = try await showMenu(identifier: identifier)
        let items = (axDriver.readAttribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let titles = items.map { (axDriver.readAttribute($0, kAXTitleAttribute) as? String) ?? "" }
        try await pressKey(CGKeyCode(kVK_Escape), modifiers: [])
        try await waitForContextMenuDismissed()
        return titles
    }

    private func showMenu(identifier: String) async throws -> AXUIElement {
        let menuButton = try axDriver.resolveElement(identifier: identifier)
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }
        // `AXShowMenu` reports success without opening the menu on a control that
        // does not advertise it, such as a `Menu` hosted in a grouped `Form`.
        var actionNames: CFArray?
        AXUIElementCopyActionNames(menuButton, &actionNames)
        let openAction = ((actionNames as? [String]) ?? []).contains(kAXShowMenuAction) ? kAXShowMenuAction : kAXPressAction
        let showErr = AXUIElementPerformAction(menuButton, openAction as CFString)
        if showErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
        try await waitForShownMenu(on: menuButton, identifier: identifier)
        return try axDriver.resolveShownMenu(for: menuButton, identifier: identifier)
    }

    /// Sends a key-down/up pair only to the owned app process.
    func pressKey(_ key: CGKeyCode, modifiers: CGEventFlags) async throws {
        await ensureFrontmost()
        try postKey(key, modifiers: modifiers)
    }

    func runRosterNoticeScript(target: String) async throws -> Int32 {
        guard let pid = process?.processIdentifier else { throw TestHarnessError.elementNotFound(identifier: "app") }
        let script = Self.appBundleURL.deletingLastPathComponent().appending(path: "Skills/ducko-ui/scripts/ducko-dismiss-roster-notice.sh")
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/bash")
        command.arguments = [script.path, target]
        command.environment = environment.merging(["DUCKO_PID": String(pid)]) { _, value in value }
        try command.run()
        let deadline = ContinuousClock.now + .seconds(10)
        while command.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if command.isRunning { command.terminate() }
        command.waitUntilExit()
        return command.terminationStatus
    }

    /// Selects an item by title in the currently-shown context menu (the
    /// right-click menu opened by `rightClick(identifier:)`). Polls for the
    /// menu to publish and to dismiss so a follow-up action does not race
    /// the menu's open/close animation.
    ///
    /// Identifier-based selection (the prior helper) was removed because
    /// SwiftUI's `.accessibilityIdentifier` modifier on a `Button` inside a
    /// `.contextMenu` builder does not reliably propagate to the bridged
    /// `kAXMenuItemRole` element on macOS 26 — the global DFS lookup landed
    /// on a sibling and `kAXPressAction` fired the wrong action (e.g. asking
    /// for "edit-message-menu-item" actually invoked Retract). Title is the
    /// stable AX attribute on menu items; `kAXPressAction` is the canonical
    /// action (the bridged `NSMenuItem` action handler), with `kAXPickAction`
    /// as a documented fallback for AX implementations that reject press on
    /// context-menu items. This is the inverse of `pickPopUpItem`'s pick-only
    /// shape — `Picker(.menu)` controls answer to pick; context-menu items
    /// answer to press.
    func contextMenuItem(title: String) async throws {
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }

        let menu = try await waitForShownContextMenu()
        let identifier = "context-menu/menu-item[\(title)]"

        guard let menuItem = axDriver.findMenuItem(in: menu, title: title) else {
            try? await pressKey(CGKeyCode(kVK_Escape), modifiers: [])
            throw TestHarnessError.elementNotFound(identifier: identifier)
        }

        // SwiftUI `Button` inside `.contextMenu { }` bridges to a
        // `kAXMenuItemRole` whose action closure is dispatched on
        // `kAXPressAction` (the canonical NSMenuItem action). `kAXPickAction`
        // returns `.success` and visually dismisses the menu on macOS 26
        // *without* invoking the SwiftUI closure — confirmed empirically
        // (the test rendering observed the original body, not the edited
        // one, and a held-on-failure session showed the menu still open).
        // Press is therefore the canonical action here, with pick as the
        // documented fallback for AX implementations that reject press.
        //
        // Press is tentative: `.cannotComplete` during modal menu tracking
        // is documented-indeterminate, so non-success flows through to the
        // pick fallback rather than throwing. Only `.apiDisabled` is fatal
        // on the press path. The FINAL pick failure is classified through
        // `mapPerformError` so a genuine action-execution failure surfaces
        // as `axActionFailed` carrying the raw AX code, not a synthetic
        // `elementNotFound`. Menu dismissal is polled afterward to confirm
        // the action committed.
        let pressErr = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        if let error = Self.classifyContextMenuPressPick(
            press: pressErr,
            pick: AXUIElementPerformAction(menuItem, kAXPickAction as CFString),
            identifier: identifier
        ) {
            throw error
        }

        try await waitForContextMenuDismissed()
    }

    /// Clicks a button by visible label inside the application's topmost
    /// sheet. Use when SwiftUI's `.accessibilityIdentifier` does not
    /// propagate to a `Button` that also carries `.keyboardShortcut(.defaultAction)`
    /// or `.keyboardShortcut(.cancelAction)` — the bridged AX button instead
    /// inherits the *outer* container's identifier (e.g. both Save and
    /// Destroy under a VStack tagged `room-settings-view` come through with
    /// `id='room-settings-view'`), so a global identifier-based DFS lands
    /// on a sibling at best. The button's `kAXTitleAttribute` is also empty
    /// for SwiftUI `Button("Save") { … }`; the human-readable label is
    /// published via `kAXDescriptionAttribute`. The same title-then-description
    /// fallback shape powers `axDriver.segmentLabel(of:)`.
    ///
    /// Sheet scoping is intentional: a `Save` label in the sheet must not
    /// be confused with an unrelated `Save` label elsewhere in the app, and
    /// limits the walk to the active modal's surface.
    func clickSheetButton(label: String) async throws {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: "sheet-button[\(label)]")
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let sheet = axDriver.findDescendant(in: appElement, role: kAXSheetRole, where: { _ in true }) else {
            throw TestHarnessError.elementNotFound(identifier: "sheet[\(label)]")
        }
        guard let button = axDriver.findDescendant(
            in: sheet,
            role: kAXButtonRole,
            where: { candidate in axDriver.segmentLabel(of: candidate) == label }
        ) else {
            throw TestHarnessError.elementNotFound(identifier: "sheet-button[\(label)]")
        }
        try axDriver.perform(action: kAXPressAction, on: button, identifier: "sheet-button[\(label)]")
    }

    /// Polls until the application has no `kAXSheetRole` descendant. Use
    /// after `clickSheetButton` to confirm the sheet actually dismissed
    /// before issuing follow-up commands against the parent window — the
    /// press is asynchronous and the sheet's animation can race a follow-up
    /// `activateWindow`.
    func waitForSheetDismissed(timeout: Duration = TestTimeout.uiElement) async throws {
        try await pollUntilApplicationDescendantAbsent(timeout: timeout) { app in
            axDriver.findDescendant(in: app, role: kAXSheetRole, where: { _ in true })
        }
    }

    /// Selects the `List(selection:)` row under `identifier` whose descendant
    /// static text contains `substring`. The rows carry no
    /// `accessibilityIdentifier` (the account list renders plain
    /// `Text(displayName ?? jid)`), so the displayed JID/name is the only stable
    /// handle.
    ///
    /// Tries `kAXPressAction` first — when supported it follows the AppKit
    /// activation path that drives SwiftUI's `selection` binding. On macOS 26 a
    /// SwiftUI `List` row bridges to an NSTableView-backed `AXRow` that answers
    /// `kAXErrorActionUnsupported` to press, so this falls back to setting
    /// `kAXSelectedAttribute` (the NSTableView AX selection path that the
    /// `selection` binding observes). Callers still confirm selection via an
    /// observable downstream signal (the detail pane rendering) rather than this
    /// helper's return.
    func selectListRow(containingSubstring substring: String, underIdentifier identifier: String) async throws {
        let rowID = "\(identifier)/row[\(substring)]"
        try await retryOnStaleElement(identifier: identifier) {
            let container = try self.axDriver.resolveElement(identifier: identifier)
            guard let row = self.axDriver.findDescendantRow(
                in: container,
                roles: [kAXRowRole, kAXCellRole],
                containingSubstring: substring
            ) else {
                throw TestHarnessError.elementNotFound(identifier: rowID)
            }
            let pressErr = AXUIElementPerformAction(row, kAXPressAction as CFString)
            if pressErr == .success { return }
            if pressErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
            if pressErr == .invalidUIElement {
                // Stale handle between resolve and act — retriable.
                throw TestHarnessError.elementNotFound(identifier: rowID)
            }
            var settable: DarwinBoolean = false
            let settableErr = AXUIElementIsAttributeSettable(row, kAXSelectedAttribute as CFString, &settable)
            guard settableErr == .success, settable.boolValue else {
                throw TestHarnessError.axActionFailed(
                    identifier: rowID,
                    action: kAXSelectedAttribute,
                    axError: pressErr.rawValue
                )
            }
            let setErr = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            if let error = Self.mapPerformError(setErr, identifier: rowID, action: kAXSelectedAttribute) {
                throw error
            }
        }
    }

    /// Reports whether a `kAXButtonRole` descendant under `identifier` carries
    /// the visible `label`. Distinct from `containsDescendant`, which reads
    /// `kAXValue`→`kAXTitle` only: a SwiftUI `Button("…")` publishes its label
    /// via `kAXDescription` (the same reason `clickSheetButton`/`clickSegment`
    /// route through `segmentLabel`), so a presence check matching on label must
    /// go through the title-then-description lookup. `label` is matched exactly,
    /// so callers pass the published label verbatim, including any trailing
    /// ASCII `...`.
    func hasDescendantButton(label: String, underIdentifier identifier: String) async throws -> Bool {
        try await retryOnStaleElement(identifier: identifier) {
            let container = try self.axDriver.resolveElement(identifier: identifier)
            return self.axDriver.findDescendant(in: container, role: kAXButtonRole, where: { self.axDriver.segmentLabel(of: $0) == label }) != nil
        }
    }

    /// Polls `hasDescendantButton` until the labeled button appears or the
    /// timeout elapses. The description-aware companion to `waitForDescendant`,
    /// for buttons whose label only surfaces via `kAXDescription`.
    func waitForDescendantButton(
        label: String,
        underIdentifier identifier: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                try await self.hasDescendantButton(label: label, underIdentifier: identifier)
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForDescendantButton timeout (\(timeout)) label '\(label)' under '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls until a `kAXButtonRole` element labeled `label` appears in any of
    /// the application's windows. Use to await a SwiftUI `.alert`/dialog whose
    /// inner controls' `accessibilityIdentifier`s do not bridge to AX (the
    /// button's title does), e.g. the Change Nickname alert.
    func waitForWindowButton(label: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                self.axDriver.findButtonInWindows(where: { self.axDriver.segmentLabel(of: $0) == label }) != nil
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForWindowButton timeout (\(timeout)) for label '\(label)'")
            throw TestHarnessError.timeout
        }
    }

    /// Types `text` into the application's currently AX-focused element via
    /// PID-targeted keystrokes. Use for an auto-focusing control that can't be
    /// resolved/clicked by identifier — e.g. the SwiftUI `.alert` TextField
    /// (focused with its text selected; `clearFirst: true` replaces it) or the
    /// room-subject `TextField` once it auto-focuses via `@FocusState` (empty in
    /// edit mode, so `clearFirst: false` avoids a delete-on-empty beep).
    func typeIntoFocusedElement(_ text: String, clearFirst: Bool = true) async throws {
        await ensureFrontmost()
        try typeFocusedText(text, clearFirst: clearFirst)
    }

    /// Clicks a button by visible `label`, scoping the descendant search to
    /// `identifier`'s subtree, or to the application's windows when `identifier`
    /// is nil. Like `clickSheetButton`, it matches the SwiftUI button label via
    /// `segmentLabel` (title→description), but the targets here are NOT under a
    /// `kAXSheetRole`: the room-subject Save/Cancel are inline chat-window
    /// buttons, and a `.confirmationDialog`'s destructive button renders outside
    /// the presenting sheet — `ducko-destroy-room.sh` walks all process windows
    /// for the latter, which the nil-`identifier` window walk mirrors. `label`
    /// is matched exactly, including any trailing ASCII `...`.
    func clickDescendantButton(label: String, underIdentifier identifier: String? = nil) async throws {
        let scope = identifier ?? "application"
        let buttonID = "\(scope)/button[\(label)]"
        try await retryOnStaleElement(identifier: scope) {
            let button: AXUIElement?
            if let identifier {
                let container = try self.axDriver.resolveElement(identifier: identifier)
                button = self.axDriver.findDescendant(in: container, role: kAXButtonRole, where: { self.axDriver.segmentLabel(of: $0) == label })
            } else {
                button = self.axDriver.findButtonInWindows(where: { self.axDriver.segmentLabel(of: $0) == label })
            }
            guard let button else {
                throw TestHarnessError.elementNotFound(identifier: buttonID)
            }
            try self.axDriver.perform(action: kAXPressAction, on: button, identifier: buttonID)
        }
    }

    /// Presses the `buttonLabel` action inside the SwiftUI `.confirmationDialog`
    /// whose body contains `dialogText`, then waits for that dialog to dismiss.
    /// Scoping to the dialog text (rather than a global "first button labeled
    /// Destroy") avoids matching an unrelated button, and `.confirmationDialog`
    /// can bridge its actions as either `kAXButtonRole` or `kAXMenuItemRole`, so
    /// both are tried with the appropriate press/pick. Dialog dismissal is the
    /// local proof the action fired — distinct from any downstream/server effect.
    func clickConfirmationDialogButton(dialogText: String, buttonLabel: String) async throws {
        let identifier = "confirmation-dialog[\(dialogText)]/button[\(buttonLabel)]"
        let action = try await pollForApplicationDescendantPresent(timeout: TestTimeout.uiElement, identifier: identifier) { app in
            self.axDriver.findDialogAction(in: app, dialogText: dialogText, buttonLabel: buttonLabel)
        }
        if axDriver.elementRole(of: action) == kAXMenuItemRole {
            if let error = Self.classifyContextMenuPressPick(
                press: AXUIElementPerformAction(action, kAXPressAction as CFString),
                pick: AXUIElementPerformAction(action, kAXPickAction as CFString),
                identifier: identifier
            ) {
                throw error
            }
        } else if let pressError = Self.mapPerformError(AXUIElementPerformAction(action, kAXPressAction as CFString), identifier: identifier, action: kAXPressAction) {
            // The action can dismiss the dialog while the press is still in
            // flight, so AX reports an error for an action that committed.
            // Dismissal decides.
            do {
                try await waitForConfirmationDialogDismissed(dialogText: dialogText)
            } catch {
                throw pressError
            }
            return
        }
        try await waitForConfirmationDialogDismissed(dialogText: dialogText)
    }

    /// Presses the element resolved by `identifier`+`role` (+ optional `label`).
    /// Use when a control carries an identifier propagated from a SwiftUI
    /// container onto its leaves — e.g. the room-subject pencil
    /// (`identifier: "room-subject-view", role: AXButton`, no label, the only
    /// button with that identifier when not editing) and the inline Save
    /// (`label: "Save"`, distinguishing it from Cancel in edit mode).
    func clickElement(identifier: String, role: String, label: String? = nil) async throws {
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier, role: role, label: label)
            let qualifier = label.map { "\(identifier)[\(role):\($0)]" } ?? "\(identifier)[\(role)]"
            try self.axDriver.perform(action: kAXPressAction, on: element, identifier: qualifier)
        }
    }

    /// Clicks the role-qualified field before typing without re-activation.
    /// Room-topic edits need this path because AX value changes do not commit
    /// the binding read by Save, and re-activation can restore composer focus.
    func focusAndTypeElement(_ text: String, identifier: String, role: String) async throws {
        let qualifier = "\(identifier)[\(role)]"
        try await retryOnStaleElement(identifier: identifier) {
            let element = try self.axDriver.resolveElement(identifier: identifier, role: role)
            self.axDriver.raiseWindow(of: element)
            await self.ensureFrontmost()
            guard let point = self.axDriver.elementCenter(of: element), self.axDriver.pointHitsSameWindow(as: element, at: point) else {
                throw TestHarnessError.elementNotFound(identifier: "\(qualifier)/occluded")
            }
            self.axDriver.postClickPair(at: point, clickState: 1)
            try? await Task.sleep(for: .milliseconds(100))
            try self.typeFocusedText(text, clearFirst: false)
        }
    }

    /// Polls until the element resolved by `identifier`+`role` reports a value
    /// containing `substring`. The role-aware companion to `waitForDescendant`,
    /// for asserting on a control that shares a container-propagated identifier
    /// with siblings of other roles (e.g. the room-subject topic text).
    func waitForElementValue(
        containing substring: String,
        identifier: String,
        role: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                guard let element = try? self.axDriver.resolveElement(identifier: identifier, role: role) else { return false }
                return self.axDriver.elementText(of: element)?.contains(substring) ?? false
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForElementValue timeout (\(timeout)) substring '\(substring)' for '\(identifier)' role '\(role)'")
            throw TestHarnessError.timeout
        }
    }

    /// Activates Ducko, raises the named window, makes it main, and points
    /// the application's `kAXFocusedWindowAttribute` at it. Used to bring a
    /// non-key window forward before clicking buttons on a sheet attached
    /// to it.
    func activateWindow(named title: String) async throws {
        let identifier = "window[\(title)]"
        // Full-body retry: a stale handle from `kAXWindowsAttribute` re-walks
        // the window list.
        try await retryOnStaleElement(identifier: identifier) {
            guard let pid = self.process?.processIdentifier else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            await Self.activateApp(pid: pid)
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
            guard err == .success, let windows = windowsValue as? [AXUIElement] else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            let titled = windows.compactMap { window -> (element: AXUIElement, title: String)? in
                var titleValue: AnyObject?
                let titleErr = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                guard titleErr == .success, let windowTitle = titleValue as? String else { return nil }
                return (window, windowTitle)
            }
            guard let index = Self.windowIndex(matching: title, titles: titled.map(\.title)) else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            let window = titled[index].element
            // `kAXRaiseAction` returns `kAXErrorAttributeUnsupported`
            // (-25205) on the Contacts window when a SwiftUI `.sheet`
            // is attached to it (room-config save sheet) — even though
            // `AXRaise` is in the action list and the underlying setter
            // calls below succeed. Treat raise as best-effort and let
            // the kAXMain / kAXFocusedWindow setters be the
            // authoritative "make this window key" path. Translate the
            // setter results so a silent failure on those leaves the
            // wrong window key and downstream sheet-button clicks
            // would fail with a misleading "elementNotFound" rather
            // than a clear AX-routing diagnostic.
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let mainErr = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            if let mainError = Self.mapPerformError(mainErr, identifier: identifier, action: kAXMainAttribute) {
                throw mainError
            }
            let focusedErr = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            if let focusedError = Self.mapPerformError(focusedErr, identifier: identifier, action: kAXFocusedWindowAttribute) {
                throw focusedError
            }
        }
    }

    /// Index of the window to activate for `target`, preferring an exact title
    /// match over a substring match so a window whose title merely *contains*
    /// `target` (e.g. "Chat Transcripts" when `target == "Chat"`) can't be
    /// re-keyed ahead of the intended exact-title window. Returns `nil` when no
    /// title matches; order-preserving, so the index maps back to the caller's
    /// matching window handle.
    static func windowIndex(matching target: String, titles: [String]) -> Int? {
        titles.firstIndex(of: target) ?? titles.firstIndex { $0.contains(target) }
    }

    /// Walks `identifier`'s subtree post-order DFS and returns the
    /// last-encountered `kAXIdentifierAttribute` value that starts with
    /// `prefix`. Used by `testMessageCorrection` to discover the just-sent
    /// bubble's id without an opaque "deepest descendant" walk.
    func lastIdentifier(matchingPrefix prefix: String, underIdentifier identifier: String) async throws -> String? {
        do {
            return try axDriver.collectLastIdentifier(matchingPrefix: prefix, under: identifier)
        } catch TestHarnessError.elementNotFound {
            try await Task.sleep(for: .milliseconds(50))
            return try axDriver.collectLastIdentifier(matchingPrefix: prefix, under: identifier)
        }
    }

    // MARK: - Internal AX helpers

    /// Loops `check` every 50 ms until it returns `true` or `timeout` elapses.
    /// One final probe runs after the deadline so a `check` invocation that
    /// started just before the deadline (and was still in flight as it
    /// crossed) gets a chance to surface a result before timing out. Callers
    /// that need a per-call diagnostic on timeout catch
    /// `TestHarnessError.timeout` and log before re-throwing.
    private func pollUntil(timeout: Duration, check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if try await check() { return }
        throw TestHarnessError.timeout
    }

    static func mapSetterError(_ err: AXError, identifier: String) -> SetterOutcome {
        AXDriver.mapSetterError(err, identifier: identifier)
    }

    static func mapPerformError(_ err: AXError, identifier: String, action: String) -> TestHarnessError? {
        AXDriver.mapPerformError(err, identifier: identifier, action: action)
    }

    static func classifyContextMenuPressPick(press: AXError, pick: @autoclosure () -> AXError, identifier: String) -> TestHarnessError? {
        AXDriver.classifyContextMenuPressPick(press: press, pick: pick(), identifier: identifier)
    }

    typealias SetterOutcome = AXDriver.SetterOutcome

    /// Polls until `popUp`'s shown menu becomes resolvable. Used by
    /// `pickPopUpItem` to absorb `cannotComplete` from `kAXShowMenuAction`
    /// (the menu may have opened anyway) and the asynchronous AX publication
    /// window after a successful action. Callers pick a short timeout for
    /// speculative probes and the full UI timeout for confirmation after a
    /// committed press fallback.
    private func waitForShownMenu(
        on popUp: AXUIElement,
        identifier: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        try await pollUntil(timeout: timeout) {
            (try? self.axDriver.resolveShownMenu(for: popUp, identifier: identifier)) != nil
        }
    }

    /// Polls until a context menu (`kAXMenuRole` descendant of the
    /// application element) appears. Used by `contextMenuItem(title:)`
    /// because right-click context menus are not anchored to a popUp button —
    /// `kAXShowMenuAction` opens them as a child of the application root, so
    /// a popUp-scoped lookup like `resolveShownMenu` doesn't apply.
    private func waitForShownContextMenu(
        timeout: Duration = TestTimeout.uiElement
    ) async throws -> AXUIElement {
        try await pollForApplicationDescendantPresent(
            timeout: timeout,
            identifier: "context-menu",
            find: axDriver.findContextMenu
        )
    }

    /// Polls until no context-menu `kAXMenuRole` descendant remains under
    /// the application element. The menu bar's `AXMenuBar > AXMenuBarItem >
    /// AXMenu` subtree is persistently in the AX hierarchy on macOS 26 (the
    /// Apple menu's static contents stay queryable even when closed), so we
    /// skip the menu-bar subtree and look for context menus only — those are
    /// siblings of `AXWindow`, not descendants of `AXMenuBar`.
    private func waitForContextMenuDismissed(
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        try await pollUntilApplicationDescendantAbsent(timeout: timeout, find: axDriver.findContextMenu)
    }

    /// Polls the application AX root every 50 ms until `find` returns a value,
    /// then runs one final probe after the deadline. `find` re-creates AX
    /// references inside the closure each iteration so the non-Sendable
    /// `AXUIElement` never crosses an isolation boundary — only `pid_t`
    /// (`Sendable`) is captured. Throws `elementNotFound(identifier:)` on
    /// timeout or if the process has exited.
    private func pollForApplicationDescendantPresent(
        timeout: Duration,
        identifier: String,
        find: (AXUIElement) -> AXUIElement?
    ) async throws -> AXUIElement {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: identifier)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let app = AXUIElementCreateApplication(pid)
            if let match = find(app) { return match }
            try await Task.sleep(for: .milliseconds(50))
        }
        let app = AXUIElementCreateApplication(pid)
        if let match = find(app) { return match }
        throw TestHarnessError.elementNotFound(identifier: identifier)
    }

    /// Polls the application AX root every 50 ms until `find` returns `nil`,
    /// then runs one final probe after the deadline. Same isolation-safety
    /// shape as `pollForApplicationDescendantPresent`. Treats a missing
    /// process as already-satisfied (nothing to dismiss if there's no app),
    /// so concurrent teardown does not surface as a spurious timeout.
    private func pollUntilApplicationDescendantAbsent(
        timeout: Duration,
        find: (AXUIElement) -> AXUIElement?
    ) async throws {
        guard let pid = process?.processIdentifier else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let app = AXUIElementCreateApplication(pid)
            if find(app) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let app = AXUIElementCreateApplication(pid)
        if find(app) == nil { return }
        throw TestHarnessError.timeout
    }

    /// Polls until no top-level surface contains `dialogText`, confirming the
    /// confirmation dialog dismissed after its action fired.
    private func waitForConfirmationDialogDismissed(
        dialogText: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        try await pollUntilApplicationDescendantAbsent(timeout: timeout) { app in
            guard let topChildren = self.axDriver.readAttribute(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for root in topChildren where (self.axDriver.readAttribute(root, kAXRoleAttribute) as? String) != kAXMenuBarRole {
                if self.axDriver.findDescendant(in: root, role: kAXStaticTextRole, where: {
                    self.axDriver.elementText(of: $0)?.contains(dialogText) ?? false
                }) != nil {
                    return root
                }
            }
            return nil
        }
    }

    /// Polls `axDriver.readValue(identifier:)` until it equals `expected`. Absorbs
    /// transient `elementNotFound` during SwiftUI binding commits. Use as
    /// a precondition gate before `clearAndType` when an `.onChange`
    /// pre-fills the field.
    func waitForValue(_ expected: String, identifier: String) async throws {
        do {
            try await pollUntil(timeout: TestTimeout.uiElement) {
                do {
                    return try self.axDriver.readValue(identifier: identifier) == expected
                } catch TestHarnessError.elementNotFound {
                    return false
                }
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForValue timeout (\(TestTimeout.uiElement)) for identifier '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Kind of secondary click used to open a context menu.
    private enum ContextClickKind {
        case controlLeft
        case right
    }

    /// Opens a context menu at `point` by synthesizing a real secondary click —
    /// a SwiftUI `List` row's `.contextMenu` does not respond to
    /// `kAXShowMenuAction` (verified: the action returns but no `kAXMenuRole`
    /// publishes), unlike the AppKit contact-list table. Tries Control-left then
    /// right-button, and both event taps, since which combination the SwiftUI
    /// gesture recognizer observes is not guaranteed; polls for the menu after
    /// each. Throws if none opens a menu.
    private func openContextMenu(at point: CGPoint, identifier: String) async throws {
        let attempts: [(ContextClickKind, CGEventTapLocation)] = [
            (.controlLeft, .cghidEventTap),
            (.right, .cghidEventTap),
            (.controlLeft, .cgSessionEventTap),
            (.right, .cgSessionEventTap)
        ]
        for (kind, tap) in attempts {
            await postContextClick(kind, at: point, tap: tap)
            if await (try? waitForShownContextMenu(timeout: .milliseconds(900))) != nil {
                return
            }
        }
        throw TestHarnessError.elementNotFound(identifier: "\(identifier)/context-menu")
    }

    /// Posts a single secondary-click `CGEvent` sequence at `point`: move →
    /// settle → down → hold → up. The move/settle updates hover/hit-test state
    /// before the press, which a bare down/up pair on the same tick skips.
    private func postContextClick(
        _ kind: ContextClickKind,
        at point: CGPoint,
        tap: CGEventTapLocation
    ) async {
        if let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            move.post(tap: tap)
        }
        try? await Task.sleep(for: .milliseconds(150))

        let downType: CGEventType = kind == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = kind == .right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = kind == .right ? .right : .left
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        else {
            return
        }
        if kind == .controlLeft {
            down.flags = [.maskControl]
            up.flags = [.maskControl]
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: tap)
        try? await Task.sleep(for: .milliseconds(120))
        up.post(tap: tap)
    }

    /// Minimizes or restores the window whose title contains `title`. Used to
    /// move the pinned Contacts window out of the way before a synthetic click
    /// into the Chat window, since AppKit hit-tests CGEvent clicks against the
    /// topmost window at the point and Contacts can overlap the Chat sidebar.
    func setWindowMinimized(named title: String, _ minimized: Bool) async throws {
        let identifier = "window[\(title)]"
        try await retryOnStaleElement(identifier: identifier) {
            guard let pid = self.process?.processIdentifier else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            let app = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
            guard err == .success, let windows = windowsValue as? [AXUIElement] else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            guard let window = windows.first(where: { window in
                var titleValue: AnyObject?
                let titleErr = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                return titleErr == .success && (titleValue as? String)?.contains(title) == true
            }) else {
                throw TestHarnessError.elementNotFound(identifier: identifier)
            }
            let setErr = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                minimized ? kCFBooleanTrue : kCFBooleanFalse
            )
            if let error = Self.mapPerformError(setErr, identifier: identifier, action: kAXMinimizedAttribute) {
                throw error
            }
        }
    }

    // MARK: - Static helpers

    /// Spawns `Ducko.app` through LaunchServices via
    /// `NSWorkspace.openApplication(at:configuration:)`. Returns the new
    /// `NSRunningApplication` so the caller can drive AX queries against
    /// its PID and terminate it on teardown. `createsNewApplicationInstance`
    /// is set so each test gets its own process even when a developer's
    /// dev-build Ducko is already running.
    ///
    /// Note: `OpenConfiguration.environment` *replaces* the inherited
    /// environment for the spawned process — it does not augment it. The
    /// init's allowlist (`HOME`, `PATH`, `LANG`, `LC_ALL`, plus
    /// `DUCKO_PROFILE`) intentionally re-adds anything the app needs.
    @MainActor
    private static func openApp(
        at bundleURL: URL,
        environment: [String: String],
        arguments: [String]
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        return try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    /// Polls `app.isTerminated` until the app exits or `timeout` elapses.
    /// `NSRunningApplication`'s analogue of `CLIProcess.waitForProcessExit`.
    private nonisolated static func waitForRunningAppExit(
        _ app: NSRunningApplication,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if app.isTerminated { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return app.isTerminated
            }
        }
        return app.isTerminated
    }

    /// Reads the bundle's Info dictionary and verifies
    /// `DuckoBuildConfiguration == "debug"`. Throws
    /// `TestHarnessError.appBundleNotDebug` otherwise.
    private static func assertDebugBundle(at bundleURL: URL) throws {
        try assertDebugBundle(info: Bundle(url: bundleURL)?.infoDictionary, bundlePath: bundleURL.path)
    }

    /// Pure-core debug-bundle gate: validates `info` carries
    /// `DuckoBuildConfiguration == "debug"` and throws
    /// `TestHarnessError.appBundleNotDebug(path:)` for every dict-validation
    /// failure (nil dict, missing key, wrong type, non-`"debug"` value). The
    /// `appBundleMissing` case remains reserved for the pre-launch
    /// executable-on-disk check; do not reclassify any dict failure as
    /// `appBundleMissing`.
    static func assertDebugBundle(info: [String: Any]?, bundlePath: String) throws {
        guard let info,
              let configuration = info["DuckoBuildConfiguration"] as? String,
              configuration == "debug" else {
            throw TestHarnessError.appBundleNotDebug(path: bundlePath)
        }
    }

    @MainActor
    private static func activateAppOnMain(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            log.debug("activateApp: NSRunningApplication(processIdentifier: \(pid)) returned nil")
            return
        }
        if !app.activate() {
            // `activate()` returns false when the app has quit or cannot be
            // brought forward. Log so focus and input timeouts are diagnosable.
            log.debug("activateApp: NSRunningApplication.activate() returned false for pid \(pid)")
        }
    }

    private nonisolated static func activateApp(pid: pid_t) async {
        await activateAppOnMain(pid: pid)
    }

    /// Activates Ducko and waits until `NSRunningApplication.isActive`
    /// flips to `true` (or the deadline elapses). `NSRunningApplication.activate()`
    /// returns before the activation transition completes. Keyboard events
    /// target the owned PID, but SwiftUI text bindings still need field-editor
    /// focus in that app.
    private func ensureFrontmost(timeout: Duration = .milliseconds(500)) async {
        guard let pid = process?.processIdentifier else { return }
        await Self.activateApp(pid: pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if app.isActive { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Sets `kAXFocusedAttribute = true` on the element and logs at debug
    /// when the AX error is non-success. Many SwiftUI controls accept value
    /// or keystroke input without taking AX focus, so failure here is not
    /// fatal — but if a downstream keystroke fallback misses its target,
    /// the breadcrumb makes the failure mode legible.
    private nonisolated static func setFocused(_ element: AXUIElement, identifier: String) {
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if err != .success {
            log.debug("setFocused: AXError \(err.rawValue) on '\(identifier)'")
        }
    }

    private func postKey(_ key: CGKeyCode, modifiers: CGEventFlags, text: String? = nil) throws {
        guard let process, !process.isTerminated else {
            throw TestHarnessError.elementNotFound(identifier: "application")
        }
        let pid = process.processIdentifier
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: isDown) else {
                throw TestHarnessError.elementNotFound(identifier: "keyboard-event")
            }
            event.flags = modifiers
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
            }
            event.postToPid(pid)
        }
    }
}
