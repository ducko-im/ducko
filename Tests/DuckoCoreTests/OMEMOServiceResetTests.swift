import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!

/// A reset of the encryption sessions with a contact, run against bob's device 200 over the encrypted-send harness, or
/// with the account's other devices.
@MainActor
struct OMEMOServiceResetTests {
    /// The notes in the chat with bob.
    private func notes(in harness: EncryptedSendHarness) async throws -> [TimelineNote] {
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        return try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil)
    }

    private func storedSession(_ data: UInt8, deviceID: UInt32 = 200) -> OMEMOStoredSession {
        OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: deviceID,
            sessionData: Data([data]), associatedData: Data([data])
        )
    }

    /// A second service over the harness's account and store, with trust on first use as given, whose guard the
    /// harness's module uses as a module the service builds would.
    private func guardedService(trustOnFirstUse: Bool = true, in harness: EncryptedSendHarness) async throws -> OMEMOService {
        let service = OMEMOService(omemoStore: harness.omemoStore, trustOnFirstUse: { trustOnFirstUse })
        service.setAccountService(harness.accountService)
        service.setChatService(harness.chatService)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.configureTrustGuard(service.trustGuard(forAccountJID: testJIDString))
        return service
    }

    private func sentEncrypted(in harness: EncryptedSendHarness) async -> Bool {
        await harness.transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<encrypted") }
    }

    @Test func `A reset builds a new session with each listed device, sends it an empty message, stores it, and notes the reset`() async throws {
        let harness = try await EncryptedSendHarness.connect()

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report == OMEMOSessionResetReport(peerJID: contact.description, devices: [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))]))
        #expect(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") } != nil)
        let sessions = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(sessions.map(\.peerDeviceID) == [200])
        let note = try #require(await notes(in: harness).first)
        #expect(note.kind == .sessionsReset)
        #expect(note.detail == nil)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset that finds a device's key changed holds and stores the new key as untrusted, deletes the session, and notes both keys`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        // The harness builds its module without the service, which wires the account's guard into the modules it builds.
        let trustGuard = harness.omemoService.trustGuard(forAccountJID: testJIDString)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.configureTrustGuard(trustGuard)
        let previous = String(repeating: "ab", count: 32)
        trustGuard.merge(
            [OMEMOTrustGuard.StoredTrust(peer: contact, deviceID: 200, fingerprint: previous, decision: .granted)],
            loadedAfter: trustGuard.currentStamp()
        )
        try await harness.omemoStore.saveSession(storedSession(1))
        let new = try omemoFingerprint(of: OMEMOIdentityKeyPair(rawRepresentation: harness.bob.identityKeyRaw).publicKeyBytes)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 200, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .keyChanged(previousFingerprint: previous, newFingerprint: new))])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == new)
        #expect(trustGuard.refuses(SessionKey(jid: contact, deviceID: 200)))
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(new) untrusted"])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains(OMEMODeviceInfo.formatFingerprint(previous)))
        #expect(detail.contains(OMEMODeviceInfo.formatFingerprint(new)))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A rebuilt device that is not trusted for encryption is reported and noted as needing trusting`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let service = try await guardedService(trustOnFirstUse: false, in: harness)
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .undecided))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: true))])
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains("needs trusting"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset takes in an untrust another process stored, and only discards the device's session`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let service = try await guardedService(in: harness)
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .untrusted))
        try await harness.omemoStore.saveSession(storedSession(1))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .discarded)])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        #expect(await !sentEncrypted(in: harness))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming a device that is not on the list only deletes its stored session and sends it nothing`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        #expect(await !sentEncrypted(in: harness))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming a device that is not on the list drops the module's session, so a later save does not store it again`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
        let bobsSession = try #require(module.exportSession(jid: contact, deviceID: 200))
        module.restoreSessions([OMEMOModule.StoredSessionEntry(
            jid: contact, deviceID: 999, sessionData: bobsSession.sessionData, associatedData: bobsSession.associatedData
        )])
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        #expect(!module.allSessionEntries().contains { $0.jid == contact && $0.deviceID == 999 })
        await harness.omemoService.saveModuleSessions(module: module, accountID: harness.accountID)
        #expect(try await !harness.omemoStore.loadSessions(for: testJIDString).contains { $0.peerDeviceID == 999 })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A device whose reset fails is reported as failed, and the note says so`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let failure = XMPPClientError.sendFailed("The connection was closed")
        await harness.transport.failNextSend(matching: "<encrypted", error: failure)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .failed(failure.localizedDescription))])
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains("could not be reset"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset of the account's own devices rebuilds the session with each other device, leaves this one out, and notes nothing`() async throws {
        let harness = try await EncryptedSendHarness.connect(otherOwnDevices: [300])
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: testJIDString, deviceID: 300, fingerprint: "", trustLevel: .trusted))

        let report = try await harness.omemoService.resetSessions(peerJID: testJIDString, deviceID: nil, accountID: harness.accountID)

        #expect(report == OMEMOSessionResetReport(peerJID: testJIDString, devices: [.init(deviceID: 300, outcome: .rebuilt(needsTrusting: false))]))
        let sent = await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        #expect(sent?.contains("to=\"\(testJIDString)\"") == true)
        let sessions = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(sessions.map { "\($0.peerJID) \($0.peerDeviceID)" } == ["\(testJIDString) 300"])
        #expect(await harness.transcripts.notes.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming this device is refused`() async throws {
        let harness = try await EncryptedSendHarness.connect(otherOwnDevices: [300])

        let error = await #expect(throws: OMEMOServiceError.self) {
            _ = try await harness.omemoService.resetSessions(peerJID: testJIDString, deviceID: 100, accountID: harness.accountID)
        }

        if case .thisDeviceNotResettable? = error {} else { Issue.record("Expected this device to be refused, got \(String(describing: error))") }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
