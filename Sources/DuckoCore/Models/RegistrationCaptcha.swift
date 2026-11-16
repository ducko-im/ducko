import DuckoXMPP
import Foundation

/// The XEP-0158 CAPTCHA a registration form carries: the challenges the user answers, a proof of work Ducko answers
/// itself, and the server's fallback web page.
public struct RegistrationCaptcha: Sendable {
    /// One challenge per user-answered field, in form order.
    public internal(set) var challenges: [CaptchaChallenge]
    /// How many challenges the server wants answered, from its hidden `answers` field.
    public let answersRequired: Int?
    public internal(set) var proofOfWork: CaptchaProofOfWork?
    /// The server's text pointing to its fallback web page.
    public internal(set) var fallbackText: String?
    /// The fallback page's address as the server sent it. `fallbackLink` holds it when it is a web address, else it
    /// shows as text.
    public internal(set) var fallbackURLText: String?
    /// What the fallback page is called: the server's label for its field, else "CAPTCHA web page".
    public let fallbackLabel: String
    /// Whether the required challenges were exactly `ocr` and `SHA-256`, with no `answers` field. ejabberd checks only
    /// the proof of work then, when it has a value.
    let requiredChallengesAreImageAndProofOfWork: Bool

    /// The XEP-0158 challenge field types.
    static let challengeVariables: Set = [
        "audio_recog", "ocr", "picture_q", "picture_recog", "qa", proofOfWorkVariable, "speech_q", "speech_recog",
        "video_q", "video_recog"
    ]
    static let proofOfWorkVariable = "SHA-256"
    static let fallbackTextVariable = "captcha-fallback-text"
    static let fallbackURLVariable = "captcha-fallback-url"

    /// The form's CAPTCHA, or nil for a form that has no hidden `challenge` field or no known challenge.
    init?(form: DataForm, bitsOfBinary: [BitsOfBinaryData]) {
        let fields = form.fields
        guard fields.contains(where: { $0.variable == "challenge" && $0.type == "hidden" }),
              fields.contains(where: { $0.variable.map(Self.challengeVariables.contains) ?? false })
        else { return nil }

        func value(of variable: String) -> String? {
            fields.first { $0.variable == variable }?.values.first
        }

        self.challenges = fields.compactMap { field in
            guard let variable = field.variable, variable != Self.proofOfWorkVariable, Self.challengeVariables.contains(variable) else { return nil }
            return CaptchaChallenge(
                variable: variable,
                isRequired: field.isRequired,
                image: Self.image(for: field.media, bitsOfBinary: bitsOfBinary)
            )
        }
        self.answersRequired = value(of: "answers").flatMap { Int($0) }
        self.proofOfWork = fields.first { $0.variable == Self.proofOfWorkVariable }.map {
            CaptchaProofOfWork(label: $0.label ?? "", prefix: value(of: "from"), isRequired: $0.isRequired)
        }
        let fallbackText = fields.first { $0.variable == Self.fallbackTextVariable }?.values.joined(separator: "\n")
        self.fallbackText = fallbackText?.isBlank == false ? fallbackText : nil
        self.fallbackURLText = value(of: Self.fallbackURLVariable).flatMap { $0.isBlank ? nil : $0 }
        let fallbackLabel = fields.first { $0.variable == Self.fallbackURLVariable }?.label
        self.fallbackLabel = fallbackLabel.flatMap { $0.isBlank ? nil : $0 } ?? "CAPTCHA web page"
        let requiredVariables = Set(fields.filter(\.isRequired).compactMap(\.variable).filter(Self.challengeVariables.contains))
        self.requiredChallengesAreImageAndProofOfWork = requiredVariables == ["ocr", Self.proofOfWorkVariable] && answersRequired == nil
    }

    /// The fallback page as a link the user may open, which only a web address is.
    public var fallbackLink: URL? {
        fallbackURLText.flatMap(URL.init(string:)).flatMap { $0.isWebAddress ? $0 : nil }
    }

    /// The field's image: the first sent inline whose bytes are of a format Ducko shows and match its declared type,
    /// else the first on the web, else `.unavailable` when one was named by content ID, else nil.
    private static func image(for media: [DataFormMediaURI], bitsOfBinary: [BitsOfBinaryData]) -> CaptchaChallenge.Image? {
        let images = media.filter { $0.type.lowercased().hasPrefix("image/") }
        let contentIDs = images.compactMap { $0.uri.lowercased().hasPrefix("cid:") ? String($0.uri.dropFirst(4)) : nil }
        for contentID in contentIDs {
            guard let data = bitsOfBinary.first(where: { $0.cid == contentID }),
                  let format = CaptchaImageFormat(signatureOf: data.bytes), format.mimeType == mediaType(of: data.type)
            else { continue }
            return .inline(Data(data.bytes), format: format)
        }
        if let link = images.lazy.compactMap({ URL(string: $0.uri) }).first(where: \.isWebAddress) {
            return .link(link)
        }
        return contentIDs.isEmpty ? nil : .unavailable
    }

    /// A MIME type's type and subtype, lowercased and without the parameters XEP-0231 lets it carry.
    private static func mediaType(of mimeType: String) -> String {
        String(mimeType.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Satisfiability

    /// Whether Ducko can't answer this CAPTCHA, even with every remaining challenge answered.
    public var isUnanswerable: Bool {
        rejectsUnsolvedProofOfWork || challenges.count + solvedProofOfWorkCount < answersNeeded
    }

    /// Whether the CAPTCHA is answered, given the variables of the challenge fields that hold a value.
    func isSatisfied(answered: Set<String>) -> Bool {
        guard !isUnanswerable,
              challenges.allSatisfy({ !$0.isRequired || answered.contains($0.variable) })
        else { return false }
        return challenges.count(where: { answered.contains($0.variable) }) + solvedProofOfWorkCount >= answersNeeded
    }

    /// A required proof of work left unsolved can't be answered, except on a form whose image answers instead.
    private var rejectsUnsolvedProofOfWork: Bool {
        guard let proofOfWork, proofOfWork.isRequired, proofOfWork.answer == nil else { return false }
        return !requiredChallengesAreImageAndProofOfWork
    }

    /// How many challenges have to be answered: the largest of the server's count, the number required, and one, since
    /// the sender answers at least one challenge (XEP-0158 §3.1.3).
    private var answersNeeded: Int {
        let requiredChallenges = challenges.count(where: \.isRequired) + (proofOfWork?.isRequired == true ? solvedProofOfWorkCount : 0)
        return max(answersRequired ?? 0, requiredChallenges, 1)
    }

    private var solvedProofOfWorkCount: Int {
        proofOfWork?.answer == nil ? 0 : 1
    }

    // MARK: - Proof of Work

    /// Answers the proof of work. When `allowsSkippingImage` and the required challenges are exactly the image and the
    /// proof of work, a solved one replaces the image, so the image challenge and the fallback text and link go.
    /// Returns the variables of the challenge fields that went, for the form to drop.
    mutating func answerProofOfWork(prefixFallback: String, allowsSkippingImage: Bool) async -> Set<String> {
        guard let proofOfWork else { return [] }
        self.proofOfWork?.answer = await CaptchaProofOfWorkSolver.solve(prefix: proofOfWork.prefix ?? prefixFallback, label: proofOfWork.label)
        guard self.proofOfWork?.answer != nil, allowsSkippingImage, requiredChallengesAreImageAndProofOfWork else { return [] }
        challenges.removeAll { $0.variable == "ocr" }
        fallbackText = nil
        fallbackURLText = nil
        return ["ocr"]
    }
}

/// One CAPTCHA challenge the user answers in its form field.
public struct CaptchaChallenge: Sendable {
    public enum Image: Sendable {
        /// An image sent with the form, whose bytes are of `format`.
        case inline(Data, format: CaptchaImageFormat)
        /// An image on the web, which Ducko opens in the browser and never fetches itself.
        case link(URL)
        /// An image named by content ID that can't be shown: its data didn't arrive, or isn't of a format Ducko shows.
        case unavailable
    }

    /// The challenge type, which is also the `var` of its field.
    public let variable: String
    public let isRequired: Bool
    public let image: Image?

    private static let unplayableVariables: Set = ["audio_recog", "speech_q", "speech_recog", "video_q", "video_recog"]

    /// Whether Ducko can present the challenge, which it can't for audio and video.
    public var isPlayable: Bool {
        !Self.unplayableVariables.contains(variable)
    }

    public var fieldID: RoomConfigField.FieldID {
        .variable(variable)
    }
}

/// An image format Ducko shows a CAPTCHA in, recognized by its bytes' signature rather than by the type the server
/// declares, so only these formats reach the image decoder.
public enum CaptchaImageFormat: Sendable {
    case png
    case jpeg
    case gif

    init?(signatureOf bytes: [UInt8]) {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else {
            return nil
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .gif: "image/gif"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        }
    }
}

/// A SHA-256 proof of work: an answer whose digest ends with the label's hex digits.
public struct CaptchaProofOfWork: Sendable {
    public let label: String
    /// The JID the answer starts with, from the form's hidden `from` field.
    public let prefix: String?
    public let isRequired: Bool
    public internal(set) var answer: String?
}
