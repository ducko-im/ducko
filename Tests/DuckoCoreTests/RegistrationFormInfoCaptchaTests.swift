import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private typealias Fixtures = CaptchaFormFixtures

struct RegistrationFormInfoCaptchaTests {
    @Test
    func `An image challenge shows its inline image, and the fallback moves out of the fields`() throws {
        let form = try filled(Fixtures.form(Fixtures.ocr()))

        let captcha = try #require(form.captcha)
        let challenge = try #require(captcha.challenges.first)
        guard case let .inline(data, format) = challenge.image else {
            Issue.record("Expected an inline image, got \(String(describing: challenge.image))")
            return
        }
        #expect(captcha.challenges.map(\.variable) == ["ocr"])
        #expect(data == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(format == .png)
        #expect(captcha.fallbackText == "If you don't see the CAPTCHA image here, visit the web page.")
        #expect(captcha.fallbackLink == URL(string: "https://example.com/captcha/123/image"))
        #expect(form.dataForm.fields.compactMap(\.variable).filter { $0.hasPrefix("captcha-") }.isEmpty)
        #expect(form.dataForm.fields.contains { $0.variable == "ocr" })
    }

    @Test
    func `A solved proof of work replaces the image, so the form goes out unseen with the answer and without the image`() async throws {
        let form = try await filled(Fixtures.form(Fixtures.ocr() + Fixtures.proofOfWork(Fixtures.solvableLabel)))
            .answeringProofOfWork(prefixFallback: "fallback.example", allowsSkippingImage: true)

        let fields = submittedFields(form)
        let answer = try #require(fields["SHA-256"]?.first)
        #expect(answer.hasPrefix("example.com"))
        #expect(fields["ocr"] == nil)
        #expect(form.captcha?.challenges.isEmpty == true)
        #expect(form.captcha?.fallbackText == nil)
        #expect(form.captcha?.fallbackLink == nil)
        #expect(form.captcha?.fallbackURLText == nil)
        #expect(form.asksOnlyForAccountDetails)
    }

    @Test
    func `Without the server's JID in the form, the proof of work's answer starts with the JID the form came from`() async throws {
        let form = try await filled(Fixtures.form(Fixtures.ocr() + Fixtures.proofOfWork(Fixtures.solvableLabel), from: nil))
            .answeringProofOfWork(prefixFallback: "fallback.example", allowsSkippingImage: true)

        let answer = try #require(submittedFields(form)["SHA-256"]?.first)
        #expect(answer.hasPrefix("fallback.example"))
    }

    @Test(arguments: [
        ("an answers field", Fixtures.answers(1) + Fixtures.ocr()),
        ("a third required challenge", Fixtures.ocr() + Fixtures.question())
    ])
    func `A solved proof of work keeps the image on a form that asks for more than the image and the proof of work`(
        name: String, challenges: String
    ) async throws {
        let form = try await filled(Fixtures.form(challenges + Fixtures.proofOfWork(Fixtures.solvableLabel)))
            .answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: true)

        #expect(form.captcha?.proofOfWork?.answer != nil, Comment(rawValue: name))
        #expect(form.captcha?.challenges.contains { $0.variable == "ocr" } == true, Comment(rawValue: name))
        #expect(form.dataForm.fields.contains { $0.variable == "ocr" }, Comment(rawValue: name))
        #expect(!form.asksOnlyForAccountDetails, Comment(rawValue: name))
    }

    @Test
    func `A solved proof of work keeps the image when skipping it is not allowed`() async throws {
        let form = try await filled(Fixtures.form(Fixtures.ocr() + Fixtures.proofOfWork(Fixtures.solvableLabel)))
            .answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: false)

        #expect(form.captcha?.proofOfWork?.answer != nil)
        #expect(form.captcha?.challenges.map(\.variable) == ["ocr"])
        #expect(form.dataForm.fields.contains { $0.variable == "ocr" })
        #expect(form.captcha?.fallbackLink != nil)
        #expect(!form.asksOnlyForAccountDetails)
    }

    @Test
    func `A proof of work too hard to solve is left out, and the image answers instead`() async throws {
        var form = try await filled(Fixtures.form(Fixtures.ocr() + Fixtures.proofOfWork(Fixtures.tooHardLabel)))
            .answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: true)
        setValue("k7Rq4w", of: "ocr", in: &form)

        #expect(form.canSubmit)
        #expect(submittedFields(form)["SHA-256"] == nil)
    }

    @Test
    func `A form whose only content is a solved proof of work can be submitted`() async throws {
        let form = try await RegistrationFormInfo(from: Fixtures.form(Fixtures.proofOfWork(Fixtures.solvableLabel)))
            .answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: true)
        var bare = form
        bare.dataForm.fields.removeAll { $0.isUserEditable }

        #expect(!bare.hasFields)
        #expect(bare.canSubmit)
    }

    /// A form that pins one part of the rule for whether Ducko can answer the CAPTCHA.
    struct AnswerabilityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let challenges: String
        let isUnanswerable: Bool

        var testDescription: String {
            name
        }
    }

    private static let answerabilityCases: [AnswerabilityCase] = {
        let solved = Fixtures.proofOfWork(Fixtures.solvableLabel)
        let unsolved = Fixtures.proofOfWork(Fixtures.tooHardLabel)
        let optionalUnsolved = Fixtures.proofOfWork(Fixtures.tooHardLabel, required: false)
        let threeAnswers = Fixtures.answers(3) + Fixtures.ocr(required: false) + Fixtures.question(required: false) + optionalUnsolved
        return [
            AnswerabilityCase(name: "image only", challenges: Fixtures.ocr(), isUnanswerable: false),
            AnswerabilityCase(name: "image and a solved proof of work", challenges: Fixtures.ocr() + solved, isUnanswerable: false),
            AnswerabilityCase(name: "image and an unsolved proof of work", challenges: Fixtures.ocr() + unsolved, isUnanswerable: false),
            AnswerabilityCase(name: "solved proof of work only", challenges: solved, isUnanswerable: false),
            AnswerabilityCase(name: "unsolved proof of work only", challenges: unsolved, isUnanswerable: true),
            AnswerabilityCase(name: "optional unsolved proof of work only", challenges: optionalUnsolved, isUnanswerable: true),
            AnswerabilityCase(
                name: "required unsolved proof of work beside a question, one answer wanted",
                challenges: Fixtures.answers(1) + Fixtures.question() + unsolved, isUnanswerable: true
            ),
            AnswerabilityCase(
                name: "three answers wanted from an image, a question and an unsolved proof of work", challenges: threeAnswers, isUnanswerable: true
            ),
            AnswerabilityCase(name: "audio only, answered through the web page", challenges: Fixtures.audio(), isUnanswerable: false),
            AnswerabilityCase(name: "optional question only", challenges: Fixtures.question(required: false), isUnanswerable: false)
        ]
    }()

    @Test(arguments: answerabilityCases)
    func `A CAPTCHA is unanswerable exactly when answering every remaining challenge leaves it unsatisfied`(
        testCase: AnswerabilityCase
    ) async throws {
        let (name, isUnanswerable) = (testCase.name, testCase.isUnanswerable)
        var form = try await filled(Fixtures.form(testCase.challenges)).answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: true)

        #expect(form.captcha?.isUnanswerable == isUnanswerable, Comment(rawValue: name))
        for challenge in form.captcha?.challenges ?? [] {
            setValue("answer", of: challenge.variable, in: &form)
        }
        #expect(form.canSubmit == !isUnanswerable, Comment(rawValue: name))
        if isUnanswerable {
            #expect(!form.asksOnlyForAccountDetails, Comment(rawValue: name))
        }
    }

    @Test
    func `A text question shows as its field's label`() throws {
        let form = try filled(Fixtures.form(Fixtures.question()))

        #expect(form.captcha?.challenges.first?.image == nil)
        #expect(form.dataForm.fields.first { $0.variable == "qa" }?.displayLabel == "What is 2 + 3?")
    }

    @Test
    func `An audio challenge keeps its field and is marked as one Ducko can't play`() throws {
        let form = try filled(Fixtures.form(Fixtures.audio()))

        #expect(form.captcha?.challenges.first?.isPlayable == false)
        #expect(form.dataForm.fields.contains { $0.variable == "audio_recog" })
    }

    @Test
    func `Each of several image challenges keeps its own image`() throws {
        let secondImage = "<data xmlns='urn:xmpp:bob' cid='sha1+def@bob.xmpp.org' type='image/jpeg'>/9j/</data>"
        let form = try filled(Fixtures.form(
            Fixtures.ocr() + Fixtures.ocr("picture_q", uri: "cid:sha1+def@bob.xmpp.org"), data: Fixtures.inlineImage + secondImage
        ))

        let images = (form.captcha?.challenges ?? []).map { challenge -> String? in
            guard case let .inline(_, format) = challenge.image else { return nil }
            return "\(challenge.variable) \(format.mimeType)"
        }
        #expect(images == ["ocr image/png", "picture_q image/jpeg"])
    }

    @Test
    func `An answers count of two blocks submitting with one answer`() throws {
        var form = try filled(Fixtures.form(Fixtures.answers(2) + Fixtures.ocr(required: false) + Fixtures.question(required: false)))
        setValue("k7Rq4w", of: "ocr", in: &form)

        #expect(!form.canSubmit)

        setValue("5", of: "qa", in: &form)

        #expect(form.canSubmit)
    }

    @Test(arguments: [
        ("image/gif", "R0lGODlhAQABAA==", CaptchaImageFormat?.some(.gif)),
        ("image/jpeg", "/9j/4A==", .jpeg),
        ("Image/PNG; name=captcha.png", "iVBORw0KGgo=", .png),
        ("image/png", "R0lGODlhAQABAA==", nil),
        ("image/bmp", "Qk0=", nil)
    ])
    func `Inline data shows only when its bytes are a PNG, JPEG or GIF of the declared type, whatever its parameters`(
        type: String, base64: String, format: CaptchaImageFormat?
    ) throws {
        let data = "<data xmlns='urn:xmpp:bob' cid='\(Fixtures.imageCID)' type='\(type)'>\(base64)</data>"
        let form = try filled(Fixtures.form(Fixtures.ocr(), data: data))

        switch form.captcha?.challenges.first?.image {
        case let .inline(_, shown): #expect(shown == format)
        case .unavailable: #expect(format == nil)
        case .link, nil: Issue.record("Expected an inline image or the note that it can't be shown")
        }
    }

    @Test(arguments: [
        ("cid:sha1+missing@bob.xmpp.org", "unavailable"),
        ("https://example.com/captcha/123/image.png", "link")
    ])
    func `An image not sent inline is a note that it didn't arrive, or a link for one on the web`(uri: String, kind: String) throws {
        let form = try filled(Fixtures.form(Fixtures.ocr(uri: uri)))

        switch form.captcha?.challenges.first?.image {
        case .unavailable: #expect(kind == "unavailable")
        case let .link(url): #expect(kind == "link" && url.absoluteString == uri)
        case .inline, nil: Issue.record("Expected \(kind)")
        }
    }

    @Test(arguments: [("Page web du CAPTCHA", "Page web du CAPTCHA"), (" ", "CAPTCHA web page"), (nil, "CAPTCHA web page")])
    func `The fallback page is called by the server's label for it, else CAPTCHA web page`(label: String?, shown: String) {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm, instructions: nil, isRegistered: false,
            dataForm: DataForm(fields: [
                DataFormField(variable: "challenge", type: "hidden", values: ["1"]),
                DataFormField(variable: "qa", type: "text-single", label: "What is 2 + 3?"),
                DataFormField(variable: "captcha-fallback-url", type: "text-single", label: label, values: ["https://example.com/captcha"])
            ])
        ))

        #expect(form.captcha?.fallbackLabel == shown)
    }

    @Test
    func `A fallback address that is not a web address stays text`() throws {
        let form = try filled(Fixtures.form(Fixtures.ocr(), fallbackURL: "javascript:alert(1)"))

        #expect(form.captcha?.fallbackLink == nil)
        #expect(form.captcha?.fallbackURLText == "javascript:alert(1)")
    }

    @Test
    func `A fresh form keeps the typed values and its own challenge, and clears every challenge answer`() throws {
        var rejected = try filled(Fixtures.form(Fixtures.ocr() + Fixtures.question(), challengeID: "123"))
        setValue("k7Rq4w", of: "ocr", in: &rejected)
        setValue("5", of: "qa", in: &rejected)

        let fresh = try RegistrationFormInfo(from: Fixtures.form(Fixtures.ocr() + Fixtures.question(), challengeID: "456"))
            .carryingValues(from: rejected)

        let fields = submittedFields(fresh)
        #expect(fields["username"] == ["juliet"])
        #expect(fields["password"] == ["secret"])
        #expect(fields["challenge"] == ["456"])
        #expect(fields["ocr"] == [])
        #expect(fields["qa"] == [])
    }

    private func filled(_ form: RegistrationModule.RegistrationForm) -> RegistrationFormInfo {
        RegistrationFormInfo(from: form).filling(username: "juliet", password: "secret", email: nil)
    }

    private func setValue(_ value: String, of variable: String, in form: inout RegistrationFormInfo) {
        guard let index = form.dataForm.fields.firstIndex(where: { $0.variable == variable }) else { return }
        form.dataForm.fields[index].values = [value]
    }

    /// The submitted data form's values by field.
    private func submittedFields(_ form: RegistrationFormInfo) -> [String: [String]] {
        guard case let .dataForm(fields) = form.submission else { return [:] }
        return Dictionary(fields.compactMap { field in field.variable.map { ($0, field.values) } }) { first, _ in first }
    }
}
