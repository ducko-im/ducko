import Carbon.HIToolbox
import DuckoCore
import DuckoData
import DuckoXMPP
import Foundation
import SwiftData
import Testing

extension DuckoIntegrationTests.UILayer {
    @Suite(.enabled(
        if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted,
        "Debug Ducko.app or accessibility trust unavailable"
    ))
    struct UIRosterOutcomeTests {
        @Test(arguments: ["add", "menu", "shortcut", "info", "rejection", "script", "script-info"])
        @MainActor func `roster outcomes remain visible and can be dismissed`(entry: String) async throws {
            let server = UIRosterLoopbackServer()
            let port = try await server.start()
            let profile = "inttest-ui-\(UUID().uuidString.prefix(8))"
            do {
                try await seed(profile: profile, port: port)
                if entry == "rejection" { await server.rejectMutation() }
                try await AppAccessor.withAppAccessor(profile: profile) { app in
                    try await app.waitForElement(identifier: "contact-row-bob@example.com")
                    try await exercise(entry, app: app)
                }
                await server.stop()
            } catch {
                await server.stop()
                await CLIProcess.removeProfileDirectory(profile: profile)
                throw error
            }
        }

        @Test
        @MainActor func `cancelled removal keeps the contact and hiding it clears the selection`() async throws {
            let server = UIRosterLoopbackServer()
            let port = try await server.start()
            let profile = "inttest-ui-\(UUID().uuidString.prefix(8))"
            do {
                try await seed(profile: profile, port: port)
                try await AppAccessor.withAppAccessor(profile: profile) { app in
                    try await app.waitForElement(identifier: "contact-row-bob@example.com")
                    try await app.selectRow(identifier: "contact-row-bob@example.com")
                    try await app.pressKey(CGKeyCode(kVK_Delete), modifiers: .maskCommand)
                    try await app.clickConfirmationDialogButton(dialogText: "Remove Bob?", buttonLabel: "Cancel")
                    try await app.waitForElement(identifier: "contact-row-bob@example.com")
                    // The server acknowledges a removal without pushing it back, so Bob staying visible alone
                    // wouldn't prove Cancel sent nothing.
                    try await Task.sleep(for: .seconds(1))
                    #expect(await !server.mutated)

                    // Hiding the selected offline contact moves the table selection without a click.
                    try await app.pressKey(CGKeyCode(kVK_ANSI_H), modifiers: [.maskCommand, .maskShift])
                    try await app.waitForAbsence(identifier: "contact-row-bob@example.com")
                    try await app.pressKey(CGKeyCode(kVK_Delete), modifiers: .maskCommand)
                    try await Task.sleep(for: .seconds(1))
                    try await app.waitForSheetDismissed(timeout: .seconds(1))

                    try await app.pressKey(CGKeyCode(kVK_ANSI_H), modifiers: [.maskCommand, .maskShift])
                    try await app.waitForElement(identifier: "contact-row-bob@example.com")
                }
                await server.stop()
            } catch {
                await server.stop()
                await CLIProcess.removeProfileDirectory(profile: profile)
                throw error
            }
        }

        private func exercise(_ entry: String, app: AppAccessor) async throws {
            switch entry {
            case "add", "rejection", "script":
                try await app.pressKey(CGKeyCode(kVK_ANSI_D), modifiers: .maskCommand)
                try await app.waitForElement(identifier: "add-contact-jid-field")
                try await app.clearAndType("carol@example.com", intoIdentifier: "add-contact-jid-field")
                try await app.clickSheetButton(label: "Add Contact")
                if entry == "rejection" {
                    try await app.waitForElement(identifier: "add-contact-error")
                    #expect(try await app.value(identifier: "add-contact-error")?.isEmpty == false)
                    try await app.waitForElement(identifier: "add-contact-jid-field")
                    try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
                    try await app.waitForSheetDismissed()
                    return
                }
                try await app.waitForSheetDismissed()
            case "menu":
                try await app.rightClick(identifier: "contact-row-bob@example.com")
                try await app.contextMenuItem(title: "Remove Contact…")
                try await app.clickConfirmationDialogButton(dialogText: "Remove Bob?", buttonLabel: "Remove Contact")
            case "shortcut":
                try await app.selectRow(identifier: "contact-row-bob@example.com")
                try await app.pressKey(CGKeyCode(kVK_Delete), modifiers: .maskCommand)
                try await app.clickConfirmationDialogButton(dialogText: "Remove Bob?", buttonLabel: "Remove Contact")
            case "info", "script-info":
                try await app.rightClick(identifier: "contact-row-bob@example.com")
                try await app.contextMenuItem(title: "Get Info")
                try await app.waitForElement(identifier: "contact-info-remove")
                try await app.click(identifier: "contact-info-remove")
                try await app.clickSheetButton(label: "Remove Contact")
                try await app.waitForSheetDismissed()
            default:
                Issue.record("Unknown entry point")
            }
            let notice = entry.hasSuffix("info") ? "contact-info-roster-notice" : "roster-notice"
            try await app.waitForElement(identifier: notice)
            try await app.waitForDescendantButton(label: "Dismiss notice", underIdentifier: notice)
            if entry.hasPrefix("script") {
                #expect(try await app.runRosterNoticeScript(target: entry == "script-info" ? "info" : "contacts") == 0)
            } else {
                try await app.pressKey(CGKeyCode(kVK_Escape), modifiers: [])
            }
            try await app.waitForAbsence(identifier: notice)
        }

        private func seed(profile: String, port: UInt16) async throws {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Ducko-Dev-\(profile)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(for: ModelContainerFactory.schema, configurations: [ModelConfiguration(url: directory.appending(path: "default.store"))])
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: true, host: "127.0.0.1", port: Int(port), requireTLS: false, allowsPLAIN: true, createdAt: Date())
            try await store.saveAccount(account)
            FileCredentialStore(fileURL: directory.appending(path: "credentials.json")).savePassword("local-fixture", for: account.jid.description)
        }
    }
}
