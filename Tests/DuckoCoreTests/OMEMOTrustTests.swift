import Testing
@testable import DuckoCore

enum OMEMOTrustTests {
    struct TrustLevelTests {
        @Test(arguments: [
            (OMEMOTrustLevel.verified, false, true),
            (OMEMOTrustLevel.verified, true, true),
            (OMEMOTrustLevel.trusted, false, true),
            (OMEMOTrustLevel.trusted, true, true),
            (OMEMOTrustLevel.undecided, false, false),
            (OMEMOTrustLevel.undecided, true, true),
            (OMEMOTrustLevel.untrusted, false, false),
            (OMEMOTrustLevel.untrusted, true, false)
        ])
        func `is trusted for encryption with TOFU`(
            level: OMEMOTrustLevel, tofu: Bool, expected: Bool
        ) {
            let result = level.isTrustedForEncryption(trustOnFirstUse: tofu)
            #expect(result == expected)
        }

        @Test func `strict trust property`() {
            #expect(OMEMOTrustLevel.verified.isTrustedForEncryption)
            #expect(OMEMOTrustLevel.trusted.isTrustedForEncryption)
            #expect(!OMEMOTrustLevel.undecided.isTrustedForEncryption)
            #expect(!OMEMOTrustLevel.untrusted.isTrustedForEncryption)
        }
    }

    struct CollapseTests {
        private static func row(_ fingerprint: String, _ level: OMEMOTrustLevel, deviceID: UInt32 = 1) -> OMEMOTrust {
            OMEMOTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: deviceID, fingerprint: fingerprint, trustLevel: level)
        }

        private static func orderings(of rows: [OMEMOTrust]) -> [[OMEMOTrust]] {
            guard rows.count > 1 else { return [rows] }
            return rows.indices.flatMap { index in
                var rest = rows
                let first = rest.remove(at: index)
                return orderings(of: rest).map { [first] + $0 }
            }
        }

        @Test(arguments: [
            ([("", OMEMOTrustLevel.verified), ("f1", .trusted)], "f1", OMEMOTrustLevel.verified),
            ([("f1", .trusted), ("", .untrusted)], "f1", .untrusted),
            ([("f1", .verified), ("f2", .trusted)], "", .untrusted),
            ([("", .undecided), ("", .trusted)], "", .trusted),
            ([("f1", .trusted), ("f2", .trusted), ("f1", .trusted)], "", .untrusted),
            ([("f1", .undecided), ("", .trusted), ("f1", .verified)], "f1", .verified)
        ])
        func `Duplicate rows of a device collapse to one, the same in every order`(
            rows: [(String, OMEMOTrustLevel)], fingerprint: String, level: OMEMOTrustLevel
        ) {
            for ordering in Self.orderings(of: rows.map { Self.row($0.0, $0.1) }) {
                let collapsed = ordering.collapsingDuplicateDevices()
                #expect(collapsed.map(\.fingerprint) == [fingerprint])
                #expect(collapsed.map(\.trustLevel) == [level])
            }
        }

        @Test func `Rows of different devices stay apart, in the order each device first appears`() {
            let rows = [Self.row("f2", .trusted, deviceID: 2), Self.row("f1", .untrusted), Self.row("f2", .verified, deviceID: 2)]

            let collapsed = rows.collapsingDuplicateDevices()

            #expect(collapsed.map(\.deviceID) == [2, 1])
            #expect(collapsed.map(\.trustLevel) == [.verified, .untrusted])
        }
    }

    struct DeviceInfoTests {
        @Test func identifiable() {
            let info = OMEMODeviceInfo(
                peerJID: "alice@example.com",
                deviceID: 42,
                fingerprint: "abcd1234",
                trustLevel: .trusted
            )
            #expect(info.id == "alice@example.com-42")
        }
    }
}
