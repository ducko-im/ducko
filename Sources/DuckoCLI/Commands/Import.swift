import ArgumentParser
import DuckoCore
import Foundation

extension DuckoCLI {
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import chat history from other clients",
            subcommands: [Adium.self]
        )

        struct Adium: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Import Adium chat logs"
            )

            @Option(name: .long, help: "Path to Adium logs directory")
            var path: String?

            @Flag(name: .long, help: "Scan and report without importing")
            var dryRun: Bool = false

            func run() async throws {
                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }

                let logsURL: URL = if let path {
                    URL(fileURLWithPath: path)
                } else {
                    AdiumLogDiscovery.defaultLogsURL
                }

                print("Scanning \(logsURL.path)…")
                let sources = try AdiumLogDiscovery.discoverSources(at: logsURL)

                if sources.isEmpty {
                    print("No Adium logs found.")
                    return
                }

                let totalFiles = sources.reduce(0) { $0 + $1.fileCount }
                print("\nDiscovered \(sources.count) account(s), \(totalFiles) log file(s):\n")
                for source in sources {
                    print("  \(source.service).\(source.accountUID): \(source.contactDirectories.count) contact(s), \(source.fileCount) file(s)")
                }
                print()

                if dryRun {
                    print("Dry run — no changes made.")
                    return
                }

                print("Importing…")
                let importService = AdiumImportService(store: context.environment.store, transcripts: context.environment.transcripts)
                let result = try await importService.importLogs(from: sources) { progress in
                    let pct = progress.totalFiles > 0
                        ? Int(Double(progress.completedFiles) / Double(progress.totalFiles) * 100)
                        : 0
                    print("  [\(pct)%] \(progress.completedFiles)/\(progress.totalFiles) files, \(progress.importedMessages) messages imported")
                }

                print("\nImport complete:")
                print("  Messages imported: \(result.importedMessages)")
                print("  Duplicates skipped: \(result.skippedDuplicates)")
                if !result.errors.isEmpty {
                    print("  Errors: \(result.errors.count)")
                    for error in result.errors.prefix(10) {
                        print("    \(error.displayText)")
                    }
                    if result.errors.count > 10 {
                        print("    … and \(result.errors.count - 10) more")
                    }
                }
            }
        }
    }
}
