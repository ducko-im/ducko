/// XEP-0428 fallback indication: marks the part of a message's body that only clients without support for the
/// feature it is `for` should show. Body positions count Unicode scalars (XEP-0426).
public struct FallbackIndication: Sendable, Equatable {
    /// The namespace of the feature the fallback stands in for.
    public let target: String
    /// The fallback part of the body, or nil when the whole body is fallback.
    public let bodyRange: Range<Int>?

    public init(for target: String, bodyRange: Range<Int>? = nil) {
        self.target = target
        self.bodyRange = bodyRange
    }

    /// Reads a `<fallback/>` element, or returns nil when it is malformed or marks none of the body. A fallback without
    /// children marks the whole body, and one that marks only the subject marks none of it. A `<body/>` without a range
    /// marks the whole body. Ranges must join into one span, because a body loses its fallback as one cut, such as a
    /// reply's quote (XEP-0461).
    init?(_ element: XMLElement) {
        guard let target = element.attribute("for") else { return nil }
        let parts = element.children(named: "body")
        guard !parts.isEmpty else {
            guard element.children(named: "subject").isEmpty else { return nil }
            self.init(for: target)
            return
        }
        var ranges: [Range<Int>] = []
        for part in parts {
            guard let startText = part.attribute("start"), let endText = part.attribute("end") else {
                self.init(for: target)
                return
            }
            guard let start = Int(startText), let end = Int(endText), start >= 0, start <= end else { return nil }
            ranges.append(start ..< end)
        }
        guard let span = Self.span(joining: ranges) else { return nil }
        self.init(for: target, bodyRange: span)
    }

    /// The one span `ranges` cover together, or nil when a gap separates them.
    private static func span(joining ranges: [Range<Int>]) -> Range<Int>? {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard var span = sorted.first else { return nil }
        for range in sorted.dropFirst() {
            guard range.lowerBound <= span.upperBound else { return nil }
            span = span.lowerBound ..< max(span.upperBound, range.upperBound)
        }
        return span
    }

    public var element: XMLElement {
        var fallback = XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": target])
        if let bodyRange {
            fallback.addChild(XMLElement(name: "body", attributes: ["start": String(bodyRange.lowerBound), "end": String(bodyRange.upperBound)]))
        }
        return fallback
    }

    /// The fallback part of `body`, or nil when it lies outside `body`.
    public func bodyRange(in body: String) -> Range<Int>? {
        let count = body.unicodeScalars.count
        guard let bodyRange else { return 0 ..< count }
        return bodyRange.upperBound <= count ? bodyRange : nil
    }
}

public extension XMPPMessage {
    /// The message's fallback indication for the feature `target`.
    func fallbackIndication(for target: String) -> FallbackIndication? {
        element.children(named: "fallback")
            .first { $0.namespace == XMPPNamespaces.fallbackIndication && $0.attribute("for") == target }
            .flatMap(FallbackIndication.init)
    }
}

package extension String {
    /// The text without the Unicode scalars at `offsets`.
    func removingUnicodeScalars(at offsets: Range<Int>) -> String {
        let scalars = Array(unicodeScalars)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<offsets.lowerBound])
        view.append(contentsOf: scalars[offsets.upperBound...])
        return String(view)
    }

    /// The text of the Unicode scalars at `offsets`.
    func unicodeScalars(at offsets: Range<Int>) -> String {
        String(String.UnicodeScalarView(Array(unicodeScalars)[offsets]))
    }
}
