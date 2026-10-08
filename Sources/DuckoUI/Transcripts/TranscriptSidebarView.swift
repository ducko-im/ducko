import DuckoCore
import SwiftUI

struct TranscriptSidebarView: View {
    private static let collapsedSectionsKey = "transcriptCollapsedSections"

    @Bindable var state: TranscriptViewerState
    /// The keys of the collapsed sections, as a JSON array. A section missing from it is expanded.
    @AppStorage(TranscriptSidebarView.collapsedSectionsKey, store: PreferencesDefaults.store) private var collapsedSectionsStorage = "[]"

    /// The generation of the list that has been given its selection.
    @State private var selectedListGeneration = 0

    private var collapsedSections: Set<String> {
        Set(jsonArray: collapsedSectionsStorage)
    }

    var body: some View {
        List(selection: Binding(
            // A list built with a row below its first section already selected keeps that row painted when another
            // is selected. So a list built anew starts with no selection and gets it once it is there.
            get: { selectedListGeneration == state.sidebarListGeneration ? state.sidebarSelection : nil },
            set: { state.select($0) }
        )) {
            ForEach(state.sidebarSections) { section in
                TranscriptSidebarSectionView(section: section, state: state, isExpanded: isExpanded(section))
            }
        }
        .id(state.sidebarListGeneration)
        .task(id: state.sidebarListGeneration) {
            selectedListGeneration = state.sidebarListGeneration
        }
        .takesKeyboardOnClick()
        .searchable(text: $state.sidebarFilter, placement: .sidebar, prompt: "Filter conversations")
    }

    private func isExpanded(_ section: TranscriptSidebarSection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(section.collapseKey) },
            set: { isExpanded in
                var collapsed = collapsedSections
                if isExpanded {
                    collapsed.remove(section.collapseKey)
                } else {
                    collapsed.insert(section.collapseKey)
                }
                collapsedSectionsStorage = collapsed.jsonArray
            }
        )
    }
}

// MARK: - Section

private struct TranscriptSidebarSectionView: View {
    let section: TranscriptSidebarSection
    let state: TranscriptViewerState
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(section.conversations) { conversation in
                TranscriptSidebarRow(conversation: conversation, avatarData: state.avatarData(for: conversation))
                    .tag(TranscriptSelection.conversation(conversation.id))
            }
        } label: {
            Text(section.title)
                .fontWeight(.semibold)
                .tag(section.selection)
        }
    }
}
