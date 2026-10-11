import Carbon.HIToolbox
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIContactListTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `contact list shows a known peer after auto-connect`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")
                // Single combined AX element should advertise something
                // identifying the contact (display name or JID local-part)
                // in its label. Its value holds the row's activity, so the
                // label is what identifies it. Locks in the
                // `.accessibilityElement(children: .combine)` contract on
                // `ContactRow`. Without it the identifier would resolve to a
                // leaf with no readable label.
                let label = try await app.label(identifier: "contact-row-\(bob.jid)") ?? ""
                let localPart = bob.jid.split(separator: "@").first.map(String.init) ?? ""
                #expect(!label.isEmpty)
                #expect(label.localizedCaseInsensitiveContains(localPart))
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `searching the contact list filters to a matching JID`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")

                // Search is hidden until revealed with Find (⌘F); the field
                // carries `contact-search-field` once shown.
                try await app.pressKey(CGKeyCode(kVK_ANSI_F), modifiers: .maskCommand)
                try await app.waitForElement(
                    identifier: "contact-search-field",
                    timeout: TestTimeout.uiElement
                )

                // Negative case first: a query that matches no contact must
                // hide bob's row. `replaceText` types via keystrokes so the
                // SwiftUI binding commits (a plain AX value-set leaves
                // `$searchText` stale).
                try await app.replaceText("zzznomatch", intoIdentifier: "contact-search-field")
                try await app.waitForAbsence(
                    identifier: "contact-row-\(bob.jid)",
                    timeout: TestTimeout.uiElement
                )

                // Positive case: replacing the query with "bob" surfaces the
                // row again.
                try await app.replaceText("bob", intoIdentifier: "contact-search-field")
                try await app.waitForElement(
                    identifier: "contact-row-\(bob.jid)",
                    timeout: TestTimeout.uiElement
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `right-clicking a contact row opens the context menu`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")
                try await app.rightClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(
                    identifier: "send-directed-presence-menu-item",
                    timeout: TestTimeout.uiElement
                )
            }
        }
    }
}
