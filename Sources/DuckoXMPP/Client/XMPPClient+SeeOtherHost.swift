extension XMPPClient {
    /// Extracts host and optional port from a `<see-other-host>` stream error element.
    static func parseSeeOtherHost(from element: XMLElement) -> (String, UInt16?)? {
        guard let value = element.child(named: "see-other-host", namespace: XMPPNamespaces.streams)?.textContent,
              !value.isEmpty else { return nil }
        // IPv6: [host]:port
        if value.hasPrefix("["), let closeBracket = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex) ..< closeBracket])
            let afterBracket = value.index(after: closeBracket)
            if afterBracket < value.endIndex, value[afterBracket] == ":",
               let port = UInt16(value[value.index(after: afterBracket)...]) {
                return (host, port)
            }
            return (host, nil)
        }
        // host:port or host
        let parts = value.split(separator: ":", maxSplits: 1)
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) : nil
        return (host, port)
    }
}
