import AppKit
import ApplicationServices

// Fills the app's open Open panel with a path and confirms it, then checks that the panel closed, and cancels it
// when it did not.
// The panel's contents are served by another process, which takes key events only while the app is frontmost.
// Usage: swift ducko-file-panel.swift <pid> <path>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

struct ReadFailed: Error {}

enum PanelState {
    case open(AXUIElement)
    case closed
    case unknown
}

// Throws on a failed read, as happens while the sheet is torn down, so it is never mistaken for an absent attribute.
func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
    case .success: return value
    case .attributeUnsupported, .noValue, .notImplemented: return nil
    default: throw ReadFailed()
    }
}

func findPanel(in element: AXUIElement, depth: Int = 0) throws -> AXUIElement? {
    guard depth < 64 else { return nil }
    if try attribute(element, kAXIdentifierAttribute) as? String == "open-panel" { return element }
    for child in try (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let panel = try findPanel(in: child, depth: depth + 1) { return panel }
    }
    return nil
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fail("Expected a process ID and a file path")
}
let path = CommandLine.arguments[2]
guard AXIsProcessTrusted() else { fail("Accessibility permission is required") }
// Set on the system-wide element, the timeout covers every element; set on one element, it covers that one alone.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

// The panel counts as closed only when a whole read of the app's windows found none.
func panelState() -> PanelState {
    let application = AXUIElementCreateApplication(pid)
    do {
        for window in try (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let panel = try findPanel(in: window) { return .open(panel) }
        }
        return .closed
    } catch {
        return .unknown
    }
}

func servicePID(in panel: AXUIElement) -> pid_t? {
    var queue = [panel]
    while !queue.isEmpty {
        let element = queue.removeFirst()
        var owner: pid_t = 0
        if AXUIElementGetPid(element, &owner) == .success, owner != pid { return owner }
        queue += ((try? attribute(element, kAXChildrenAttribute)) as? [AXUIElement]) ?? []
    }
    return nil
}

func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        usleep(50000)
    } while Date() < deadline
    return condition()
}

func waitForClosed(seconds: Double) -> Bool {
    waitUntil(seconds: seconds) {
        if case .closed = panelState() { return true }
        return false
    }
}

// NSRunningApplication and NSWorkspace update activation state only as the run loop turns, which this script never
// does, so the AX attribute is what reads back fresh.
func activate() {
    let application = AXUIElementCreateApplication(pid)
    NSRunningApplication(processIdentifier: pid)?.activate()
    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    let frontmost = waitUntil(seconds: 2) {
        (try? attribute(application, kAXFrontmostAttribute)) as? Bool == true
    }
    guard frontmost else { fail("DuckoUITest did not come to the front") }
}

func post(_ key: CGKeyCode, flags: CGEventFlags = [], text: String? = nil, to target: pid_t) {
    for isDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: isDown) else { fail("No keyboard event") }
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
        }
        event.postToPid(target)
    }
}

var panelService: pid_t?
_ = waitUntil(seconds: 5) {
    guard case let .open(panel) = panelState() else { return false }
    panelService = servicePID(in: panel)
    return panelService != nil
}
guard let service = panelService else { fail("Open panel not found in process \(pid)") }

activate()
usleep(500_000)
post(5, flags: [.maskCommand, .maskShift], to: service)
usleep(1_000_000)
for character in path {
    post(0, text: String(character), to: service)
    usleep(10000)
}
usleep(500_000)
post(36, to: service)
usleep(1_000_000)
post(36, to: service)

if waitForClosed(seconds: 5) { exit(0) }
// The first Escape may only close the Go to Folder sheet.
activate()
post(53, to: service)
if !waitForClosed(seconds: 3) {
    post(53, to: service)
    if !waitForClosed(seconds: 3) { fail("Open panel stayed open and could not be cancelled") }
}
fail("Open panel stayed open")
