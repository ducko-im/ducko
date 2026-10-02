import DuckoCore
import SwiftUI

struct MessageContextMenu: View {
    let message: ChatMessage
    let windowState: ChatWindowState

    /// Buttons inside `.contextMenu { }` carry no `.accessibilityIdentifier`:
    /// SwiftUI does not reliably propagate the modifier to the bridged
    /// `kAXMenuItemRole` element on macOS 26, so identifier-based AX lookups
    /// can land on a sibling. UI integration tests select context-menu items
    /// by title via `AppAccessor.contextMenuItem(title:)`, which matches
    /// `kAXTitleAttribute` directly.
    var body: some View {
        if !message.isRetracted, !message.isUndecryptable {
            // A shared file's body is its link, and nothing of it shows as text.
            Button(message.bodyIsAttachmentLink ? "Copy Link" : "Copy") {
                copyToPasteboard(message.body)
            }

            Button("Reply") {
                windowState.startReply(to: message)
            }
        }

        let localFileURLs = message.attachments.compactMap(\.localFileURL)
        if !localFileURLs.isEmpty {
            Button("Reveal in Finder") {
                revealInFinder(localFileURLs)
            }
        }

        if message.isOutgoing, !message.isRetracted, message.stanzaID != nil {
            if !message.bodyIsAttachmentLink {
                Button("Edit") {
                    windowState.startEdit(of: message)
                }
            }

            Button("Retract") {
                Task {
                    await windowState.retractMessage(message)
                }
            }
        }

        if !message.isOutgoing, !message.isRetracted, message.serverID != nil,
           windowState.isGroupchat, windowState.myRoomRole == .moderator {
            Button("Remove Message") {
                Task {
                    await windowState.moderateMessage(message, reason: nil)
                }
            }
        }
    }
}
