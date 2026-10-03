import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIPreferencesTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `cmd plus comma opens the preferences window`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "contact-list", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(
                    identifier: "preferences-window",
                    timeout: TestTimeout.uiElement
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `accounts tab lists the seeded JID`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "contact-list", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(
                    identifier: "preferences-window",
                    timeout: TestTimeout.uiElement
                )

                try await app.clickTab(title: "Accounts", identifier: "preferences-window")

                let alice = TestCredentials.alice
                let aliceVisible = try await app.containsDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: alice.jid,
                    underIdentifier: "preferences-window"
                )
                #expect(aliceVisible)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `accounts detail pane lists the Actions menu and opens each non-destructive sheet`() async throws {
            try await UISeededApp.withSeededApp { app in
                // Gate on a connected account before opening prefs so the detail
                // pane's `isConnected`-gated Actions menu renders. Wait on Bob (a
                // roster contact with a `contact-row-` element) rather than Alice:
                // Alice is the seeded self account and has no roster row of her
                // own, so `waitForContactRow(.alice)` would time out.
                try await app.waitForContactRow(TestCredentials.bob)

                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(identifier: "preferences-window", timeout: TestTimeout.uiElement)
                try await app.clickTab(title: "Accounts", identifier: "preferences-window")

                // Select the seeded account's row so the detail pane renders.
                let alice = TestCredentials.alice
                try await app.selectListRow(containingSubstring: alice.jid, underIdentifier: "preferences-window")

                // The Actions pull-down renders only while connected.
                try await app.waitForElement(identifier: "account-actions-menu", timeout: TestTimeout.uiElement)
                // Unregister is only read, never pressed: accepting its confirmation would unregister the fixture account from the server.
                let actionTitles = try await app.menuItemTitles(identifier: "account-actions-menu")
                #expect(actionTitles == [
                    "Connection Info…", "Server Info…", "",
                    "Change Password…", "Check Registration…", "",
                    "Unregister Account…"
                ])

                try await app.pressMenuItem(title: "Change Password…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "new-password-field", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
                try await app.waitForSheetDismissed()

                // Server Info and Check Registration both fetch on appear, so their
                // sheet containers mount while the request is still in flight. Wait
                // on an element only the settled states render. What the server
                // answers is not asserted — every settled state is a pass.
                try await app.pressMenuItem(title: "Server Info…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "server-info-content", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
                try await app.waitForSheetDismissed()

                try await app.pressMenuItem(title: "Check Registration…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "registration-form-content", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
                try await app.waitForSheetDismissed()

                try await app.pressMenuItem(title: "Connection Info…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "cipherSuite", timeout: TestTimeout.uiElement)
                let cipherUnavailable = try await app.containsDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: "Not available",
                    underIdentifier: "cipherSuite"
                )
                #expect(cipherUnavailable)
                try await app.waitForElement(identifier: "tlsVersion", timeout: TestTimeout.uiElement)
                try await app.waitForElement(identifier: "certFingerprint", timeout: TestTimeout.uiElement)
                try await app.clickSheetButton(label: "Done")
                try await app.waitForSheetDismissed()

                try await app.pressMenuItem(title: "Connection Info…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "cipherSuite", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
                try await app.waitForSheetDismissed()

                try await app.pressMenuItem(title: "Connection Info…", identifier: "account-actions-menu")
                try await app.waitForElement(identifier: "cipherSuite", timeout: TestTimeout.uiElement)
                try await app.activateWindow(named: "Contacts")
                try await app.pickPopUpItem(title: "Offline", identifier: "status-picker")
                try await app.waitForDescendantButton(label: "Connect", underIdentifier: "preferences-window")
                try await app.waitForSheetDismissed()
                try await app.waitForAbsence(identifier: "account-actions-menu")
            }
        }
    }
}
