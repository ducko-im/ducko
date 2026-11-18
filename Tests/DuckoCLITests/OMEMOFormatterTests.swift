import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

/// Two stored Ed25519 fingerprints and the Curve25519 forms they display as, taken from the OMEMO 2 reference fixtures.
private let storedFingerprintA = "0fd5e4fad8f18fa13f85465f9dc312c5c17d0c8242439220b6db11a5498f3ae9"
private let displayFingerprintA = "d9f71a68 33945da8 bda259e2 9a179ad2 e5092fe1 4d7372af 800da323 3b16ce4f"
private let storedFingerprintB = "9f5686ae842998d832ae1b36d451824ca72c0ad9056f41d156720f5460533355"
private let displayFingerprintB = "9888eec5 6c2611ab d87a3f9a a6949aa2 ee28edb3 9ab47529 165f68e4 e1fe4844"

struct OMEMOFormatterTests {
    private let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: storedFingerprintA, trustLevel: .trusted)
    private let resetReport = OMEMOSessionResetReport(peerJID: "bob@example.com", devices: [
        .init(deviceID: 42, outcome: .rebuilt(needsTrusting: false)),
        .init(deviceID: 43, outcome: .keyChanged(previousFingerprint: storedFingerprintA, newFingerprint: storedFingerprintB)),
        .init(deviceID: 44, outcome: .failed("The connection was closed")),
        .init(deviceID: 45, outcome: .rebuilt(needsTrusting: true)),
        .init(deviceID: 46, outcome: .notListed)
    ])

    private func jsonObject(_ output: String) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    @Test func `plain device line shows id, display fingerprint and trust`() {
        #expect(PlainFormatter().formatOMEMODevice(device) == "  42  \(displayFingerprintA)  [trusted]")
    }

    @Test func `plain device line marks a missing fingerprint`() {
        let bare = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 7, fingerprint: "", trustLevel: .undecided)
        #expect(PlainFormatter().formatOMEMODevice(bare) == "  7  (no fingerprint)  [undecided]")
    }

    @Test func `json device is structured with the raw and display fingerprints`() throws {
        let object = try jsonObject(JSONFormatter().formatOMEMODevice(device))
        #expect(object == [
            "type": "omemo_device", "jid": "bob@example.com", "deviceID": "42",
            "fingerprint": storedFingerprintA, "displayFingerprint": displayFingerprintA, "trust": "trusted"
        ])
    }

    @Test func `json fingerprint keeps the raw hex and adds the display form`() throws {
        let object = try jsonObject(JSONFormatter().formatOMEMOFingerprint(storedFingerprintA))
        #expect(object == ["type": "omemo_fingerprint", "fingerprint": storedFingerprintA, "displayFingerprint": displayFingerprintA])
    }

    @Test(arguments: [(OMEMOTrustLevel.trusted, "Trusted"), (.untrusted, "Untrusted")])
    func `trust change reads in every format`(trustLevel: OMEMOTrustLevel, verb: String) throws {
        #expect(PlainFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel) == "\(verb) device 42 for bob@example.com.")
        #expect(ANSIFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel).contains("\(verb) device 42 for bob@example.com."))
        let object = try jsonObject(JSONFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel))
        #expect(object == ["type": "omemo_trust", "jid": "bob@example.com", "deviceID": "42", "trust": trustLevel.rawValue])
    }

    @Test func `a session reset lists each device's outcome with both keys of a changed one in their display form`() {
        let expected = [
            "Reset the OMEMO sessions with bob@example.com:",
            "  Device 42 has a new session",
            "  Device 43 changed its key from \(displayFingerprintA) to \(displayFingerprintB) and needs trusting",
            "  Device 44 could not be reset: The connection was closed",
            "  Device 45 has a new session and needs trusting",
            "  Device 46 is not on the device list, so its session was discarded"
        ]
        #expect(PlainFormatter().formatOMEMOSessionReset(resetReport) == expected.joined(separator: "\n"))
        let ansi = ANSIFormatter().formatOMEMOSessionReset(resetReport)
        #expect(expected.allSatisfy { ansi.contains($0.trimmingCharacters(in: .whitespaces)) })
    }

    @Test func `json session reset carries each device's outcome and the raw and display keys of a changed one`() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(JSONFormatter().formatOMEMOSessionReset(resetReport).utf8)) as? NSDictionary)
        let expected: NSDictionary = [
            "type": "omemo_session_reset",
            "jid": "bob@example.com",
            "devices": [
                ["deviceID": "42", "outcome": "rebuilt", "needsTrusting": "false"],
                [
                    "deviceID": "43", "outcome": "key_changed",
                    "previousFingerprint": storedFingerprintA, "previousDisplayFingerprint": displayFingerprintA,
                    "newFingerprint": storedFingerprintB, "newDisplayFingerprint": displayFingerprintB
                ],
                ["deviceID": "44", "outcome": "failed", "error": "The connection was closed"],
                ["deviceID": "45", "outcome": "rebuilt", "needsTrusting": "true"],
                ["deviceID": "46", "outcome": "not_listed"]
            ]
        ]
        #expect(object == expected)
    }
}

struct OMEMOVerifyFingerprintTests {
    private let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: storedFingerprintA, trustLevel: .trusted)

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
