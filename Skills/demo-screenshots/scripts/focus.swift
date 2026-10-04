import AppKit

// Brings one window of a PID to the front as the key window, using only that PID's accessibility element.
// Refuses an executable under /Applications/, so it never acts on an installed app.
// Usage: swift focus.swift <pid> <window title>
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]) else {
    fail("usage: focus.swift <pid> <window title>, with exactly one PID", code: 2)
}
let title = CommandLine.arguments[2]
guard AXIsProcessTrusted() else { fail("Accessibility permission is required", code: 1) }
guard let running = NSRunningApplication(processIdentifier: pid),
      let path = running.executableURL?.path, !path.hasPrefix("/Applications/") else {
    fail("refusing: not the demo instance", code: 1)
}
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
let windows = value as? [AXUIElement] ?? []
for window in windows {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
    guard (t as? String) == title else { continue }
    running.activate()
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("raised", title)
    exit(0)
}
fail("window not found: \(title) of \(windows.count)", code: 2)
