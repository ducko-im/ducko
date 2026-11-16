import DuckoTestSupport
@testable import DuckoXMPP

/// Registration forms shaped like ejabberd's CAPTCHA forms (`ejabberd_captcha.erl`, `mod_register.erl`).
enum CaptchaFormFixtures {
    static let imageCID = "sha1+abc@bob.xmpp.org"
    /// A PNG's signature, inline as ejabberd sends the image.
    static let inlineImage = "<data xmlns='urn:xmpp:bob' cid='\(imageCID)' type='image/png' max-age='0'>iVBORw0KGgo=</data>"
    /// A label Ducko solves within a few hundred attempts.
    static let solvableLabel = "a1"
    /// A label over the five hex digits Ducko solves.
    static let tooHardLabel = "abcdef"

    static func ocr(_ variable: String = "ocr", required: Bool = true, uri: String = "cid:\(imageCID)") -> String {
        """
        <field var='\(variable)' type='text-single' label='Enter the text you see'>\(required ? "<required/>" : "")\
        <media xmlns='urn:xmpp:media-element' height='60' width='180'><uri type='image/png'>\(uri)</uri></media></field>
        """
    }

    static func proofOfWork(_ label: String, required: Bool = true) -> String {
        "<field var='SHA-256' type='text-single' label='\(label)'>\(required ? "<required/>" : "")</field>"
    }

    static func question(required: Bool = true) -> String {
        "<field var='qa' type='text-single' label='What is 2 + 3?'>\(required ? "<required/>" : "")</field>"
    }

    static func audio(required: Bool = true) -> String {
        """
        <field var='audio_recog' type='text-single' label='Enter the number you hear'>\(required ? "<required/>" : "")\
        <media xmlns='urn:xmpp:media-element'><uri type='audio/x-wav'>https://example.com/captcha/123/audio</uri></media></field>
        """
    }

    static func answers(_ count: Int) -> String {
        "<field var='answers' type='hidden'><value>\(count)</value></field>"
    }

    /// The `<query>` of ejabberd's registration form: the account fields, the hidden CAPTCHA fields, `challenges`,
    /// the fallback text and page, then `data`. A nil `from` leaves out the hidden field naming the server.
    static func query(
        _ challenges: String, from: String? = "example.com", challengeID: String = "123",
        fallbackURL: String = "https://example.com/captcha/123/image", data: String = inlineImage
    ) -> String {
        """
        <query xmlns='jabber:iq:register'><instructions>Choose a username and password to register with this server</instructions>\
        <x xmlns='jabber:x:data' type='form'>\
        <field var='FORM_TYPE' type='hidden'><value>jabber:iq:register</value></field>\
        <field var='username' type='text-single' label='User'><required/></field>\
        <field var='password' type='text-private' label='Password'><required/></field>\
        \(from.map { "<field var='from' type='hidden'><value>\($0)</value></field>" } ?? "")\
        <field var='challenge' type='hidden'><value>\(challengeID)</value></field>\
        <field var='sid' type='hidden'><value/></field>\
        \(challenges)\
        <field var='captcha-fallback-text' type='fixed'><value>If you don't see the CAPTCHA image here, visit the web page.</value></field>\
        <field var='captcha-fallback-url' type='text-single' label='CAPTCHA web page'><value>\(fallbackURL)</value></field>\
        </x>\(data)</query>
        """
    }

    static func form(
        _ challenges: String, from: String? = "example.com", challengeID: String = "123",
        fallbackURL: String = "https://example.com/captcha/123/image", data: String = inlineImage
    ) throws -> RegistrationModule.RegistrationForm {
        let query = query(challenges, from: from, challengeID: challengeID, fallbackURL: fallbackURL, data: data)
        let events = XMPPStreamParser().parse(Array((testServerStreamOpen + query).utf8))
        for case let .stanzaReceived(element) in events {
            return RegistrationModule.parseForm(element)
        }
        throw XMPPClientError.unexpectedStreamState("No query")
    }
}
