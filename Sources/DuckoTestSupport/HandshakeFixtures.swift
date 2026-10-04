import Foundation

// MARK: - Shared Handshake XML Constants

// Byte-identical across DuckoCoreTests and DuckoXMPPTests, so they live here rather than being duplicated
// per target. Target-specific fixtures (post-auth features with SM, the SASL2/ISR set, the divergent
// `testBindResult`) stay in their own target's helpers.

/// Standard stream opening from server.
public let testServerStreamOpen =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"

/// Features offering only PLAIN auth (no TLS).
public let testFeaturesNoTLS = """
<features xmlns='http://etherx.jabber.org/streams'>\
<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
<mechanism>PLAIN</mechanism>\
</mechanisms>\
</features>
"""

/// Post-auth features with bind only.
public let testFeaturesBind = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
</features>
"""

// MARK: - IQ ID Extraction

/// Extracts the IQ `id` attribute value from a raw XML string. `XMLElement.xmlString` sorts attributes
/// alphabetically, so an outer iq's `id` always precedes any inner element's.
public func extractIQID(from xmlString: String) -> String? {
    guard let idRange = xmlString.range(of: "id=\""),
          let endRange = xmlString[idRange.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(xmlString[idRange.upperBound ..< endRange])
}

/// Extracts the IQ `id` attribute value from captured `MockTransport.sentBytes`.
public func extractIQID(from bytes: [UInt8]) -> String? {
    extractIQID(from: String(decoding: bytes, as: UTF8.self))
}

/// Extracts the `queryid` attribute value from a raw archive query IQ.
public func extractQueryID(from xmlString: String) -> String? {
    guard let range = xmlString.range(of: "queryid=\""),
          let endRange = xmlString[range.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(xmlString[range.upperBound ..< endRange])
}
