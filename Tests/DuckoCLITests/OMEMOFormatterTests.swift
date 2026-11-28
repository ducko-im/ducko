import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

/// Two stored Ed25519 fingerprints and the Curve25519 forms they display as, taken from the OMEMO 2 reference fixtures.
private let storedFingerprintA = "0fd5e4fad8f18fa13f85465f9dc312c5c17d0c8242439220b6db11a5498f3ae9"
private let displayFingerprintA = "d9f71a68 33945da8 bda259e2 9a179ad2 e5092fe1 4d7372af 800da323 3b16ce4f"
private let storedFingerprintB = "9f5686ae842998d832ae1b36d451824ca72c0ad9056f41d156720f5460533355"
private let displayFingerprintB = "9888eec5 6c2611ab d87a3f9a a6949aa2 ee28edb3 9ab47529 165f68e4 e1fe4844"

struct OMEMOFormatterTests {
    private let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: storedFingerprintA, trustLevel: .trusted, versions: [.omemo2])
    private let resetReport = OMEMOSessionResetReport(peerJID: "bob@example.com", devices: [
        .init(deviceID: 42, outcome: .rebuilt(needsTrusting: false)),
        .init(deviceID: 43, outcome: .keyChanged(previousFingerprint: storedFingerprintA, newFingerprint: storedFingerprintB)),
        .init(deviceID: 44, outcome: .failed("The connection was closed")),
        .init(deviceID: 45, outcome: .rebuilt(needsTrusting: true)),
        .init(deviceID: 46, outcome: .notListed),
        .init(deviceID: 47, outcome: .discarded),
        .init(deviceID: 48, outcome: .noBundle),
        .init(deviceID: 49, outcome: .rebuiltKeyRefused(needsTrusting: false, newFingerprint: storedFingerprintB)),
        .init(deviceID: 50, outcome: .rebuiltKeyRefused(needsTrusting: true, newFingerprint: storedFingerprintB))
    ])

    private func jsonObject(_ output: String) throws -> [String: String] {
        expectSnakeCaseKeys(output)
        return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    @Test func `plain device line shows id, display fingerprint and trust`() {
        #expect(PlainFormatter().formatOMEMODevice(device) == "  42  \(displayFingerprintA)  [trusted]  OMEMO 2")
    }

    @Test func `plain device line marks a missing fingerprint`() {
        let bare = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 7, fingerprint: "", trustLevel: .undecided, versions: [.omemo2])
        #expect(PlainFormatter().formatOMEMODevice(bare) == "  7  (no fingerprint)  [undecided]  OMEMO 2")
    }

    /// OMEMO 2 comes first whatever the set's order, and a device whose lists are not known names no version.
    @Test(arguments: [
        (Set<OMEMOWireFormat>([.legacy, .omemo2]), "  OMEMO 2, legacy", ["omemo2", "legacy"]),
        (Set<OMEMOWireFormat>([.legacy]), "  legacy", ["legacy"]),
        (Set<OMEMOWireFormat>(), "", [])
    ])
    func `a device line names the versions the device speaks`(versions: Set<OMEMOWireFormat>, text: String, json: [String]) throws {
        let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: storedFingerprintA, trustLevel: .trusted, versions: versions)

        #expect(PlainFormatter().formatOMEMODevice(device) == "  42  \(displayFingerprintA)  [trusted]\(text)")
        #expect(ANSIFormatter().formatOMEMODevice(device).hasSuffix("[trusted]\u{001B}[0m\(text)"))
        let output = JSONFormatter().formatOMEMODevice(device)
        expectSnakeCaseKeys(output)
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["versions"] as? [String] == json)
    }

    @Test func `json device is structured with the raw and display fingerprints`() throws {
        let output = JSONFormatter().formatOMEMODevice(device)
        expectSnakeCaseKeys(output)
        var object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object.removeValue(forKey: "versions") as? [String] == ["omemo2"])
        #expect(object as? [String: String] == [
            "type": "omemo_device", "jid": "bob@example.com", "device_id": "42",
            "fingerprint": storedFingerprintA, "display_fingerprint": displayFingerprintA, "trust": "trusted"
        ])
    }

    @Test func `json fingerprint keeps the raw hex and adds the display form`() throws {
        let object = try jsonObject(JSONFormatter().formatOMEMOFingerprint(storedFingerprintA))
        #expect(object == ["type": "omemo_fingerprint", "fingerprint": storedFingerprintA, "display_fingerprint": displayFingerprintA])
    }

    @Test func `json session established names a legacy session's version and its key in the legacy stored form`() throws {
        let peer = try #require(BareJID.parse("bob@example.com"))
        let event = XMPPEvent.omemoSessionEstablished(jid: peer, deviceID: 42, version: .legacy, identityKey: [0, 0xAB, 0xFF], consumedPreKeyID: nil)

        let object = try jsonObject(#require(JSONFormatter().formatEvent(event, accountID: UUID())))

        #expect(object["version"] == "legacy")
        #expect(object["fingerprint"] == "0500abff")
    }

    @Test(arguments: [(OMEMOTrustLevel.trusted, "Trusted"), (.untrusted, "Untrusted")])
    func `trust change reads in every format`(trustLevel: OMEMOTrustLevel, verb: String) throws {
        #expect(PlainFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel) == "\(verb) device 42 for bob@example.com.")
        #expect(ANSIFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel).contains("\(verb) device 42 for bob@example.com."))
        let object = try jsonObject(JSONFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel))
        #expect(object == ["type": "omemo_trust", "jid": "bob@example.com", "device_id": "42", "trust": trustLevel.rawValue])
    }

    @Test func `a session reset lists each device's outcome with the keys of a changed or refused one in their display form`() {
        let expected = [
            "Reset the OMEMO sessions with bob@example.com:",
            "  Device 42 has a new session",
            "  Device 43 changed its key from \(displayFingerprintA) to \(displayFingerprintB) and needs trusting",
            "  Device 44 could not be reset: The connection was closed",
            "  Device 45 has a new session and needs trusting",
            "  Device 46 is not on the device list, so its session was discarded",
            "  Device 47 is marked untrusted, so its session was discarded",
            "  Device 48 publishes no usable keys, so its session was discarded",
            "  Device 49 has a new session. It also offered a different key (\(displayFingerprintB)), which Ducko refused",
            "  Device 50 has a new session and needs trusting. It also offered a different key (\(displayFingerprintB)), which Ducko refused"
        ]
        #expect(PlainFormatter().formatOMEMOSessionReset(resetReport) == expected.joined(separator: "\n"))
        let ansi = ANSIFormatter().formatOMEMOSessionReset(resetReport)
        #expect(expected.allSatisfy { ansi.contains($0.trimmingCharacters(in: .whitespaces)) })
    }

    @Test func `json session reset carries each device's outcome and the raw and display keys of a changed or refused one`() throws {
        let output = JSONFormatter().formatOMEMOSessionReset(resetReport)
        expectSnakeCaseKeys(output)
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? NSDictionary)
        let expected: NSDictionary = [
            "type": "omemo_session_reset",
            "jid": "bob@example.com",
            "devices": [
                ["device_id": "42", "outcome": "rebuilt", "needs_trusting": "false"],
                [
                    "device_id": "43", "outcome": "key_changed",
                    "previous_fingerprint": storedFingerprintA, "previous_display_fingerprint": displayFingerprintA,
                    "new_fingerprint": storedFingerprintB, "new_display_fingerprint": displayFingerprintB
                ],
                ["device_id": "44", "outcome": "failed", "error": "The connection was closed"],
                ["device_id": "45", "outcome": "rebuilt", "needs_trusting": "true"],
                ["device_id": "46", "outcome": "not_listed"],
                ["device_id": "47", "outcome": "discarded"],
                ["device_id": "48", "outcome": "no_bundle"],
                [
                    "device_id": "49", "outcome": "rebuilt_key_refused", "needs_trusting": "false",
                    "new_fingerprint": storedFingerprintB, "new_display_fingerprint": displayFingerprintB
                ],
                [
                    "device_id": "50", "outcome": "rebuilt_key_refused", "needs_trusting": "true",
                    "new_fingerprint": storedFingerprintB, "new_display_fingerprint": displayFingerprintB
                ]
            ]
        ]
        #expect(object == expected)
    }
}

struct OMEMOVerifyFingerprintTests {
    private let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: storedFingerprintA, trustLevel: .trusted, versions: [.omemo2])

    @Test(arguments: [
        (displayFingerprintA, true),
        (displayFingerprintA.uppercased(), true),
        (displayFingerprintA.replacingOccurrences(of: " ", with: ""), true),
        (storedFingerprintA, true),
        (displayFingerprintB, false),
        (storedFingerprintB, false),
        (String(displayFingerprintA.dropLast()), false)
    ])
    func `a typed fingerprint matches the device's key in its displayed or stored form`(typed: String, names: Bool) {
        #expect(device.matchesFingerprint(typed) == names)
    }
}
