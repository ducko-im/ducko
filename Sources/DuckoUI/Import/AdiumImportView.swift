import DuckoCore
import SwiftUI

public struct AdiumImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var logsURL: URL = AdiumLogDiscovery.defaultLogsURL
    @State private var sources: [AdiumServiceAccount]?
    @State private var isDiscovering = false
    @State private var isImporting = false
    @State private var progress: AdiumImportService.ImportProgress?
    @State private var result: AdiumImportService.ImportProgress?

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Text("Import Adium Logs")
                .font(.headline)

            if let result {
                completionView(result)
            } else if isImporting, let progress {
                importingView(progress)
            } else if let sources {
                discoveryView(sources)
            } else {
                pathSelectionView
            }
        }
        .padding(24)
        .frame(minWidth: 450)
    }

    // MARK: - Subviews

    private var pathSelectionView: some View {
        VStack(spacing: 12) {
            Text("Select the Adium logs directory to import.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Logs path", text: Binding(
                    get: { logsURL.path },
                    set: { logsURL = URL(fileURLWithPath: $0) }
                ))
                .textFieldStyle(.roundedBorder)

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = logsURL
                    if panel.runModal() == .OK, let url = panel.url {
                        logsURL = url
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Scan") {
                    Task { await discover() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isDiscovering)
            }
        }
    }

    private func discoveryView(_ sources: [AdiumServiceAccount]) -> some View {
        VStack(spacing: 12) {
            let totalFiles = sources.reduce(0) { $0 + $1.fileCount }
            Text("Found \(sources.count) account(s), \(totalFiles) log file(s)")
                .foregroundStyle(.secondary)

            List {
                ForEach(sources, id: \.directoryURL) { source in
                    HStack {
                        Text("\(source.service).\(source.accountUID)")
                        Spacer()
                        Text("\(source.contactDirectories.count) contacts, \(source.fileCount) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 200)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task { await performImport(sources) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func importingView(_ progress: AdiumImportService.ImportProgress) -> some View {
        AdiumImportProgressView(progress: progress)
    }

    private func completionView(_ result: AdiumImportService.ImportProgress) -> some View {
        VStack(spacing: 12) {
            AdiumImportCompletionView(result: result)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }

        do {
            let discovered = try AdiumLogDiscovery.discoverSources(at: logsURL)
            sources = discovered
        } catch {
            sources = []
        }
    }

    private func performImport(_ sources: [AdiumServiceAccount]) async {
        isImporting = true
        let importService = AdiumImportService(store: environment.store, transcripts: environment.transcripts)

        do {
            result = try await importService.importLogs(from: sources) { p in
                Task { @MainActor in
                    progress = p
                }
            }
        } catch {
            result = .failure(error: error)
        }
        isImporting = false
    }
}
