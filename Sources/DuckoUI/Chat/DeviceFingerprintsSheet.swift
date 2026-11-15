import DuckoCore
import Logging
import SwiftUI

private let log = Logger(label: "im.ducko.ui.devicefingerprints")

struct DeviceFingerprintsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let peerJID: String
    let accountID: UUID

    @State private var devices: [OMEMODeviceInfo] = []
    @State private var ownDevice: OMEMODeviceInfo?
    @State private var otherOwnDevices: [OMEMODeviceInfo] = []
    @State private var isLoading = true
    @State private var resetStatus: ResetStatus?

    /// What the last reset did, shown under the device's row until the next action. A device that is no longer listed
    /// has no row, so its status shows above the sections instead.
    private struct ResetStatus {
        let deviceInfoID: String
        let deviceID: UInt32
        let text: String
        let isProblem: Bool
        /// Whether `text` names the device, as a report's summary does. An error's text does not.
        let namesDevice: Bool

        /// The status away from the device's row, which has to say which device it is about.
        var standaloneText: String {
            namesDevice ? text : "Device \(deviceID): \(text)"
        }
    }

    /// The last reset's status when its device has no row to show it under.
    private var unlistedResetStatus: ResetStatus? {
        guard let resetStatus, !(otherOwnDevices + devices).contains(where: { $0.id == resetStatus.deviceInfoID }) else { return nil }
        return resetStatus
    }

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
                    if let unlistedResetStatus {
                        resetStatusCaption(unlistedResetStatus, text: unlistedResetStatus.standaloneText)
                    }
                    ownFingerprintSection
                    otherOwnDevicesSection
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

    @ViewBuilder
    private var otherOwnDevicesSection: some View {
        if !otherOwnDevices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Other Devices")
                    .font(.subheadline.bold())
                deviceRows(otherOwnDevices)
            }
        }
    }

    private var peerDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contact's Devices")
                .font(.subheadline.bold())

            if devices.isEmpty {
                Text("No known devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                deviceRows(devices)
            }
        }
    }

    private func deviceRows(_ devices: [OMEMODeviceInfo]) -> some View {
        ForEach(devices) { device in
            deviceRow(device)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("device-row-\(device.deviceID)")
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
                if let resetStatus, resetStatus.deviceInfoID == device.id {
                    resetStatusCaption(resetStatus, text: resetStatus.text)
                }
            }

            Spacer()

            trustActions(device)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func resetStatusCaption(_ status: ResetStatus, text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
            .accessibilityIdentifier("reset-status-\(status.deviceID)")
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
                // Verifying compares a fingerprint, so it waits until one is known.
                if !device.fingerprint.isEmpty {
                    Button("Verify") {
                        Task { await verify(device) }
                    }
                    .accessibilityIdentifier("verify-button-\(device.deviceID)")
                }
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
            Button("Reset Session") {
                Task { await resetSession(device) }
            }
            .accessibilityIdentifier("reset-session-button-\(device.deviceID)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: - Actions

    private func loadDevices() async {
        let ownDevice = await environment.omemoService.ownDeviceInfo(accountID: accountID)
        self.ownDevice = ownDevice
        if let ownDevice {
            otherOwnDevices = await environment.omemoService.deviceInfoList(for: ownDevice.peerJID, accountID: accountID)
                .filter { $0.deviceID != ownDevice.deviceID }
        } else {
            otherOwnDevices = []
        }
        devices = await environment.omemoService.deviceInfoList(for: peerJID, accountID: accountID)
        isLoading = false
    }

    private func trust(_ device: OMEMODeviceInfo) async {
        resetStatus = nil
        try? await environment.omemoService.trustDevice(
            accountID: accountID, peerJID: device.peerJID,
            deviceID: device.deviceID, fingerprint: device.fingerprint
        )
        await loadDevices()
    }

    private func untrust(_ device: OMEMODeviceInfo) async {
        resetStatus = nil
        try? await environment.omemoService.untrustDevice(
            accountID: accountID, peerJID: device.peerJID, deviceID: device.deviceID
        )
        await loadDevices()
    }

    private func verify(_ device: OMEMODeviceInfo) async {
        resetStatus = nil
        try? await environment.omemoService.verifyDevice(
            accountID: accountID, peerJID: device.peerJID,
            deviceID: device.deviceID, fingerprint: device.fingerprint
        )
        await loadDevices()
    }

    /// The row shows what the reset did, since only the chat with a contact notes it and the account's other devices
    /// have no chat.
    private func resetSession(_ device: OMEMODeviceInfo) async {
        resetStatus = nil
        do {
            // A reset of one device reports that device alone.
            let report = try await environment.omemoService.resetSessions(peerJID: device.peerJID, deviceID: device.deviceID, accountID: accountID)
            if let reset = report.devices.first {
                resetStatus = ResetStatus(
                    deviceInfoID: device.id, deviceID: device.deviceID, text: reset.summary, isProblem: reset.needsAttention, namesDevice: true
                )
            }
        } catch {
            resetStatus = ResetStatus(
                deviceInfoID: device.id, deviceID: device.deviceID, text: error.localizedDescription, isProblem: true, namesDevice: false
            )
            log.warning("An encryption session could not be reset")
            log.debug("Resetting the session with device \(device.deviceID) failed with: \(error)")
        }
        await loadDevices()
    }

    // MARK: - Formatting

    private func formatFingerprint(_ hex: String) -> String {
        OMEMODeviceInfo.formatFingerprint(hex)
    }
}
