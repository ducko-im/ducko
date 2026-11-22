import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct TLSInfoOutputTests {
    @Test(arguments: [nil, "TLS_AES_128_GCM_SHA256"] as [String?])
    func `TLS cipher output preserves unavailable and known values`(cipher: String?) throws {
        let info = TLSInfo(protocolVersion: "TLS 1.3", cipherSuite: cipher, certificateSubject: "localhost")
        let expected = cipher ?? "Not available"
        #expect(PlainFormatter().formatTLSInfo(info).contains(expected))
        #expect(ANSIFormatter().formatTLSInfo(info).contains(expected))
        let output = JSONFormatter().formatTLSInfo(info)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "tls_info")
        #expect(json["tls_version"] as? String == "TLS 1.3")
        #expect(json["subject"] as? String == "localhost")
        if let cipher {
            #expect(json["cipher_suite"] as? String == cipher)
        } else {
            #expect(json["cipher_suite"] is NSNull)
        }
    }
}
