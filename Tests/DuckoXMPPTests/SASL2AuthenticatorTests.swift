import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Builds a `<stream:features>` element with SASL2 authentication.
private func sasl2Features(
    mechanisms: [String],
    supportsBind2: Bool = false,
    supportsSM: Bool = false,
    bind2InlineFeatures: [String] = []
) -> XMLElement {
    var auth = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
    for name in mechanisms {
        var mechanism = XMLElement(name: "mechanism")
        mechanism.addText(name)
        auth.addChild(mechanism)
    }

    if supportsBind2 || supportsSM {
        var inline = XMLElement(name: "inline")
        if supportsBind2 {
            var bind = XMLElement(name: "bind", namespace: XMPPNamespaces.bind2)
            var bindInline = XMLElement(name: "inline")
            for feature in bind2InlineFeatures {
                bindInline.addChild(XMLElement(name: "feature", attributes: ["var": feature]))
            }
            bind.addChild(bindInline)
            inline.addChild(bind)
        }
        if supportsSM {
            inline.addChild(XMLElement(name: "sm", namespace: XMPPNamespaces.sm))
        }
        auth.addChild(inline)
    }

    var features = XMLElement(name: "stream:features")
    features.addChild(auth)
    return features
}

/// Builds a SASL2 `<success>` element.
private func sasl2Success(
    jid: String?,
    additionalData: String? = nil,
    bound: XMLElement? = nil,
    streamManagement: XMLElement? = nil
) -> XMLElement {
    var success = XMLElement(name: "success", namespace: XMPPNamespaces.sasl2)
    if let jid {
        var authID = XMLElement(name: "authorization-identifier")
        authID.addText(jid)
        success.addChild(authID)
    }
    if let additionalData {
        var ad = XMLElement(name: "additional-data")
        ad.addText(additionalData)
        success.addChild(ad)
    }
    if let bound {
        success.addChild(bound)
    }
    if let streamManagement {
        success.addChild(streamManagement)
    }
    return success
}

/// Starts a PLAIN exchange and feeds it `success`.
private func plainResponse(to success: XMLElement) throws -> SASL2Authenticator.Response {
    var auth = SASL2Authenticator()
    _ = try auth.begin(
        features: sasl2Features(mechanisms: ["PLAIN"]),
        authcid: "user",
        password: "pencil",
        inlinePayloads: []
    )
    return auth.receive(success)
}

// MARK: - Tests

enum SASL2AuthenticatorTests {
    struct FeatureParsing {
        @Test
        func `Parses SASL2 features with mechanisms`() {
            let features = sasl2Features(mechanisms: ["SCRAM-SHA-256", "PLAIN"])
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed != nil)
            #expect(parsed?.mechanisms.contains("SCRAM-SHA-256") == true)
            #expect(parsed?.mechanisms.contains("PLAIN") == true)
        }

        @Test
        func `Parses inline feature support`() {
            let features = sasl2Features(
                mechanisms: ["PLAIN"],
                supportsBind2: true,
                supportsSM: true,
                bind2InlineFeatures: [XMPPNamespaces.carbons, XMPPNamespaces.sm]
            )
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed?.supportsBind2 == true)
            #expect(parsed?.supportsSM == true)
            #expect(parsed?.bind2InlineFeatures == [XMPPNamespaces.carbons, XMPPNamespaces.sm])
        }

        @Test
        func `Returns nil when no SASL2 authentication element`() {
            let features = XMLElement(name: "stream:features")
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed == nil)
        }

        @Test
        func `Returns nil when no mechanisms listed`() {
            var auth = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
            auth.addChild(XMLElement(name: "inline"))
            var features = XMLElement(name: "stream:features")
            features.addChild(auth)
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed == nil)
        }
    }

    struct MechanismSelection {
        @Test
        func `Selects SCRAM-SHA-256 when all offered`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Falls back to PLAIN when no SCRAM available`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `With SCRAM required, an offer that includes SCRAM signs in with it`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["SCRAM-SHA-256", "PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                requiresSCRAM: true
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Throws when no supported mechanism`() {
            var auth = SASL2Authenticator()
            #expect(throws: SASLAuthError.self) {
                try auth.begin(
                    features: sasl2Features(mechanisms: ["EXTERNAL"]),
                    authcid: "user",
                    password: "pencil",
                    inlinePayloads: []
                )
            }
        }
    }

    struct PLUSMechanismSelection {
        @Test
        func `Does not offer PLUS when no CB data`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["SCRAM-SHA-256-PLUS", "PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `Skips the unsupported EXTERNAL mechanism`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["EXTERNAL", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }
    }

    struct PLAINFlow {
        @Test
        func `Full PLAIN flow with SASL2 framing`() throws {
            var auth = SASL2Authenticator()
            let authElement = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            #expect(authElement.name == "authenticate")
            #expect(authElement.namespace == XMPPNamespaces.sasl2)
            #expect(authElement.child(named: "initial-response") != nil)

            let success = sasl2Success(jid: "user@example.com/res1")
            let response = auth.receive(success)
            guard case let .success(.session(fullJID, _)) = response else {
                Issue.record("Expected a new session, got \(response)")
                return
            }
            #expect(fullJID.description == "user@example.com/res1")
        }
    }

    struct SuccessParsing {
        @Test
        func `Parses authorization-identifier as bound JID`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let success = sasl2Success(jid: "user@example.com/ducko-abc")
            let response = auth.receive(success)
            guard case let .success(.session(fullJID, _)) = response else {
                Issue.record("Expected a new session, got \(response)")
                return
            }
            #expect(fullJID.bareJID.localPart == "user")
            #expect(fullJID.bareJID.domainPart == "example.com")
            #expect(fullJID.resourcePart == "ducko-abc")
        }

        @Test
        func `Parses the answer to an inline resume`() throws {
            let resumed = XMLElement(name: "resumed", namespace: XMPPNamespaces.sm, attributes: ["previd": "sm-1", "h": "3"])
            let response = try plainResponse(to: sasl2Success(jid: "user@example.com/res", streamManagement: resumed))
            guard case let .success(.resumed(element)) = response else {
                Issue.record("Expected a resumed stream, got \(response)")
                return
            }
            #expect(element.attribute("h") == "3")
        }

        /// A resumed success may name only the bare JID (XEP-0388 Example 9), but it must name a valid one.
        @Test(arguments: [
            ("user@example.com", true), ("user@example.com/res", true), (nil, false), ("", false), ("@@", false)
        ] as [(String?, Bool)])
        func `A resumed success needs a valid bare or full JID`(jid: String?, resumes: Bool) throws {
            let resumed = XMLElement(name: "resumed", namespace: XMPPNamespaces.sm, attributes: ["previd": "sm-1", "h": "0"])
            let response = try plainResponse(to: sasl2Success(jid: jid, streamManagement: resumed))
            if case .success(.resumed) = response {
                #expect(resumes)
            } else if case .failure(.invalidState) = response {
                #expect(!resumes)
            } else {
                Issue.record("Expected a resumed stream or invalidState, got \(response)")
            }
        }

        @Test
        func `A fresh session must name its full JID`() throws {
            let response = try plainResponse(to: sasl2Success(jid: "user@example.com"))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }

        @Test
        func `Parses bound element from Bind 2`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let bound = XMLElement(name: "bound", namespace: XMPPNamespaces.bind2)
            let success = sasl2Success(jid: "user@example.com/res", bound: bound)
            let response = auth.receive(success)
            guard case let .success(.session(_, bound)) = response else {
                Issue.record("Expected a new session, got \(response)")
                return
            }
            #expect(bound?.name == "bound")
        }

        @Test
        func `Bound is nil when not using Bind 2`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let success = sasl2Success(jid: "user@example.com/res")
            let response = auth.receive(success)
            guard case let .success(.session(_, bound)) = response else {
                Issue.record("Expected a new session, got \(response)")
                return
            }
            #expect(bound == nil)
        }
    }

    struct FailureHandling {
        @Test
        func `Server failure with condition`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            var failure = XMLElement(name: "failure", namespace: XMPPNamespaces.sasl2)
            failure.addChild(XMLElement(name: "not-authorized"))

            let response = auth.receive(failure)
            guard case let .failure(.serverFailure(condition, _)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "not-authorized")
        }

        @Test
        func `A continue asks for a sign-in step that is not supported`() throws {
            let response = try plainResponse(to: XMLElement(name: "continue", namespace: XMPPNamespaces.sasl2))
            guard case .failure(.unsupportedSignInStep) = response else {
                Issue.record("Expected unsupportedSignInStep, got \(response)")
                return
            }
        }

        @Test
        func `Receive without begin returns invalidState`() {
            var auth = SASL2Authenticator()
            let response = auth.receive(XMLElement(name: "success", namespace: XMPPNamespaces.sasl2))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }
    }

    struct InlinePayloads {
        @Test
        func `Authenticate element includes inline payloads`() throws {
            var auth = SASL2Authenticator()

            let bind = buildBind2Request(enableSM: true, enableCarbons: true)
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"], supportsBind2: true, supportsSM: true),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [bind]
            )

            let bindChild = element.child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bindChild != nil)
            #expect(bindChild?.childText(named: "tag") == "Ducko")
            #expect(bindChild?.child(named: "enable", namespace: XMPPNamespaces.sm) != nil)
            #expect(bindChild?.child(named: "enable", namespace: XMPPNamespaces.carbons) != nil)
        }

        @Test(arguments: [String?.some("Tobias's MacBook"), nil])
        func `Authenticate names the user agent without an id`(device: String?) throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                userAgent: SASL2UserAgent(software: "Ducko", device: device)
            )

            let userAgent = try #require(element.child(named: "user-agent"))
            #expect(userAgent.attribute("id") == nil)
            #expect(userAgent.childText(named: "software") == "Ducko")
            #expect(userAgent.childText(named: "device") == device)
        }
    }

    struct Bind2Request {
        @Test
        func `Builds correct Bind 2 request`() {
            let bind = buildBind2Request(enableSM: true, enableCarbons: true)
            #expect(bind.name == "bind")
            #expect(bind.namespace == XMPPNamespaces.bind2)
            #expect(bind.childText(named: "tag") == "Ducko")

            let smEnable = bind.child(named: "enable", namespace: XMPPNamespaces.sm)
            #expect(smEnable?.attribute("resume") == "true")

            let carbonsEnable = bind.child(named: "enable", namespace: XMPPNamespaces.carbons)
            #expect(carbonsEnable != nil)
        }

        @Test
        func `Uses custom tag when provided`() {
            let bind = buildBind2Request(tag: "laptop")
            #expect(bind.childText(named: "tag") == "laptop")
        }

        @Test
        func `Omits SM and carbons when not requested`() {
            let bind = buildBind2Request(enableSM: false, enableCarbons: false)
            #expect(bind.child(named: "enable", namespace: XMPPNamespaces.sm) == nil)
            #expect(bind.child(named: "enable", namespace: XMPPNamespaces.carbons) == nil)
        }
    }
}
