import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch result {
    case .success: return value
    case .attributeUnsupported, .noValue: return nil
    default: fail("Accessibility read failed for \(name): \(result.rawValue)")
    }
}

func findAll(in element: AXUIElement, depth: Int = 0, matching predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 64 else { return [] }
    if predicate(element) { return [element] }
    return ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap {
        findAll(in: $0, depth: depth + 1, matching: predicate)
    }
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fail("Expected a process ID and a text to match, which may be empty")
}
guard AXIsProcessTrusted() else { fail("Accessibility permission is required") }
// Set on the system-wide element, the timeout covers every element; set on one element, it covers that one alone.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
let application = AXUIElementCreateApplication(pid)
let text = CommandLine.arguments[2]
let blocks = ((attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap { window in
    findAll(in: window) { attribute($0, kAXIdentifierAttribute) as? String == "code-block" }
}
let block = text.isEmpty
    ? blocks.last
    : blocks.first { (attribute($0, kAXValueAttribute) as? String)?.contains(text) ?? false }
guard let block else { fail(text.isEmpty ? "No code block found" : "No code block containing \(text) found") }
var actionNames: CFArray?
let actionsResult = AXUIElementCopyActionNames(block, &actionNames)
guard actionsResult == .success else { fail("Accessibility read failed for actions: \(actionsResult.rawValue)") }
// A named action is listed as "Name:<title>" followed by lines naming its target and selector.
guard let action = (actionNames as? [String])?.first(where: { $0.hasPrefix("Name:Copy Code") }) else {
    fail("The code block offers no Copy Code action")
}
let pasteboard = NSPasteboard.general
let changeCount = pasteboard.changeCount
guard AXUIElementPerformAction(block, action as CFString) == .success else { fail("Copy Code action failed") }
let deadline = ContinuousClock.now + .seconds(2)
while pasteboard.changeCount == changeCount, ContinuousClock.now < deadline { usleep(20000) }
guard pasteboard.changeCount != changeCount, let copied = pasteboard.string(forType: .string) else {
    fail("The clipboard did not change")
}
print(copied)
