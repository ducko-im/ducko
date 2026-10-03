import AppKit

/// Shows a window without interrupting: it comes up behind the window the user is in, or was in before switching to
/// another app, and that window keeps the keyboard and what had it.
@MainActor
enum QuietWindow {
    /// How long after asking for the window it is still put back. A window that is being created comes to the front
    /// a moment after the call that opened it, and can do so more than once.
    private static let settlingTime: Duration = .seconds(1)
    private static let checkInterval: Duration = .milliseconds(20)

    /// Counts the watches, so an earlier one ends when a later one starts or the user takes the window.
    private static var watch = 0
    private static var endCurrentWatch: (() -> Void)?

    /// `open` asks for the window with `identifier`. A window that is already on screen or in the Dock is left as it
    /// is. `settling` is told when the window starts and stops being put back: in between it can have the keyboard
    /// for a moment without the user having gone to it.
    static func show(identifier: String, open: () -> Void, settling: @escaping (Bool) -> Void) {
        let find = { NSApp.windows.first { $0.identifier?.rawValue == identifier } }
        if let window = find(), window.isVisible || window.isMiniaturized { return }
        // In a background app no window has the keyboard. The frontmost one is the window the user comes back to.
        let current = NSApp.keyWindow ?? windowsFrontToBack.first { $0.isVisible && $0.canBecomeKey && $0.styleMask.contains(.titled) }
        guard let current else {
            // With no window of the app to keep it behind, the window is simply opened. In an active app it is then
            // the focused window, and its chat counts as looked at.
            open()
            return
        }

        let focus = KeyboardFocus(in: current)
        let wasActive = NSApp.isActive
        stopWatching()
        let currentWatch = watch
        // A click in the window is the user going to it.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.window?.identifier?.rawValue == identifier { stopWatching() }
            return event
        }
        endCurrentWatch = {
            if let clicks { NSEvent.removeMonitor(clicks) }
            settling(false)
        }
        settling(true)
        open()
        Task {
            let deadline = ContinuousClock.now + settlingTime
            while ContinuousClock.now < deadline, currentWatch == watch {
                // The user came back to the app meanwhile, and whichever window they came back to is theirs.
                if !wasActive, NSApp.isActive { break }
                if let window = find(), window !== current, isAhead(window, of: current) {
                    window.order(.below, relativeTo: current.windowNumber)
                    current.makeKey()
                    focus.restore(in: current)
                }
                try? await Task.sleep(for: checkInterval)
            }
            if currentWatch == watch { stopWatching() }
        }
    }

    /// Leaves the window where it is from now on. For when the user asks for the window themselves.
    static func stopWatching() {
        watch += 1
        endCurrentWatch?()
        endCurrentWatch = nil
    }

    /// Whether `window` has the keyboard or stands in front of `other`.
    private static func isAhead(_ window: NSWindow, of other: NSWindow) -> Bool {
        if window.isKeyWindow { return true }
        let ordered = windowsFrontToBack
        guard let windowIndex = ordered.firstIndex(of: window), let otherIndex = ordered.firstIndex(of: other) else {
            return false
        }
        return windowIndex < otherIndex
    }

    /// The app's windows front to back, panels included, which `NSApp.orderedWindows` leaves out.
    private static var windowsFrontToBack: [NSWindow] {
        var windows: [NSWindow] = []
        NSApp.enumerateWindows(options: .orderedFrontToBack) { window, _ in windows.append(window) }
        return windows
    }
}
