import AppKit
import DuckoCore
import SwiftUI

/// A CAPTCHA challenge's image above its answer field: the image sent with the form, a link to one on the web, or a
/// note that Ducko can't display it.
struct CaptchaChallengeImage: View {
    let image: CaptchaChallenge.Image
    /// Whether the form names a web page to answer on instead.
    let hasFallback: Bool

    var body: some View {
        switch image {
        case let .inline(data, _):
            if let decoded = AvatarImageDecoder.decode(data, maxPixelSize: 1200) {
                Image(nsImage: decoded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: decoded.size.width, maxHeight: decoded.size.height)
                    .accessibilityLabel("CAPTCHA image")
                    .accessibilityIdentifier("registration-captcha-image")
            } else {
                unavailableNote
            }
        case let .link(url):
            Link("Open the CAPTCHA image", destination: url)
                .accessibilityIdentifier("registration-captcha-image-link")
        case .unavailable:
            unavailableNote
        }
    }

    private var unavailableNote: some View {
        Text(hasFallback ? "Ducko couldn't display the CAPTCHA image. Use the web page below to answer it." : "Ducko couldn't display the CAPTCHA image.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
