import DuckoCore
import SwiftUI

struct DeviceFingerprintsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let peerJID: String
    let accountID: UUID

    @State private var devices: [OMEMODeviceInfo] = []
    @State private var ownDevice: OMEMODeviceInfo?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 450, minHeight: 350)
        .accessibilityIdentifier("device-fingerprints-sheet")
        .task { await loadDevices() }
    }

    private var header: some View {
        HStack {
            Text("Encryption — \(peerJID)")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ownFingerprintSection
                    peerDevicesSection
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var ownFingerprintSection: some View {
        if let ownDevice {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Device")
                        .font(.subheadline.bold())
                    Text("Device ID: \(ownDevice.deviceID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatFingerprint(ownDevice.fingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var peerDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peer Devices")
                .font(.subheadline.bold())

            if devices.isEmpty {
                Text("No known devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    deviceRow(device)
                        .accessibilityIdentifier("device-row-\(device.deviceID)")
                }
            }
        }
    }

    private func effectiveTrustLevel(of device: OMEMODeviceInfo) -> OMEMOTrustLevel {
        device.trustLevel.effective(trustOnFirstUse: OMEMOPreferences.shared.trustOnFirstUse)
    }

    private func deviceRow(_ device: OMEMODeviceInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Device \(device.deviceID)")
                        .font(.caption.bold())
                    trustBadge(effectiveTrustLevel(of: device))
                }
                if !device.fingerprint.isEmpty {
                    Text(formatFingerprint(device.fingerprint))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            trustActions(device)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func trustBadge(_ level: OMEMOTrustLevel) -> some View {
        Text(level.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(trustColor(level).opacity(0.2), in: Capsule())
            .foregroundStyle(trustColor(level))
    }

    private func trustColor(_ level: OMEMOTrustLevel) -> Color {
        switch level {
        case .verified: .green
        case .trusted: .blue
        case .undecided: .gray
        case .untrusted: .red
        }
    }

    private func trustActions(_ device: OMEMODeviceInfo) -> some View {
        HStack(spacing: 4) {
            switch effectiveTrustLevel(of: device) {
            case .undecided, .untrusted:
                Button("Trust") {
                    Task { await trust(device) }
                }
                .accessibilityIdentifier("trust-button-\(device.deviceID)")
            case .trusted:
                Button("Verify") {
                    Task { await verify(device) }
                }
                .accessibilityIdentifier("verify-button-\(device.deviceID)")
                Button("Untrust") {
                    Task { await untrust(device) }
                }
                .accessibilityIdentifier("untrust-button-\(device.deviceID)")
            case .verified:
                Button("Untrust") {
                    Task { await untrust(device) }
                }
                .accessibilityIdentifier("untrust-button-\(device.deviceID)")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Actions

    private func loadDevices() async {
        ownDevice = await environment.omemoService.ownDeviceInfo(accountID: accountID)
        devices = await environment.omemoService.deviceInfoList(for: peerJID, accountID: accountID)
        isLoading = false
    }

    private func trust(_ device: OMEMODeviceInfo) async {
        try? await environment.omemoService.trustDevice(
            accountID: accountID, peerJID: peerJID,
            deviceID: device.deviceID, fingerprint: device.fingerprint
        )
        await loadDevices()
    }

    private func untrust(_ device: OMEMODeviceInfo) async {
        try? await environment.omemoService.untrustDevice(
            accountID: accountID, peerJID: peerJID, deviceID: device.deviceID
        )
        await loadDevices()
    }

    private func verify(_ device: OMEMODeviceInfo) async {
        try? await environment.omemoService.verifyDevice(
            accountID: accountID, peerJID: peerJID,
            deviceID: device.deviceID, fingerprint: device.fingerprint
        )
        await loadDevices()
    }

    // MARK: - Formatting

    private func formatFingerprint(_ hex: String) -> String {
        OMEMODeviceInfo.formatFingerprint(hex)
    }
}
