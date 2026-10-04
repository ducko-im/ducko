import AppKit

// Presses every "Dismiss error" button in the windows of a PID, which closes the chat's warning banners.
// Prints how many it pressed; pressing none is not an error.
// Usage: swift dismiss_banner.swift <pid>
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

// The banner sits a few levels below the window; the bound keeps a cyclic tree from looping.
func buttons(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 64 else { return [] }
    var found: [AXUIElement] = []
    if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
       attribute(element, kAXDescriptionAttribute) as? String == "Dismiss error" {
        found.append(element)
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        found += buttons(in: child, depth: depth + 1)
    }
    return found
}

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    fail("usage: dismiss_banner.swift <pid>, with exactly one PID", code: 2)
}
guard AXIsProcessTrusted() else { fail("Accessibility permission is required", code: 1) }
guard let running = NSRunningApplication(processIdentifier: pid),
      let path = running.executableURL?.path, !path.hasPrefix("/Applications/") else {
    fail("refusing: not the demo instance", code: 1)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
var pressed = 0
for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    for button in buttons(in: window) where AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
        pressed += 1
    }
}
print("dismissed", pressed)
