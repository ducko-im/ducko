import AppKit
import SwiftUI

/// Puts the chat window's keyboard where `ChatKeyboardPolicy` says when the user comes back to the window, when
/// another tab is picked, and once a sheet, a quiet opening or a search has ended. `requestMessageField` and
/// `requestSearchField` ask the selected tab's message field or find bar field to take the keyboard. A key typed while
/// nothing that takes text has the keyboard goes to `messageField`.
struct ChatKeyboardKeeper: NSViewRepresentable {
    let selectedKey: ConversationKey?
    let isOpeningQuietly: Bool
    /// Whether the selected tab's find bar is shown.
    let isSearching: Bool
    let messageField: MessageFieldReference
    let requestMessageField: () -> Void
    let requestSearchField: () -> Void

    func makeNSView(context _: Context) -> ChatKeyboardKeeperView {
        ChatKeyboardKeeperView(selectedKey: selectedKey, isOpeningQuietly: isOpeningQuietly, isSearching: isSearching, messageField: messageField)
    }

    func updateNSView(_ view: ChatKeyboardKeeperView, context _: Context) {
        view.requestMessageField = requestMessageField
        view.requestSearchField = requestSearchField
        view.update(selectedKey: selectedKey, isOpeningQuietly: isOpeningQuietly, isSearching: isSearching)
    }
}

// MARK: - ChatKeyboardKeeperView

/// Finds the window it is in and follows that window gaining and losing the keyboard, and the keys typed in it.
final class ChatKeyboardKeeperView: NSView {
    var requestMessageField: () -> Void = {}
    var requestSearchField: () -> Void = {}
    private let messageField: MessageFieldReference
    private var selectedKey: ConversationKey?
    private var isOpeningQuietly: Bool
    private var isSearching: Bool
    /// Set when the window opens, another tab is picked or the find bar closes, until a field of the shown tab is asked
    /// to take the keyboard, or something else the user types in keeps it.
    private var isFieldDue = false
    /// What had the keyboard when the window last lost it.
    private var savedFocus: KeyboardFocus?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    init(selectedKey: ConversationKey?, isOpeningQuietly: Bool, isSearching: Bool, messageField: MessageFieldReference) {
        self.selectedKey = selectedKey
        self.isOpeningQuietly = isOpeningQuietly
        self.isSearching = isSearching
        self.messageField = messageField
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        stopObserving()
    }

    func update(selectedKey: ConversationKey?, isOpeningQuietly: Bool, isSearching: Bool) {
        let pickedTab = selectedKey != self.selectedKey
        let quietOpeningEnded = self.isOpeningQuietly && !isOpeningQuietly
        // The find bar's field took the keyboard, and goes with the bar.
        let searchEnded = !pickedTab && self.isSearching && !isSearching
        self.selectedKey = selectedKey
        self.isOpeningQuietly = isOpeningQuietly
        self.isSearching = isSearching
        if pickedTab {
            // What had the keyboard belongs to the tab that was left, whose views the new tab reuses.
            savedFocus = nil
        }
        if pickedTab || searchEnded {
            isFieldDue = true
        }
        if pickedTab || quietOpeningEnded || searchEnded {
            reconcileAfterUpdate()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        isFieldDue = true
        observe(NSWindow.didBecomeKeyNotification, of: window) { $0.reconcile() }
        observe(NSWindow.didResignKeyNotification, of: window) { $0.saveFocus() }
        observe(NSWindow.didEndSheetNotification, of: window) { $0.reconcileAfterUpdate() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return redirectTyping(event)
        }
        // The window can have the keyboard already.
        reconcileAfterUpdate()
    }

    /// Waits for the views to show the change first, so a newly picked tab's field is the one asked.
    private func reconcileAfterUpdate() {
        Task { [weak self] in self?.reconcile() }
    }

    private func reconcile() {
        guard let window else { return }
        let action = ChatKeyboardPolicy.action(
            isKey: window.isKeyWindow,
            hasSheet: window.attachedSheet != nil,
            isOpeningQuietly: isOpeningQuietly,
            holder: keyboardHolder(in: window),
            dueField: isFieldDue ? ChatKeyboardPolicy.Field(isSearching: isSearching) : nil
        )
        switch action {
        case .leave:
            return
        case .keepTextInput:
            isFieldDue = false
        case .restore:
            savedFocus?.restore(in: window)
            if !Self.isKeyboardHeld(in: window) {
                focusMessageField()
            }
        case .focus(.message):
            focusMessageField()
        case .focus(.search):
            isFieldDue = false
            requestSearchField()
        }
    }

    private func focusMessageField() {
        isFieldDue = false
        requestMessageField()
    }

    private func keyboardHolder(in window: NSWindow) -> ChatKeyboardPolicy.Holder {
        guard Self.isKeyboardHeld(in: window), let responder = window.firstResponder else { return .window }
        guard ChatTypingPolicy.takesText(responder) else { return .view }
        let isMessageField = messageField.field.map { responder === $0.currentEditor() || responder === $0 } ?? false
        return isMessageField ? .view : .otherTextInput
    }

    /// Hands the message field the keyboard when `event` types text that nothing in the window would take, so the
    /// event then reaches the field as if typed in it.
    private func redirectTyping(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              ChatTypingPolicy.redirectsToMessageField(
                  ChatTypingPolicy.Key(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.characters ?? ""),
                  in: ChatTypingPolicy.WindowState(
                      isKey: window.isKeyWindow, isOpeningQuietly: isOpeningQuietly, hasSheet: window.attachedSheet != nil
                  ),
                  responderTakesText: ChatTypingPolicy.takesText(window.firstResponder),
                  spaceActivatesControls: NSApp.isFullKeyboardAccessEnabled
              ),
              let field = messageField.field, window.makeFirstResponder(field), let editor = field.currentEditor() else {
            return event
        }
        // Taking the keyboard selects the whole draft, which the key would replace.
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        // The field catches up with taking the keyboard in the window's next layout pass, where it sets its
        // selection again. Left until after the key, that would put a dead key's accent in on its own instead of
        // joining the next key, so the pass runs before the key reaches the field.
        window.contentView?.layoutSubtreeIfNeeded()
        return event
    }

    private func saveFocus() {
        guard let window else { return }
        savedFocus = KeyboardFocus(in: window)
    }

    private static func isKeyboardHeld(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        return responder !== window
    }

    private func observe(_ name: Notification.Name, of window: NSWindow, _ handle: @escaping @MainActor (ChatKeyboardKeeperView) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        })
    }

    private func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
