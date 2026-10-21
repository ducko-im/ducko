import Testing
@testable import DuckoXMPP

struct XMPPStanzaErrorTests {
    @Test(arguments: [
        (XMPPStanzaError.Condition.badRequest, "The request was malformed"),
        (XMPPStanzaError.Condition.conflict, "The request conflicts with an existing resource"),
        (XMPPStanzaError.Condition.featureNotImplemented, "The recipient does not support this feature"),
        (XMPPStanzaError.Condition.forbidden, "You do not have permission for this action"),
        (XMPPStanzaError.Condition.gone, "The recipient is no longer at this address"),
        (XMPPStanzaError.Condition.internalServerError, "The server encountered an internal problem"),
        (XMPPStanzaError.Condition.itemNotFound, "The requested item was not found"),
        (XMPPStanzaError.Condition.jidMalformed, "The address is malformed"),
        (XMPPStanzaError.Condition.notAcceptable, "The recipient does not accept this request"),
        (XMPPStanzaError.Condition.notAllowed, "The recipient does not allow this action"),
        (XMPPStanzaError.Condition.notAuthorized, "Valid credentials are required for this action"),
        (XMPPStanzaError.Condition.policyViolation, "The request violates a server policy"),
        (XMPPStanzaError.Condition.recipientUnavailable, "The recipient is unavailable"),
        (XMPPStanzaError.Condition.redirect, "The request was redirected to another address"),
        (XMPPStanzaError.Condition.registrationRequired, "Registration is required for this action"),
        (XMPPStanzaError.Condition.remoteServerNotFound, "The remote server could not be found"),
        (XMPPStanzaError.Condition.remoteServerTimeout, "The remote server did not respond in time"),
        (XMPPStanzaError.Condition.resourceConstraint, "The server lacks resources for this request"),
        (XMPPStanzaError.Condition.serviceUnavailable, "The service is unavailable"),
        (XMPPStanzaError.Condition.subscriptionRequired, "A subscription is required for this action"),
        (XMPPStanzaError.Condition.undefinedCondition, "The request failed for an unknown reason"),
        (XMPPStanzaError.Condition.unexpectedRequest, "The request was not expected at this time")
    ])
    func `Condition display text is readable`(condition: XMPPStanzaError.Condition, expected: String) {
        #expect(condition.displayText == expected)
    }

    @Test(arguments: [
        (String?.some("No such node"), "No such node"),
        (String?.some(" \n "), "The requested item was not found"),
        (String?.none, "The requested item was not found")
    ])
    func `Display text prefers non-blank server text, then the condition phrase`(text: String?, expected: String) {
        #expect(XMPPStanzaError(errorType: .cancel, condition: .itemNotFound, text: text).displayText == expected)
    }

    @Test
    func `Parse keeps the application-specific condition`() throws {
        let iq = try stanza("""
        <iq type="error" id="s1" from="search.example.org"><error type="wait">\
        <resource-constraint xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
        <rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="30"/>\
        </error></iq>
        """)

        let error = try #require(XMPPStanzaError.parse(from: iq.child(named: "error")))

        #expect(error.condition == .resourceConstraint)
        let applicationCondition = try #require(error.applicationCondition)
        #expect(applicationCondition.name == "rate-limit")
        #expect(applicationCondition.namespace == "urn:xmpp:channel-search:0:error")
        #expect(applicationCondition.attribute("retry-after") == "30")
    }

    @Test
    func `Parse leaves the application condition empty when the error has none`() throws {
        let iq = try stanza("""
        <iq type="error" id="s1" from="search.example.org"><error type="cancel">\
        <item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
        <text xmlns="urn:ietf:params:xml:ns:xmpp-stanzas">No such node</text>\
        </error></iq>
        """)

        let error = try #require(XMPPStanzaError.parse(from: iq.child(named: "error")))

        #expect(error.condition == .itemNotFound)
        #expect(error.applicationCondition == nil)
    }
}
