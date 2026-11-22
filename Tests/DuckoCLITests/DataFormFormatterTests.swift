import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct DataFormFormatterTests {
    private let form = DataFormInfo(
        title: "Configuration for room",
        instructions: ["Complete this form."],
        fields: [
            RoomConfigField(variable: "FORM_TYPE", type: "hidden", values: ["http://jabber.org/protocol/muc#roomconfig"]),
            RoomConfigField(variable: nil, position: 1, type: "fixed", values: ["Access"]),
            RoomConfigField(
                variable: "muc#roomconfig_roomname",
                type: "text-single",
                label: "Room Name",
                description: "Shown in room lists",
                isRequired: true
            ),
            RoomConfigField(variable: "muc#roomconfig_roomsecret", type: "text-private", label: "Password", values: ["hunter2"])
        ]
    )

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter()])
    func `text output shows the title, instructions, fixed text, descriptions and required markers`(formatter: any CLIFormatter) {
        let output = formatter.formatDataForm(form)

        #expect(output.contains("Configuration for room"))
        #expect(output.contains("Complete this form."))
        #expect(output.contains("Access"))
        #expect(output.contains("Shown in room lists"))
        #expect(output.contains("(required)"))
        #expect(!output.contains("FORM_TYPE"))
    }

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter(), JSONFormatter()])
    func `a text-private value is obscured`(formatter: any CLIFormatter) {
        let output = formatter.formatDataForm(form)

        #expect(output.contains(obscuredDataFormValue))
        #expect(!output.contains("hunter2"))
    }

    @Test func `plain output marks only the required field`() {
        let lines = PlainFormatter().formatDataForm(form).split(separator: "\n")

        #expect(lines.contains("  Room Name (required): (empty)"))
        #expect(lines.contains("  Password: \(obscuredDataFormValue)"))
    }

    @Test func `JSON keeps each field's raw attributes`() throws {
        let output = JSONFormatter().formatDataForm(form)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let fields = try #require(json["fields"] as? [[String: Any]])

        #expect(json["type"] as? String == "data_form")
        #expect(json["title"] as? String == "Configuration for room")
        #expect(json["instructions"] as? [String] == ["Complete this form."])
        #expect(fields.map { $0["type"] as? String } == ["fixed", "text-single", "text-private"])
        #expect(fields[0]["values"] as? [String] == ["Access"])
        #expect(fields[1]["var"] as? String == "muc#roomconfig_roomname")
        #expect(fields[1]["desc"] as? String == "Shown in room lists")
        #expect(fields[1]["required"] as? String == "true")
        #expect(fields[2]["required"] == nil)
    }

    /// A registration form whose CAPTCHA has an image sent with it, an audio challenge, a web page that isn't a web
    /// address, a proof of work too hard to solve, and two answers wanted.
    private let captchaForm = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
        formType: .dataForm, instructions: nil, isRegistered: false,
        dataForm: DataForm(fields: [
            DataFormField(variable: "challenge", type: "hidden", values: ["123"]),
            DataFormField(variable: "answers", type: "hidden", values: ["2"]),
            DataFormField(
                variable: "ocr", type: "text-single", label: "Enter the text you see", isRequired: true,
                media: [DataFormMediaURI(type: "image/png", uri: "cid:sha1+abc@bob.xmpp.org")]
            ),
            DataFormField(variable: "audio_recog", type: "text-single", label: "Enter the number you hear"),
            DataFormField(variable: "SHA-256", type: "text-single", label: "abcdef", isRequired: true),
            DataFormField(variable: "captcha-fallback-text", type: "fixed", values: ["Visit the web page."]),
            DataFormField(variable: "captcha-fallback-url", type: "text-single", values: ["javascript:alert(1)"])
        ]),
        bitsOfBinary: [BitsOfBinaryData(cid: "sha1+abc@bob.xmpp.org", type: "image/png", bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])]
    ))

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter()])
    func `text output shows the CAPTCHA's images, notes, fallback page and answer count`(formatter: any CLIFormatter) {
        let output = formatter.formatRegistrationForm(captchaForm)

        #expect(output.contains("CAPTCHA"))
        #expect(output.contains("answer 2"))
        #expect(output.contains("image sent with the form"))
        #expect(output.contains("Ducko can't play this challenge"))
        #expect(output.contains("Visit the web page."))
        #expect(output.contains("CAPTCHA web page") && output.contains("javascript:alert(1)"))
        #expect(output.contains(captchaUnanswerableNote))
        #expect(!output.contains("SHA-256"))
    }

    @Test func `JSON carries the CAPTCHA`() throws {
        let output = JSONFormatter().formatRegistrationForm(captchaForm)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let captcha = try #require(json["captcha"] as? [String: Any])
        let challenges = try #require(captcha["challenges"] as? [[String: String]])

        #expect(challenges == [
            ["var": "ocr", "required": "true", "playable": "true", "image_type": "image/png"],
            ["var": "audio_recog", "required": "false", "playable": "false"]
        ])
        #expect(captcha["answers"] as? String == "2")
        #expect(captcha["proof_of_work_solved"] as? String == "false")
        #expect(captcha["fallback_text"] as? String == "Visit the web page.")
        #expect(captcha["fallback_url"] == nil)
        #expect(captcha["fallback_url_text"] as? String == "javascript:alert(1)")
        #expect(captcha["unanswerable"] as? String == "true")
    }

    /// A registration form whose CAPTCHA has an image on the web, an image whose data didn't arrive, and a web page.
    private let linkedCaptchaForm = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
        formType: .dataForm, instructions: nil, isRegistered: false,
        dataForm: DataForm(fields: [
            DataFormField(variable: "challenge", type: "hidden", values: ["123"]),
            DataFormField(
                variable: "ocr", type: "text-single", label: "Enter the text you see",
                media: [DataFormMediaURI(type: "image/png", uri: "https://example.com/captcha/123/ocr.png")]
            ),
            DataFormField(
                variable: "picture_recog", type: "text-single", label: "What is shown?",
                media: [DataFormMediaURI(type: "image/png", uri: "cid:sha1+missing@bob.xmpp.org")]
            ),
            DataFormField(variable: "captcha-fallback-url", type: "text-single", values: ["https://example.com/captcha/123"])
        ])
    ))

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter()])
    func `text output shows a CAPTCHA image on the web, one that can't be shown, and the web page`(formatter: any CLIFormatter) {
        let output = formatter.formatRegistrationForm(linkedCaptchaForm)

        #expect(output.contains("image at https://example.com/captcha/123/ocr.png"))
        #expect(output.contains("Ducko couldn't display the image"))
        #expect(output.split(separator: "\n").contains { $0.contains("CAPTCHA web page") && $0.hasSuffix(" https://example.com/captcha/123") })
    }

    @Test func `JSON carries a CAPTCHA image on the web, one that can't be shown, and the web page`() throws {
        let output = JSONFormatter().formatRegistrationForm(linkedCaptchaForm)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let captcha = try #require(json["captcha"] as? [String: Any])
        let challenges = try #require(captcha["challenges"] as? [[String: String]])

        #expect(challenges == [
            ["var": "ocr", "required": "false", "playable": "true", "image_url": "https://example.com/captcha/123/ocr.png"],
            ["var": "picture_recog", "required": "false", "playable": "true", "image_type": "unavailable"]
        ])
        #expect(captcha["fallback_url"] as? String == "https://example.com/captcha/123")
        #expect(captcha["fallback_url_text"] == nil)
    }
}
