import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIMUCTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `joining a fresh room reaches the chat window`() async throws {
            try await UISeededApp.withSeededApp { app in
                _ = try await Self.joinAndUnlockRoom(app)
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `messages exchanged in a room appear on both ends`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: TestCredentials.bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    // Bob joins first so live delivery wins (MUC's default
                    // history mode emits no replay request).
                    try await bobREPL.send("/join \(roomJID)")
                    _ = try await bobREPL.waitForOutput(containing: "Joined", timeout: TestTimeout.connect)

                    let body = "muc-\(UUID().uuidString.prefix(8))"
                    try await app.type(body, intoIdentifier: "message-field")
                    try await app.pressReturn(intoIdentifier: "message-field")

                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: body,
                        underIdentifier: "message-list",
                        timeout: TestTimeout.event
                    )

                    _ = try await bobREPL.waitForOutput(containing: body, timeout: TestTimeout.event)
                }
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `participant sidebar lists current occupants`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                // Sidebar is hidden by default — toggle it on.
                try await app.click(identifier: "toggle-participant-sidebar")
                try await app.waitForElement(identifier: "participant-sidebar", timeout: TestTimeout.uiElement)

                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: "alice",
                    underIdentifier: "participant-sidebar"
                )

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: TestCredentials.bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID)")
                    _ = try await bobREPL.waitForOutput(containing: "Joined", timeout: TestTimeout.connect)

                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: "bob",
                        underIdentifier: "participant-sidebar",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `participant context menu offers change nickname for self`() async throws {
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                // The participant sidebar is in the Chat window; the pinned
                // Contacts window can overlap it. A synthetic right-click is
                // hit-tested against the topmost window at the point, so move
                // Contacts out of the way and bring Chat forward first.
                try await app.setWindowMinimized(named: "Contacts", true)
                try await app.activateWindow(named: roomJID)

                try await app.click(identifier: "toggle-participant-sidebar")
                try await app.waitForElement(identifier: "participant-sidebar", timeout: TestTimeout.uiElement)
                // Wait for the occupant row to populate before right-clicking it
                // — the sidebar element appears before the roster row renders.
                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: "alice",
                    underIdentifier: "participant-sidebar"
                )

                // `Change Nickname…` appears only on the self row. Alice joined
                // as "alice", so her row's static text is the stable handle —
                // participant rows carry no identifier and bridge to `AXGroup`.
                try await app.rightClickDescendant(
                    roles: [kAXGroupRole as String, kAXRowRole as String, kAXCellRole as String],
                    withSubstring: "alice",
                    underIdentifier: "participant-sidebar"
                )
                try await app.contextMenuItem(title: "Change Nickname…")

                // The Change Nickname alert's TextField auto-focuses with its
                // text selected, but its `accessibilityIdentifier` does not
                // bridge to AX — type into the focused element rather than
                // resolving `change-nickname-field`. Wait on the alert's `Change`
                // button (its title does bridge) to know the alert is up.
                let newNickname = "alice-\(UUID().uuidString.prefix(4))"
                try await app.waitForWindowButton(label: "Change")
                try await app.typeIntoFocusedElement(newNickname)
                try await app.clickDescendantButton(label: "Change")

                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: newNickname,
                    underIdentifier: "participant-sidebar",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `room subject can be edited via the pencil`() async throws {
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                // Make Chat the key window so its SwiftUI controls respond to
                // kAXPress (the pinned Contacts window otherwise keeps key).
                try await app.setWindowMinimized(named: "Contacts", true)
                try await app.activateWindow(named: roomJID)

                let topic = "topic-\(UUID().uuidString.prefix(6))"
                // SwiftUI propagates `room-subject-view` onto each leaf, so the
                // pencil/topic-field/Save all carry that identifier and are
                // resolved by role (not as descendants). The pencil is the lone
                // `AXButton` with the id when not editing; clicking it flips the
                // view into edit mode, surfacing the `AXTextField` (which
                // auto-focuses via `@FocusState`, installing its field editor)
                // and the inline Save (`AXButton` labeled "Save", distinct from
                // Cancel). Click the field to make it first responder (the chat
                // message-field otherwise wins focus), then type — kAXSetValue
                // doesn't commit the SwiftUI binding the Save button reads.
                try await app.clickElement(identifier: "room-subject-view", role: kAXButtonRole as String)
                try await app.waitForElement(identifier: "room-subject-view", role: kAXTextFieldRole as String)
                try await app.focusAndTypeElement(topic, identifier: "room-subject-view", role: kAXTextFieldRole as String)
                // Confirm the typed text reached the field's value (the SwiftUI
                // binding committed) before Save reads it.
                try await app.waitForElementValue(
                    containing: topic,
                    identifier: "room-subject-view",
                    role: kAXTextFieldRole as String
                )
                try await app.clickElement(identifier: "room-subject-view", role: kAXButtonRole as String, label: "Save")

                try await app.waitForElementValue(
                    containing: topic,
                    identifier: "room-subject-view",
                    role: kAXStaticTextRole as String,
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `destroying a room removes it`() async throws {
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                // Room rows carry `room-row-{jid}` identifiers, so the context
                // menu opens via the identifier-keyed right-click. Bring Contacts
                // forward so its AppKit context menu and the room-settings sheet
                // it presents are active.
                try await app.activateWindow(named: "Contacts")
                try await app.waitForElement(identifier: "room-row-\(roomJID)", timeout: TestTimeout.uiElement)
                try await app.rightClick(identifier: "room-row-\(roomJID)")
                try await app.contextMenuItem(title: "Room Settings…")
                try await app.waitForElement(identifier: "room-settings-view", timeout: TestTimeout.uiElement)

                // SwiftUI propagates `room-settings-view` onto the leaf buttons,
                // so the destroy button is resolved by id+role+label, not its
                // (overridden) `room-settings-destroy` identifier.
                try await app.clickElement(identifier: "room-settings-view", role: kAXButtonRole as String, label: "Destroy Room…")
                // Confirm in the `.confirmationDialog`, scoped to its message so
                // an unrelated "Destroy" can't match. The sheet dismisses after
                // `destroyRoom` returns; the room row then disappears once the
                // destroyed conversation is removed from the list.
                try await app.clickConfirmationDialogButton(dialogText: "permanently destroy", buttonLabel: "Destroy")
                try await app.waitForAbsence(identifier: "room-settings-view", timeout: TestTimeout.uiElement)
                try await app.waitForAbsence(identifier: "room-row-\(roomJID)", timeout: TestTimeout.event)
            }
        }

        // MARK: - Helpers

        /// Joins a fresh room and submits the auto-opened config sheet so
        /// the room is unlocked. Returns the room JID for the test body.
        @MainActor private static func joinAndUnlockRoom(_ app: AppAccessor) async throws -> String {
            // Lowercase the localpart: JID normalization lowercases it, so the
            // `room-row-{jid}` identifier (built from the normalized conversation
            // JID) would otherwise mismatch a mixed-case generated suffix.
            let roomJID = "inttest-ui-\(UUID().uuidString.prefix(8).lowercased())@\(TestCredentials.mucService)"

            try await app.waitForContactRow(TestCredentials.bob)

            // Join Room… lives in the File menu; drive it through its ⌘⇧N shortcut.
            try await app.pressKey(CGKeyCode(kVK_ANSI_N), modifiers: [.maskCommand, .maskShift])
            try await app.waitForElement(identifier: "room-jid-field", timeout: TestTimeout.uiElement)
            try await app.type(roomJID, intoIdentifier: "room-jid-field")
            try await app.type("alice", intoIdentifier: "room-nickname-field")
            try await app.click(identifier: "join-room-button")

            // RoomJoinDialog.onJoin opens the chat window; message-field is
            // the most reliable frontmost-chat marker (the participant
            // sidebar is hidden by default).
            try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.connect)

            // The room-config sheet auto-opens on the contact-list window
            // (RoomRowWithMenu.onAppear/onChange). The chat window is now
            // key, so kAXPressAction on the sheet may be silently dropped.
            // Bring the contact-list window forward first.
            try await app.activateWindow(named: "Contacts")
            // SwiftUI's `.accessibilityIdentifier` on a `Button` carrying
            // `.keyboardShortcut(.defaultAction)` is not reliably bridged to
            // the AX button on macOS 26, so identifier-based lookup misses
            // the Save button entirely. Walking the sheet by role + title is
            // the documented-stable path.
            try await app.waitForElement(identifier: "room-settings-view", timeout: TestTimeout.uiElement)
            try await app.clickSheetButton(label: "Save")
            try await app.waitForSheetDismissed()

            // A fresh room has no display name, so its chat window is titled with the room JID.
            try await app.activateWindow(named: roomJID)
            return roomJID
        }
    }
}
