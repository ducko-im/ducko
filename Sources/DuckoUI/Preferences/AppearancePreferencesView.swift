import DuckoCore
import SwiftUI

struct AppearancePreferencesView: View {
    @AppStorage(ContactListSizingDefaults.compactKey, store: PreferencesDefaults.store)
    private var isCompact = false
    @AppStorage(ContactListSizingDefaults.autoSizeVerticalKey, store: PreferencesDefaults.store)
    private var autoSizeVertical = true
    @AppStorage(ContactListSizingDefaults.autoSizeHorizontalKey, store: PreferencesDefaults.store)
    private var autoSizeHorizontal = true
    @AppStorage(ContactListSizingDefaults.maxWidthKey, store: PreferencesDefaults.store)
    private var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth

    /// The Maximum Width preference normalized into the slider's valid range, so
    /// a corrupted persisted value never reaches the slider or the `Int(...)` label.
    private var clampedMaxWidth: Binding<Double> {
        Binding(
            get: { ContactListSizing.clampMaxWidth(maxWidthPreference) },
            set: { maxWidthPreference = ContactListSizing.clampMaxWidth($0) }
        )
    }

    var body: some View {
        Form {
            Section("Contact List") {
                Toggle("Compact rows", isOn: $isCompact)
                    .accessibilityIdentifier("contacts-compact-toggle")

                Toggle("Size to fit vertically", isOn: $autoSizeVertical)
                    .accessibilityIdentifier("contacts-autosize-vertical-toggle")

                Toggle("Size to fit horizontally", isOn: $autoSizeHorizontal)
                    .accessibilityIdentifier("contacts-autosize-horizontal-toggle")

                LabeledContent("Maximum Width") {
                    HStack {
                        // Clamp through the same guard the window uses so a
                        // corrupted persisted value (NaN/out-of-range) can't trap
                        // `Int(...)` or push the slider out of range here.
                        Slider(
                            value: clampedMaxWidth,
                            in: ContactListSizingDefaults.sliderMinWidth ... ContactListSizingDefaults.sliderMaxWidth
                        )
                        Text("\(Int(clampedMaxWidth.wrappedValue)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!autoSizeHorizontal)
                .accessibilityIdentifier("contacts-max-width-slider")
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}
