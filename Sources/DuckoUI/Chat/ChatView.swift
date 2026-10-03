import DuckoCore
import SwiftUI

struct ChatView: View {
    let windowState: ChatWindowState

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = windowState.conversation {
                ChatHeaderView(conversation: windowState.liveConversation ?? conversation, windowState: windowState)

                Divider()

                if windowState.isGroupchat {
                    RoomSubjectView(windowState: windowState)

                    Divider()
                }
            }

            IncomingFileTransferBanner()

            if windowState.isSearching {
                MessageSearchBar(windowState: windowState)

                Divider()
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LoadHistoryErrorBanner(windowState: windowState)

                    MessageListView(windowState: windowState)

                    TransferProgressView(accountID: windowState.resolvedAccountID)

                    Divider()

                    MessageInputView(windowState: windowState)
                }

                if windowState.isGroupchat, windowState.showParticipantSidebar {
                    Divider()

                    ParticipantSidebar(roomJIDString: windowState.jidString, roomNickname: windowState.liveConversation?.roomNickname, accountID: windowState.accountID)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .fileDropTarget(windowState: windowState)
        .animation(.easeInOut(duration: 0.2), value: windowState.showParticipantSidebar)
    }
}
