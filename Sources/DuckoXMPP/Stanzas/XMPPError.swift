/// XMPP stream-level errors per RFC 6120 §4.9.3.
public enum XMPPStreamError: String, Sendable {
    case badFormat = "bad-format"
    case badNamespacePrefix = "bad-namespace-prefix"
    case conflict
    case connectionTimeout = "connection-timeout"
    case hostGone = "host-gone"
    case hostUnknown = "host-unknown"
    case improperAddressing = "improper-addressing"
    case internalServerError = "internal-server-error"
    case invalidFrom = "invalid-from"
    case invalidNamespace = "invalid-namespace"
    case invalidXML = "invalid-xml"
    case notAuthorized = "not-authorized"
    case notWellFormed = "not-well-formed"
    case policyViolation = "policy-violation"
    case remoteConnectionFailed = "remote-connection-failed"
    case reset
    case resourceConstraint = "resource-constraint"
    case restrictedXML = "restricted-xml"
    case seeOtherHost = "see-other-host"
    case systemShutdown = "system-shutdown"
    case undefinedCondition = "undefined-condition"
    case unsupportedEncoding = "unsupported-encoding"
    case unsupportedFeature = "unsupported-feature"
    case unsupportedStanzaType = "unsupported-stanza-type"
    case unsupportedVersion = "unsupported-version"

    public var displayText: String {
        switch self {
        case .conflict: "The connection conflicts with another connection"
        case .connectionTimeout: "The connection timed out"
        case .hostGone: "The server no longer serves this domain"
        case .hostUnknown: "The server does not recognize this domain"
        case .internalServerError: "The server encountered an internal problem"
        case .notAuthorized: "The server did not authorize the connection"
        case .policyViolation: "The connection violates a server policy"
        case .remoteConnectionFailed: "The server could not reach a required remote service"
        case .reset: "The server requires a new connection"
        case .resourceConstraint: "The server lacks resources for this connection"
        case .seeOtherHost: "The server requested a redirect"
        case .systemShutdown: "The server is shutting down"
        case .undefinedCondition: "The server closed the connection"
        case .improperAddressing, .invalidFrom: "The server rejected the addressing (\(rawValue))"
        case .badFormat, .badNamespacePrefix, .invalidNamespace, .invalidXML, .notWellFormed, .restrictedXML, .unsupportedEncoding:
            "The server rejected the XML data (\(rawValue))"
        case .unsupportedFeature, .unsupportedStanzaType, .unsupportedVersion:
            "The connection uses unsupported protocol features (\(rawValue))"
        }
    }

    /// Parses a stream error condition from a `<stream:error>` element.
    public static func parse(from element: XMLElement) -> XMPPStreamError? {
        for case let .element(child) in element.children
            where child.namespace == XMPPNamespaces.streams {
            if let condition = XMPPStreamError(rawValue: child.name) {
                return condition
            }
        }
        return nil
    }
}

// MARK: - XMPPStanzaError

/// XMPP stanza-level error per RFC 6120 §8.3.3.
public struct XMPPStanzaError: Sendable, Error {
    public let errorType: ErrorType
    public let condition: Condition
    public let text: String?
    /// The application-specific condition: the `<error>` child qualified by a namespace other than the stanzas one.
    public let applicationCondition: XMLElement?

    public init(errorType: ErrorType, condition: Condition, text: String? = nil, applicationCondition: XMLElement? = nil) {
        self.errorType = errorType
        self.condition = condition
        self.text = text
        self.applicationCondition = applicationCondition
    }

    /// Human-readable description: prefers non-blank `text`, falls back to a phrase for `condition`.
    public var displayText: String {
        if let text, !text.allSatisfy(\.isWhitespace) { text } else { condition.displayText }
    }

    /// Parses a stanza error from an `<error>` child element.
    public static func parse(from element: XMLElement?) -> XMPPStanzaError? {
        guard let element else { return nil }

        let errorType = element.attribute("type").flatMap(ErrorType.init(rawValue:)) ?? .cancel

        var condition: Condition?
        var text: String?
        var applicationCondition: XMLElement?
        for case let .element(child) in element.children {
            if child.namespace == XMPPNamespaces.stanzas {
                if child.name == "text" {
                    text = child.textContent
                } else if let parsed = Condition(rawValue: child.name) {
                    condition = parsed
                }
            } else if child.namespace != element.namespace, applicationCondition == nil {
                applicationCondition = child
            }
        }

        guard let condition else { return nil }
        return XMPPStanzaError(errorType: errorType, condition: condition, text: text, applicationCondition: applicationCondition)
    }

    public enum ErrorType: String, Sendable {
        case auth
        case cancel
        case `continue`
        case modify
        case wait
    }

    public enum Condition: String, Sendable {
        case badRequest = "bad-request"
        case conflict
        case featureNotImplemented = "feature-not-implemented"
        case forbidden
        case gone
        case internalServerError = "internal-server-error"
        case itemNotFound = "item-not-found"
        case jidMalformed = "jid-malformed"
        case notAcceptable = "not-acceptable"
        case notAllowed = "not-allowed"
        case notAuthorized = "not-authorized"
        case policyViolation = "policy-violation"
        case recipientUnavailable = "recipient-unavailable"
        case redirect
        case registrationRequired = "registration-required"
        case remoteServerNotFound = "remote-server-not-found"
        case remoteServerTimeout = "remote-server-timeout"
        case resourceConstraint = "resource-constraint"
        case serviceUnavailable = "service-unavailable"
        case subscriptionRequired = "subscription-required"
        case undefinedCondition = "undefined-condition"
        case unexpectedRequest = "unexpected-request"

        public var displayText: String {
            switch self {
            case .badRequest: "The request was malformed"
            case .conflict: "The request conflicts with an existing resource"
            case .featureNotImplemented: "The recipient does not support this feature"
            case .forbidden: "You do not have permission for this action"
            case .gone: "The recipient is no longer at this address"
            case .internalServerError: "The server encountered an internal problem"
            case .itemNotFound: "The requested item was not found"
            case .jidMalformed: "The address is malformed"
            case .notAcceptable: "The recipient does not accept this request"
            case .notAllowed: "The recipient does not allow this action"
            case .notAuthorized: "Valid credentials are required for this action"
            case .policyViolation: "The request violates a server policy"
            case .recipientUnavailable: "The recipient is unavailable"
            case .redirect: "The request was redirected to another address"
            case .registrationRequired: "Registration is required for this action"
            case .remoteServerNotFound: "The remote server could not be found"
            case .remoteServerTimeout: "The remote server did not respond in time"
            case .resourceConstraint: "The server lacks resources for this request"
            case .serviceUnavailable: "The service is unavailable"
            case .subscriptionRequired: "A subscription is required for this action"
            case .undefinedCondition: "The request failed for an unknown reason"
            case .unexpectedRequest: "The request was not expected at this time"
            }
        }
    }
}
