import AppKit
import DuckoCore
import SwiftUI

struct AdvancedPreferencesView: View {
    @State private var preferences = AdvancedPreferences()

    var body: some View {
        Form {
            Section("Data") {
                LabeledContent("Data Location") {
                    HStack {
                        Text(preferences.dataLocation.path(percentEncoded: false))
                            .foregroundStyle(.secondary)
                            .singleLine()
                            .truncationMode(.middle)

                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: preferences.dataLocation.path(percentEncoded: false))
                        }
                    }
                }
            }

            Section("Logging") {
                Picker("Log Level", selection: Bindable(preferences).logLevel) {
                    Text("Default").tag(LogLevelPreference.standard)
                    Text("Debug").tag(LogLevelPreference.debug)
                    Text("Verbose").tag(LogLevelPreference.verbose)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}
