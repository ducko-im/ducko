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
