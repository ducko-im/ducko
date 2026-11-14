import NIOCore
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func line(_ text: String) -> ByteBuffer {
    ByteBuffer(string: text)
}

/// Exporter secrets and the `tls-exporter` bindings OpenSSL's `-keymatexport EXPORTER-Channel-Binding
/// -keymatexportlen 32` gave for the same TLS 1.3 handshakes: one with a SHA-256 suite and one with SHA-384.
private let sha256SecretHex = "abda2b40bf3a23c07d2bf6d8df1ed20c0eeda907966877ab9f6f50f46c5d1d18"
private let sha256Secret = bytes(sha256SecretHex)
private let sha256Binding = bytes("e2533872c44b8a037c73755fa65d34ad95cfb9ff11f932e9c7796d753429638a")
private let sha384Secret = bytes("0e77c08bbcf10cc8f9a1fcefcb252b565ae0a4de61d0cd8eb1b474b33699d6b5443e2f6b749f28a12025607c7f9f2633")
private let sha384Binding = bytes("a23d650f7ff8c48e06560cdb9e558f353bc249f922b28e15e2dd570d2a16b387")

private let clientRandom = String(repeating: "0a", count: 32)

// MARK: - Tests

enum TLSExporterTests {
    struct Derivation {
        @Test(arguments: [(sha256Secret, sha256Binding), (sha384Secret, sha384Binding)])
        func `Matches OpenSSL's exported channel binding`(secret: [UInt8], expected: [UInt8]) {
            #expect(tlsExporterChannelBinding(exporterSecret: secret) == expected)
        }

        @Test(arguments: [0, 31, 40, 64])
        func `A secret of no TLS 1.3 hash's length gives no binding`(count: Int) {
            #expect(tlsExporterChannelBinding(exporterSecret: Array(repeating: 0x11, count: count)) == nil)
        }
    }

    struct KeyLogParsing {
        @Test(arguments: [
            "CLIENT_HANDSHAKE_TRAFFIC_SECRET", "SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0",
            "CLIENT_RANDOM", "EXPORTER_SECRETS", "EXPORTER"
        ])
        func `Lines for other secrets are not exporter lines`(label: String) {
            #expect(exporterSecret(fromKeyLogLine: line("\(label) \(clientRandom) \(sha256SecretHex)\n")) == .notExporter)
        }

        @Test(arguments: ["", "\n"])
        func `A well-formed exporter line gives its secret`(ending: String) {
            let parsed = exporterSecret(fromKeyLogLine: line("EXPORTER_SECRET \(clientRandom) \(sha256SecretHex)\(ending)"))
            #expect(parsed == .exporter(sha256Secret))
        }

        @Test
        func `The secret's length is left to the derivation`() {
            let secret = String(repeating: "ab", count: 40)
            #expect(exporterSecret(fromKeyLogLine: line("EXPORTER_SECRET \(clientRandom) \(secret)")) == .exporter(Array(repeating: 0xAB, count: 40)))
        }

        @Test(arguments: [
            "EXPORTER_SECRET", "EXPORTER_SECRET \(String(repeating: "0", count: 62)) \(sha256SecretHex)",
            "EXPORTER_SECRET \(String(repeating: "0", count: 66)) \(sha256SecretHex)",
            "EXPORTER_SECRET \(String(repeating: "g", count: 64)) \(sha256SecretHex)", "EXPORTER_SECRET \(clientRandom) ",
            "EXPORTER_SECRET \(clientRandom) abc", "EXPORTER_SECRET \(clientRandom) \(sha256SecretHex.dropLast())x",
            "EXPORTER_SECRET \(clientRandom) \(sha256SecretHex) extra", "EXPORTER_SECRET  \(clientRandom) \(sha256SecretHex)",
            "EXPORTER_SECRET \(clientRandom) \(sha256SecretHex)\n\n"
        ])
        func `An exporter line of another shape is malformed`(text: String) {
            #expect(exporterSecret(fromKeyLogLine: line(text)) == .malformed)
        }
    }

    struct Capture {
        @Test(arguments: [
            ([KeyLogExporterLine.notExporter], ExporterSecretCapture.none),
            ([.exporter(sha256Secret)], .captured(sha256Secret)),
            ([.notExporter, .exporter(sha256Secret), .notExporter], .captured(sha256Secret)),
            ([.exporter(sha256Secret), .exporter(sha256Secret)], .unusable),
            ([.malformed], .unusable),
            ([.exporter(sha256Secret), .malformed], .unusable),
            ([.malformed, .exporter(sha256Secret)], .unusable),
            ([.malformed, .notExporter], .unusable)
        ])
        func `Only a single well-formed exporter line is captured`(lines: [KeyLogExporterLine], expected: ExporterSecretCapture) {
            var capture = ExporterSecretCapture.none
            for line in lines {
                capture.record(line)
            }
            #expect(capture == expected)
        }
    }

    struct Assembly {
        @Test(arguments: [
            ExporterSecretCapture.none, .unusable, .captured(Array(repeating: 0x11, count: 40))
        ])
        func `A TLS 1.3 handshake without a usable secret keeps only the end-point binding`(capture: ExporterSecretCapture) {
            #expect(handshakeBindings(serverEndPoint: endPointBinding, capture: capture, isTLS13: true) == [.tlsServerEndPoint: endPointBinding])
        }

        @Test
        func `A TLS 1.3 handshake with one secret adds the exporter binding`() {
            let bindings = handshakeBindings(serverEndPoint: endPointBinding, capture: .captured(sha256Secret), isTLS13: true)
            #expect(bindings == [.tlsServerEndPoint: endPointBinding, .tlsExporter: sha256Binding])
        }

        @Test
        func `A TLS 1.2 handshake never derives an exporter binding`() {
            let bindings = handshakeBindings(serverEndPoint: endPointBinding, capture: .captured(sha256Secret), isTLS13: false)
            #expect(bindings == [.tlsServerEndPoint: endPointBinding])
        }
    }
}
