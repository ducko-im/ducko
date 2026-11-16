import DuckoCore

/// A data form as JSON: its title, instructions and the fields a user sees, each with its raw attributes except a
/// text-private value, which is obscured.
struct DataFormOutput: Encodable {
    let type: String?
    let form: DataFormInfo

    private enum CodingKeys: String, CodingKey {
        case type, title, instructions, fields
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(form.title, forKey: .title)
        if !form.instructions.isEmpty {
            try container.encode(form.instructions, forKey: .instructions)
        }
        try container.encode(form.fields.filter(\.isDisplayed).map(FieldOutput.init), forKey: .fields)
    }

    private struct FieldOutput: Encodable {
        let field: RoomConfigField

        private enum CodingKeys: String, CodingKey {
            case variable = "var"
            case type, label, desc, required, values
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(field.variable, forKey: .variable)
            try container.encodeIfPresent(field.type, forKey: .type)
            try container.encodeIfPresent(field.label, forKey: .label)
            try container.encodeIfPresent(field.description, forKey: .desc)
            if field.isRequired {
                try container.encode("true", forKey: .required)
            }
            try container.encode(hidesDataFormValue(field) ? [obscuredDataFormValue] : field.values, forKey: .values)
        }
    }
}

/// A registration form as JSON. A legacy form's fields are listed under `fields`, a data form's nested under `form`.
struct RegistrationFormOutput: Encodable {
    let form: RegistrationFormInfo

    private enum CodingKeys: String, CodingKey {
        case type
        case formKind = "form_kind"
        case isRegistered = "is_registered"
        case instructions
        case redirectURL = "redirect_url"
        case fields
        case form
        case captcha
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("registration_form", forKey: .type)
        try container.encode(form.formKind == .dataForm ? "data_form" : "legacy", forKey: .formKind)
        try container.encode(form.isRegistered ? "true" : "false", forKey: .isRegistered)
        try container.encodeIfPresent(form.instructions, forKey: .instructions)
        try container.encodeIfPresent(form.redirectURL?.absoluteString, forKey: .redirectURL)
        switch form.formKind {
        case .legacy:
            try container.encode(form.legacyFields.map(LegacyFieldOutput.init), forKey: .fields)
        case .dataForm:
            try container.encode(DataFormOutput(type: nil, form: form.dataForm), forKey: .form)
        }
        try container.encodeIfPresent(form.captcha.map(CaptchaOutput.init), forKey: .captcha)
    }

    private struct CaptchaOutput: Encodable {
        let captcha: RegistrationCaptcha

        private enum CodingKeys: String, CodingKey {
            case challenges, answers
            case proofOfWorkSolved = "proof_of_work_solved"
            case fallbackText = "fallback_text"
            case fallbackURL = "fallback_url"
            case fallbackURLText = "fallback_url_text"
            case unanswerable
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(captcha.challenges.map(ChallengeOutput.init), forKey: .challenges)
            try container.encodeIfPresent(captcha.answersRequired.map(String.init), forKey: .answers)
            if let proofOfWork = captcha.proofOfWork {
                try container.encode(proofOfWork.answer == nil ? "false" : "true", forKey: .proofOfWorkSolved)
            }
            try container.encodeIfPresent(captcha.fallbackText, forKey: .fallbackText)
            try container.encodeIfPresent(captcha.fallbackLink?.absoluteString, forKey: .fallbackURL)
            if captcha.fallbackLink == nil {
                try container.encodeIfPresent(captcha.fallbackURLText, forKey: .fallbackURLText)
            }
            try container.encode(captcha.isUnanswerable ? "true" : "false", forKey: .unanswerable)
        }
    }

    private struct ChallengeOutput: Encodable {
        let challenge: CaptchaChallenge

        private enum CodingKeys: String, CodingKey {
            case variable = "var"
            case required, playable
            case imageType = "image_type"
            case imageURL = "image_url"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(challenge.variable, forKey: .variable)
            try container.encode(challenge.isRequired ? "true" : "false", forKey: .required)
            try container.encode(challenge.isPlayable ? "true" : "false", forKey: .playable)
            switch challenge.image {
            case let .inline(_, format):
                try container.encode(format.mimeType, forKey: .imageType)
            case let .link(url):
                try container.encode(url.absoluteString, forKey: .imageURL)
            case .unavailable:
                try container.encode("unavailable", forKey: .imageType)
            case nil:
                break
            }
        }
    }

    private struct LegacyFieldOutput: Encodable {
        let field: RegistrationField

        private enum CodingKeys: String, CodingKey {
            case name, value
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(field.name, forKey: .name)
            try container.encode(registrationFieldValueText(field), forKey: .value)
        }
    }
}
