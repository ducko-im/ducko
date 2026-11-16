import Testing
@testable import DuckoXMPP

private let bound = ChannelBindingMode.bound(type: .tlsExporter, data: exporterBinding)

private func taskData(_ salt: String) throws -> XMLElement {
    try stanza("<task-data xmlns='urn:xmpp:sasl:2'>\(salt)</task-data>")
}

enum SCRAMUpgradeTests {
    struct Selection {
        @Test(arguments: [
            (["UPGR-SCRAM-SHA-256"], SCRAMMechanismName.sha1Plus, SCRAMHash?.some(.sha256)),
            (["UPGR-SCRAM-SHA-256", "UPGR-SCRAM-SHA-512"], SCRAMMechanismName.sha1Plus, .sha512),
            (["UPGR-SCRAM-SHA-256"], SCRAMMechanismName.sha256Plus, nil),
            (["UPGR-SCRAM-SHA-1"], SCRAMMechanismName.sha256Plus, nil),
            (["UPGR-SCRAM-SHA-256-PLUS", "UPGR-SCRAM-SHA-384", "HT-SHA-256"], SCRAMMechanismName.sha1Plus, nil)
        ])
        func `A bound sign-in picks the strongest offered upgrade stronger than its mechanism`(
            offered: [String], selected: String, expected: SCRAMHash?
        ) {
            #expect(selectSCRAMUpgrade(offered: Set(offered), selectedMechanism: selected, channelBinding: bound) == expected)
        }

        @Test(arguments: [ChannelBindingMode.none, .clientSupportsButNotUsed])
        func `An unbound sign-in picks no upgrade`(binding: ChannelBindingMode) {
            #expect(selectSCRAMUpgrade(offered: ["UPGR-SCRAM-SHA-256"], selectedMechanism: SCRAMMechanismName.sha1, channelBinding: binding) == nil)
        }
    }

    struct Salt {
        @Test
        func `The salt and iteration count are read, with whitespace around the base64`() throws {
            let parsed = try parseSCRAMUpgradeSalt(taskData(
                "<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='4096'>\n  \(capturedUpgradeSalt)\n</salt>"
            ), hash: .sha256).get()
            #expect(parsed.salt == Base64.decode(capturedUpgradeSalt))
            #expect(parsed.iterations == 4096)
        }

        @Test(arguments: [
            ("", SASLAuthError.malformedUpgradeTask),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='4096'/>", .malformedUpgradeTask),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='4096'>  </salt>", .malformedUpgradeTask),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0'>\(capturedUpgradeSalt)</salt>", .malformedUpgradeTask),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='many'>\(capturedUpgradeSalt)</salt>", .malformedUpgradeTask),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='4095'>\(capturedUpgradeSalt)</salt>", .iterationCountTooLow(4095)),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='600001'>\(capturedUpgradeSalt)</salt>", .iterationCountTooHigh(600_001)),
            ("<salt xmlns='urn:xmpp:scram-upgrade:0' iterations='4096'>not base64!</salt>", .invalidBase64)
        ])
        func `A salt that can't be used fails`(salt: String, error: SASLAuthError) throws {
            let element = try taskData(salt)
            #expect(throws: error) { try parseSCRAMUpgradeSalt(element, hash: .sha256).get() }
        }
    }

    /// One case at a time, so the 512-bit key derivations don't push other suites' sign-in deadlines past their limit.
    @Suite(.serialized)
    struct SaltedPassword {
        @Test(arguments: [
            (SCRAMHash.sha1, "P2uFuYSUXcoR9EsCR1qqyeN3c44="),
            (.sha256, capturedUpgradeSHA256Hash),
            (.sha512, "g9qAwPT9+Kc4R6xF/5nNSP2r5zjxwN+u8koAkVoWN6HoxGjBniU99OJ0zA4WO3FK3uLeRAvLwaZ1LGOhAkpLsw=="),
            (.sha3_512, "QsPlB0l0Ue/8GOl7o4hvuZQR0oiuzBTZUCw4oN368qzd7cX8Uob0xTKr+/ntn8p6dRsp/H3C935ShauqR6MuWw==")
        ])
        func `Matches Python's hashlib`(hash: SCRAMHash, expected: String) throws {
            let salt = try #require(Base64.decode(capturedUpgradeSalt))
            #expect(Base64.encode(hash.saltedPassword(password: Array("pencil".utf8), salt: salt, iterations: 4096)) == expected)
        }
    }
}
