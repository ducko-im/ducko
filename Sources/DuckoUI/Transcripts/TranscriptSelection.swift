import DuckoCore
import Foundation

/// What is selected in the history window's left list.
enum TranscriptSelection: Hashable {
    case account(UUID)
    /// The address of the account an imported history came from.
    case importSource(String)
    case conversation(UUID)
}

/// An account or an imported history in the left list, with the conversations whose rows it shows.
struct TranscriptSidebarSection: Identifiable {
    let selection: TranscriptSelection
    let title: String
    /// The key its collapsed state is stored under.
    let collapseKey: String
    let conversations: [Conversation]

    var id: TranscriptSelection {
        selection
    }
}

/// A day and the messages on it that a search found, by id, in the order the day shows them.
struct TranscriptDayMatches: Equatable {
    let day: TranscriptDay
    let messageIDs: [UUID]
}
