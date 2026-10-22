import DuckoCore
import SwiftUI

/// Shared progress indicator for Adium log import.
struct AdiumImportProgressView: View {
    let progress: AdiumImportService.ImportProgress

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress.completedFiles), total: Double(max(progress.totalFiles, 1)))

            Text("\(progress.completedFiles) / \(progress.totalFiles) files")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(progress.importedMessages) messages imported")
                .font(.caption)
        }
    }
}

/// Shared completion view for Adium import. Shows checkmark (or a warning when every account it tried failed to
/// connect), stats, and optional account results.
/// Does NOT include action buttons — parents add their own "Done" button.
struct AdiumImportCompletionView: View {
    struct AccountResult: Identifiable {
        let id: String
        let jid: String
        let success: Bool
        let error: String?
    }

    let result: AdiumImportService.ImportProgress?
    var accountResults: [AccountResult] = []

    private static let visibleErrorLimit = 5

    private var succeededCount: Int {
        accountResults.filter(\.success).count
    }

    private var noAccountConnected: Bool {
        !accountResults.isEmpty && succeededCount == 0
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: noAccountConnected ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(noAccountConnected ? .orange : .green)

            Text(noAccountConnected ? "No Accounts Connected" : "Import Complete")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                if !accountResults.isEmpty {
                    Text("Accounts connected: \(succeededCount)/\(accountResults.count)")
                }
                if let result {
                    Text("Messages imported: \(result.importedMessages)")
                    Text("Duplicates skipped: \(result.skippedDuplicates)")
                    if !result.errors.isEmpty {
                        Text("Errors: \(result.errors.count)")
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)

            let failedAccounts = accountResults.filter { !$0.success }
            let errors = result?.errors ?? []
            if !failedAccounts.isEmpty || !errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(failedAccounts) { account in
                        Text("\(account.jid): \(account.error ?? "Failed")")
                            .foregroundStyle(.red)
                    }
                    // Errors are a static, append-only list with no identity of their own.
                    ForEach(errors.prefix(Self.visibleErrorLimit).indices, id: \.self) { index in
                        Text(errors[index].displayText)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    if errors.count > Self.visibleErrorLimit {
                        Text("…and \(errors.count - Self.visibleErrorLimit) more")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }
}
