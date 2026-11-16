import Foundation
import Testing
@testable import DuckoXMPP

@MainActor
struct RegistrationProcessTests {
    @Test
    func `submit-registration reports a form that only names a web page instead of submitting it`() async throws {
        let run = try await submitRegistration(
            form: "<instructions>Register on the web</instructions><x xmlns='jabber:x:oob'><url>https://example.com/register</url></x>",
            input: "/submit-registration\n"
        )

        #expect(run.output.contains("The server registers accounts only on the web page shown above."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    @Test
    func `submit-registration asks again for a field left blank and submits nothing without it`() async throws {
        let run = try await submitRegistration(form: "<username>alice</username><nick/>", input: "/submit-registration\n\n\n")

        #expect(run.output.contains("Nickname is required."), Comment(rawValue: run.output))
        #expect(run.output.contains("Input ended before Nickname had a value."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    @Test(arguments: [
        ("<field var='nick' type='text-single' label='Nickname'><required/></field>", "Nickname", "", "Nickname is required."),
        (
            "<field var='role' type='list-single' label='Role'><required/><option><value>member</value></option></field>",
            "Role", "admin", "admin is not one of the listed options."
        )
    ])
    func `submit-registration asks again until a required data form field gets a value and submits nothing without it`(
        field: String, label: String, typed: String, complaint: String
    ) async throws {
        let run = try await submitRegistration(form: dataForm(field), input: "/submit-registration\n\(typed)\n")

        #expect(run.output.contains(complaint), Comment(rawValue: run.output))
        #expect(run.output.contains("Input ended before \(label) had a value."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    @Test
    func `submit-registration without a terminal keeps an optional hidden field's value and submits the form`() async throws {
        let form = dataForm("<field var='pin' type='text-private' label='PIN'/><field var='nick' type='text-single' label='Nickname'><required/></field>")

        let run = try await submitRegistration(form: form, input: "/submit-registration\njules\n")

        #expect(run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    @Test
    func `submit-registration without a terminal names the required hidden field it cannot read`() async throws {
        let run = try await submitRegistration(
            form: dataForm("<field var='pin' type='text-private' label='PIN'><required/></field>"), input: "/submit-registration\n"
        )

        #expect(run.output.contains("No PIN provided. Run in a terminal to enter it interactively."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    // MARK: - CAPTCHA

    @Test
    func `submit-registration saves the image to a file whose path it prints, and deletes the file once done`() async throws {
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(imageChallenge)])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\nk7Rq4w\n")

        let path = try #require(imagePath(in: run.output), Comment(rawValue: run.output))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
        #expect(sets.count == 1)
    }

    @Test
    func `Ctrl-C at the answer prompt deletes the image file and ends the CLI`() async throws {
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(imageChallenge)])

        let run = try await withLoopbackServer(responder: responder, profile: "registration") { _, profile in
            try await profile.run(["interactive", "--output", "plain"], input: "/submit-registration\n", until: "CAPTCHA image for ocr: ", atMarker: { output in
                let path = try #require(imagePath(in: output))
                #expect(FileManager.default.fileExists(atPath: path))
            }, thenSignals: [SIGINT])
        }

        let path = try #require(imagePath(in: run.output))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(run.reason == .exit && run.exitCode == 130, Comment(rawValue: run.output))
    }

    @Test
    func `submit-registration names a CAPTCHA it can't answer and submits nothing`() async throws {
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(proofOfWork("abcdef"))])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\n")

        #expect(run.output.contains("Ducko can't answer this server's challenge."), Comment(rawValue: run.output))
        #expect(sets.isEmpty)
    }

    @Test
    func `submit-registration asks again until enough challenges are answered and submits nothing when input ends`() async throws {
        let challenges = "<field var='answers' type='hidden'><value>2</value></field>" + (imageChallenge + question).replacing("<required/>", with: "")
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(challenges)])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\nk7Rq4w\n\n")

        #expect(run.output.contains("Answer at least 2 of the challenges."), Comment(rawValue: run.output))
        #expect(run.output.contains("Input ended before"), Comment(rawValue: run.output))
        #expect(sets.isEmpty)
    }

    @Test
    func `submit-registration without a terminal stops at a challenge answered only in hidden input`() async throws {
        let hiddenQuestion = "<field var='qa' type='text-private' label='What is 2 + 3?'/>"
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(hiddenQuestion)])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\n")

        #expect(run.output.contains("No What is 2 + 3? provided."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Answer the challenge."), Comment(rawValue: run.output))
        #expect(sets.isEmpty)
    }

    @Test
    func `submit-registration without a terminal keeps asking when a challenge can still be typed beside a hidden one`() async throws {
        let challenges = "<field var='answers' type='hidden'><value>1</value></field>" + imageChallenge.replacing("<required/>", with: "")
            + "<field var='qa' type='text-private' label='What is 2 + 3?'/>"
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(challenges)])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\n\nk7Rq4w\n")

        #expect(run.output.contains("Answer at least 1 of the challenges."), Comment(rawValue: run.output))
        #expect(run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
        #expect(sets.count == 1)
        #expect(sets.first?.contains("k7Rq4w") == true)
    }

    @Test
    func `submit-registration shows a fresh form after each refusal and stops after three submissions`() async throws {
        let refusal = """
        <error type='modify'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
        <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>The answer is wrong</text></error>
        """
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(question)], refusal: refusal)

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\n4\n6\n7\n8\n")

        #expect(sets.count == 3)
        #expect(run.output.components(separatedBy: "What is 2 + 3?").count - 1 >= 3, Comment(rawValue: run.output))
        #expect(run.output.contains("The answer is wrong"), Comment(rawValue: run.output))
        #expect(!run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
    }

    @Test
    func `submit-registration answers a proof of work it can solve without asking for it`() async throws {
        let responder = ScriptedRegistrationResponder(forms: [captchaForm(proofOfWork("a1"))])

        let (run, sets) = try await submitRegistration(responder, input: "/submit-registration\n")

        #expect(run.output.contains("Registration submitted successfully."), Comment(rawValue: run.output))
        #expect(sets.count == 1)
        #expect(sets.first?.contains("var=\"SHA-256\"") == true)
    }

    private let imageChallenge = """
    <field var='ocr' type='text-single' label='Enter the text you see'><required/>\
    <media xmlns='urn:xmpp:media-element'><uri type='image/png'>cid:sha1+abc@bob.xmpp.org</uri></media></field>
    """

    private let question = "<field var='qa' type='text-single' label='What is 2 + 3?'><required/></field>"

    private func proofOfWork(_ label: String) -> String {
        "<field var='SHA-256' type='text-single' label='\(label)'><required/></field>"
    }

    /// A registration form shaped like ejabberd's CAPTCHA form, holding `challenges` and the image the image challenge
    /// names. It asks for no password, which the plaintext loopback stream would refuse to send.
    private func captchaForm(_ challenges: String) -> String {
        dataForm("""
        <field var='from' type='hidden'><value>example.com</value></field>\
        <field var='challenge' type='hidden'><value>123</value></field>\
        \(challenges)\
        <field var='captcha-fallback-text' type='fixed'><value>If you don't see the CAPTCHA image here, visit the web page.</value></field>\
        <field var='captcha-fallback-url' type='text-single' label='CAPTCHA web page'><value>https://example.com/captcha/123</value></field>
        """) + "<data xmlns='urn:xmpp:bob' cid='sha1+abc@bob.xmpp.org' type='image/png'>iVBORw0KGgo=</data>"
    }

    /// The path the CLI printed for the `ocr` challenge's image.
    private func imagePath(in output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("CAPTCHA image for ocr: ") }.map { String($0.dropFirst("CAPTCHA image for ocr: ".count)) }
    }

    /// Runs the REPL against a server answering with `responder`, typing `input`, and returns the registrations it got.
    private func submitRegistration(_ responder: ScriptedRegistrationResponder, input: String) async throws -> (ThrowawayProfile.Run, [String]) {
        try await withLoopbackServer(responder: responder, profile: "registration") { server, profile in
            let run = try await profile.run(["interactive", "--output", "plain"], input: input)
            return await (run, server.currentResponder.sets)
        }
    }

    /// A registration data form holding `fields`.
    private func dataForm(_ fields: String) -> String {
        """
        <x xmlns='\(XMPPNamespaces.dataForms)' type='form'><field var='FORM_TYPE' type='hidden'>\
        <value>\(XMPPNamespaces.register)</value></field>\(fields)</x>
        """
    }

    /// Runs the REPL against a server whose registration form holds `form`, typing `input`.
    private func submitRegistration(form: String, input: String) async throws -> ThrowawayProfile.Run {
        try await withLoopbackServer(responder: RegistrationFormResponder(form: form), profile: "registration") { _, profile in
            try await profile.run(["interactive", "--output", "plain"], input: input)
        }
    }
}

/// Answers a registration form request with `form`.
private struct RegistrationFormResponder: LoopbackIQResponder {
    let form: String

    func reply(to element: DuckoXMPP.XMLElement, id: String) -> String? {
        guard XMPPIQ(element: element).type == "get",
              element.child(named: "query", namespace: XMPPNamespaces.register) != nil
        else { return nil }
        return "<iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.register)'>\(form)</query></iq>"
    }
}

/// Answers registration form requests with `forms` in turn, the last one again once they run out, and each
/// registration with `refusal` as a stanza error, or with a result when there is none.
private struct ScriptedRegistrationResponder: LoopbackIQResponder {
    let forms: [String]
    var refusal: String?
    private var gets = 0
    /// Each registration received.
    private(set) var sets: [String] = []

    init(forms: [String], refusal: String? = nil) {
        self.forms = forms
        self.refusal = refusal
    }

    mutating func reply(to element: DuckoXMPP.XMLElement, id: String) -> String? {
        guard element.child(named: "query", namespace: XMPPNamespaces.register) != nil else { return nil }
        switch XMPPIQ(element: element).type {
        case "get":
            let form = forms[min(gets, forms.count - 1)]
            gets += 1
            return "<iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.register)'>\(form)</query></iq>"
        case "set":
            sets.append(element.xmlString)
            return refusal.map { "<iq type='error' id='\(id)'>\($0)</iq>" } ?? "<iq type='result' id='\(id)'/>"
        default:
            return nil
        }
    }
}
