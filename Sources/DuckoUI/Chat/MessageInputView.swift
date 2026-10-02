import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    /// The numeric keypad's Enter key, which is a different key from Return.
    private static let keypadEnter = KeyEquivalent("\u{3}")

    @Bindable var windowState: ChatWindowState
    @State private var isSending = false
    @State private var selection: TextSelection?
    @FocusState private var isInputFocused: Bool

    private var trimmedText: String {
        windowState.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmedText.isEmpty || !windowState.pendingAttachments.isEmpty) && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            SendErrorBanner(windowState: windowState)

            ReplyComposeBar(windowState: windowState)

            PendingAttachmentBar(windowState: windowState)

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    windowState.showFileImporter()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("attachment-button")

                TextField("Message", text: $windowState.draftText, selection: $selection, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .onKeyPress(keys: [.return, Self.keypadEnter], phases: .down) { keyPress in
                        if keyPress.modifiers.isDisjoint(with: [.shift, .option]) {
                            sendMessage()
                        } else {
                            insertLineBreak()
                        }
                        return .handled
                    }
                    .onChange(of: windowState.draftText) {
                        guard !windowState.draftText.isEmpty else { return }
                        Task { await windowState.userIsTyping() }
                    }
                    .onChange(of: windowState.editingMessage?.id) {
                        if let editing = windowState.editingMessage {
                            windowState.draftText = editing.body
                            isInputFocused = true
                        }
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { providers in
                        handlePaste(providers)
                    }
                    .focused($isInputFocused)
                    .accessibilityIdentifier("message-field")
                    .onAppear { isInputFocused = true }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("send-button")
            }
            .padding(12)
        }
        .fileImporter(
            isPresented: $windowState.isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
    }

    /// The field inserts no line break for these keys itself. Replaces the selection with one and leaves the cursor
    /// after it. Without a single selected range, the line break goes at the end.
    private func insertLineBreak() {
        var text = windowState.draftText
        var selected = text.endIndex ..< text.endIndex
        if case let .selection(range) = selection?.indices {
            selected = range.clamped(to: text.startIndex ..< text.endIndex)
        }
        // Counted in UTF-16, because a line break after a carriage return joins it into one character.
        let cursorOffset = text.utf16.distance(from: text.startIndex, to: selected.lowerBound) + 1
        text.replaceSubrange(selected, with: "\n")
        windowState.draftText = text
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: cursorOffset, in: text))
    }

    private func sendMessage() {
        let body = trimmedText
        let hasAttachments = !windowState.pendingAttachments.isEmpty

        guard !body.isEmpty || hasAttachments else { return }
        windowState.draftText = ""
        isSending = true

        Task {
            if hasAttachments {
                await windowState.sendAttachments()
            }
            if !body.isEmpty {
                await windowState.sendMessage(body)
            }
            // Restore composer text only on typed send errors (e.g. encryption-required-but-no-trusted-devices); untyped failures leave the composer empty.
            if windowState.lastSendError != nil, let failedBody = windowState.lastFailedSendBody {
                windowState.draftText = failedBody
            }
            isSending = false
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            // Copy to temp so the security-scoped bookmark isn't needed later
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            windowState.addAttachment(url: dest)
        }
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                windowState.loadFileURL(from: provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let tempDir = FileManager.default.temporaryDirectory
                    let fileName = "pasted-image-\(UUID().uuidString).png"
                    let tempURL = tempDir.appendingPathComponent(fileName)
                    do {
                        try data.write(to: tempURL)
                        Task { @MainActor in
                            windowState.addAttachment(url: tempURL)
                        }
                    } catch {}
                }
            }
        }
    }
}
