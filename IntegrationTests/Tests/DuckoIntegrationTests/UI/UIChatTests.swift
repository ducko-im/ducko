import ApplicationServices
import Carbon.HIToolbox
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIChatTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `double-clicking a contact opens the chat window`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `sending a message renders it in the message list`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let body = "UI test \(UUID().uuidString)"
                try await app.type(body, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.uiElement)
                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: body,
                    underIdentifier: "message-list"
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `incoming messages from a CLI bob appear in the chat window`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    let body = "ui-recv-\(UUID().uuidString.prefix(8))"
                    try await bobREPL.send("send \(TestCredentials.alice.jid) \(body)")

                    try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.event)
                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: body,
                        underIdentifier: "message-list",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @MainActor private static func waitUntilTypingInContactSearch(_ app: AppAccessor) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while ContinuousClock.now < deadline {
                if await isTypingInContactSearch(app) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            let isTyping = await isTypingInContactSearch(app)
            try #require(isTyping, "The contact search field did not keep the keyboard")
        }

        /// Whether the Contacts window is the focused one and its search field has the keyboard.
        @MainActor private static func isTypingInContactSearch(_ app: AppAccessor) async -> Bool {
            let focusedWindow = await app.focusedWindowTitle()
            let hasKeyboard = await app.hasKeyboardFocus(identifier: "contact-search-field")
            return focusedWindow == "Contacts" && hasKeyboard
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `a contact's message opens their chat without taking the keyboard`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)

                // The user is typing in the Contacts window, with no chat window open. What is typed so far matches
                // no contact.
                try await app.pressKey(CGKeyCode(kVK_ANSI_F), modifiers: .maskCommand)
                try await app.waitForElement(identifier: "contact-search-field", timeout: TestTimeout.uiElement)
                try await app.replaceText("zz", intoIdentifier: "contact-search-field")
                try await app.waitForAbsence(identifier: "contact-row-\(bob.jid)", timeout: TestTimeout.uiElement)
                let windowsBefore = await app.windowTitles()
                #expect(windowsBefore == ["Contacts"])

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    // The app is the one in front, where a window that opens takes the keyboard unless it is kept
                    // from it. Behind another app it never would, and the checks below would hold for nothing.
                    let isInFront = await app.bringToFront()
                    let isTypingInSearch = await Self.isTypingInContactSearch(app)
                    try #require(isInFront && isTypingInSearch)

                    let body = "ui-quiet-\(UUID().uuidString.prefix(8))"
                    try await bobREPL.send("send \(TestCredentials.alice.jid) \(body)")

                    // The chat window appears on its own. Until the keyboard has been checked, it is only looked
                    // for by reading the window list: resolving an element in it could raise it.
                    try await app.waitForWindowCount(2, timeout: TestTimeout.event)
                    let wasStillInFront = await app.isFrontmost()
                    try #require(wasStillInFront, "Another app came to the front while the chat window opened")
                    // The new window can have the keyboard for a moment before it is put back, so the search field
                    // is given that moment to have it again.
                    try await Self.waitUntilTypingInContactSearch(app)

                    // What is typed next goes on after what was there. Typed over a selection of the whole field, it
                    // would replace it.
                    try await app.typeIntoFocusedElement("bob", clearFirst: false)
                    try await app.waitForValue("zzbob", identifier: "contact-search-field")

                    // The window is kept back for a second after it opens. Once that is over the keyboard is still
                    // where it was, and the chat counts as opened but not looked at: unread, with nothing telling
                    // the contact it was read.
                    try await Task.sleep(for: .milliseconds(1500))
                    let isTypingInSearchLater = await Self.isTypingInContactSearch(app)
                    #expect(isTypingInSearchLater)
                    try await app.waitForValue("1 unread message", identifier: "chat-tab-\(bob.jid)")
                    let sawReadMarker = await (try? bobREPL.waitForOutput(containing: "read marker", timeout: .seconds(2))) != nil
                    #expect(!sawReadMarker)

                    // A further message, with the chat window already there, leaves the keyboard alone as well.
                    try await bobREPL.send("send \(TestCredentials.alice.jid) \(body)-2")
                    try await app.waitForValue("2 unread messages", identifier: "chat-tab-\(bob.jid)")
                    let isTypingInSearchAfterSecond = await Self.isTypingInContactSearch(app)
                    #expect(isTypingInSearchAfterSecond)

                    // The chat it opened holds the message.
                    try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.event)
                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: body,
                        underIdentifier: "message-list",
                        timeout: TestTimeout.event
                    )

                    // Going to the chat is what makes it read: the count clears and the contact is told. This is
                    // also what shows the check for no read marker above could have failed.
                    try await app.raiseWindow(containing: "message-field")
                    try await app.waitForValue("", identifier: "chat-tab-\(bob.jid)")
                    _ = try await bobREPL.waitForOutput(containing: "read marker", timeout: TestTimeout.event)
                }
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `bob composing notification surfaces a typing indicator`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                let alice = TestCredentials.alice

                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let aliceJID = try #require(BareJID.parse(alice.jid))
                let bobJID = try #require(BareJID.parse(bob.jid))
                let bobUsername = try #require(bobJID.localPart)

                var builder = XMPPClientBuilder(
                    domain: bobJID.domainPart,
                    username: bobUsername,
                    password: bob.password
                )
                builder.withPreferredResource("inttest-ui-typing")
                builder.withModule(ChatModule())
                builder.withModule(ChatStatesModule())
                builder.withModule(PresenceModule())
                let client = await builder.build()

                // Register disconnect immediately so a thrown connect()
                // still tears down.
                await app.addCleanup({ await client.disconnect() }, phase: .inApp)

                try await client.connect()
                try await TestHarness.waitForRawEvent(in: client.events, timeout: TestTimeout.connect) { event in
                    if case .connected = event { return true }
                    return false
                }

                // Prime the chat-state context with `.active` before
                // `.composing` per XEP-0085, so a receiver gating on prior
                // negotiation still surfaces the typing indicator.
                //
                // Address alice's bare JID. Prosody now routes to the
                // live resource because the disconnect-side SM
                // `<r/>`/`<a/>` ack handshake prevents prior test runs
                // from leaving stale resources in mod_smacks resumption
                // queue.
                let chatStates = try #require(await client.module(ofType: ChatStatesModule.self))
                let aliceTarget: JID = .bare(aliceJID)
                try await chatStates.sendChatState(.active, to: aliceTarget)
                try await chatStates.sendChatState(.composing, to: aliceTarget)

                try await app.waitForElement(
                    identifier: "typing-indicator",
                    timeout: TestTimeout.event
                )

                try await chatStates.sendChatState(.active, to: aliceTarget)

                // Assert dismissal — the indicator must actually disappear,
                // not merely "may have disappeared by the time we checked".
                try await app.waitForAbsence(
                    identifier: "typing-indicator",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `correcting a sent message updates its body`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let body = "ui-edit-\(UUID().uuidString.prefix(8))"
                try await app.type(body, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.uiElement)
                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: body,
                    underIdentifier: "message-list"
                )

                let bubbleIdentifier = try await app.lastIdentifier(
                    matchingPrefix: "message-bubble-",
                    underIdentifier: "message-list"
                )
                let resolved = try #require(bubbleIdentifier)
                let messageID = String(resolved.dropFirst("message-bubble-".count))

                try await app.rightClick(identifier: "message-bubble-\(messageID)")
                try await app.contextMenuItem(title: "Edit")

                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
                // MessageInputView's `.onChange(of: editingMessage?.id)` pre-fills the composer;
                // wait for it so a delayed dispatch can't clobber the typed replacement.
                try await app.waitForValue(body, identifier: "message-field")
                let editedBody = "\(body) (edited)"
                try await app.clearAndType(editedBody, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: editedBody,
                    underIdentifier: "message-list"
                )
            }
        }
    }
}
