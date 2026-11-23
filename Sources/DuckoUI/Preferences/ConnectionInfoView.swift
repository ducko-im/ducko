import DuckoCore
import SwiftUI

struct ConnectionInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let tlsInfo: TLSInfo

    var body: some View {
        VStack(spacing: 0) {
            connectionDetails

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("connection-info-done-button")
            }
            .padding()
        }
        .frame(minWidth: 450)
        .containerAccessibilityIdentifier("connection-info-view")
        .onExitCommand { dismiss() }
    }

    private var connectionDetails: some View {
        Form {
            Section("TLS Connection") {
                LabeledContent("TLS Version", value: tlsInfo.protocolVersion)
                    .accessibilityIdentifier("tlsVersion")
                LabeledContent("Cipher Suite", value: tlsInfo.cipherSuite ?? "Not available")
                    .accessibilityIdentifier("cipherSuite")
            }

            Section("Certificate") {
                if let subject = tlsInfo.certificateSubject {
                    LabeledContent("Subject", value: subject)
                        .accessibilityIdentifier("certSubject")
                }
                if let issuer = tlsInfo.certificateIssuer {
                    LabeledContent("Issuer", value: issuer)
                        .accessibilityIdentifier("certIssuer")
                }
                if let expiry = tlsInfo.certificateExpiry {
                    LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("certExpiry")
                }
                if let fingerprint = tlsInfo.certificateSHA256 {
                    LabeledContent("SHA-256") {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("certFingerprint")
                }
            }
        }
        .formStyle(.grouped)
    }
}
