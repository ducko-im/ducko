import SwiftUI

/// What allowing an account to send its password to a server offering only PLAIN risks.
let plainAllowanceWarning = """
Anyone intercepting the connection could read the password. Ducko turns this off again after a sign-in that doesn't \
send it.
"""

/// Offers an add form's refused first sign-in again with PLAIN allowed. The form shows the refusal itself.
struct PlainRefusalRetry: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(plainAllowanceWarning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Sending Password and Sign In", action: retry)
                .accessibilityIdentifier("plain-refusal-allow")
        }
    }
}
