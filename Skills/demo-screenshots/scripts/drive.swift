import AppKit

// Drives the demo instance through accessibility and posted events. A PID command touches only that process's
// elements, apart from select-text's mouse events, which go to whatever lies under them, and refuses a PID whose
// executable lies under /Applications/.
// Compile once: swiftc -O drive.swift -o "$WORK/bin/drive"
// Usage:
//   drive <pid> focus <contacts|chat>          make that window key; fails unless it reads back as focused
//   drive <pid> focus-table <identifier>       give keyboard focus to the table inside that element
//   drive <pid> dismiss-banners                press every "Dismiss error" button, print how many
//   drive <pid> value|exists <identifier>
//   drive <pid> frame <identifier>             screen frame in points as x y w h, where a scene id names a window
//   drive <pid> window-button <scene> <close|minimize|zoom>   that traffic light's frame; fails while something covers it
//   drive <pid> select-row|selected <identifier>
//   drive <pid> press|show-menu <identifier>   perform AXPress or AXShowMenu on the element, e.g. to open its menu
//   drive <pid> pick <title>                   press the open menu's item with that title, ignoring its checkmark
//   drive <pid> action <identifier> <name>     perform the element's named action, e.g. "Close Tab"
//   drive <pid> type <text>                    type into the focused message field
//   drive <pid> select-text <identifier> <start> <end>   drag across those UTF-16 offsets of an incoming one-to-one
//                                              message's first line, copy, and print what the pasteboard got
//   drive hover <x> <y>                        move the real pointer there with posted mouse events
//   drive pointer | pointer-restore <x> <y> | parking | scale | appearance
//   drive dock <title>                         a Dock item's frame in points and its badge: x y w h badge
//   drive crop <in.png> <out.png> <x> <y> <w> <h>   cut a rectangle in pixels, from the top left
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: drive <pid> <command> [arguments], or drive hover|pointer|pointer-restore|parking|scale|appearance|dock|crop"

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

// The depth bound keeps a cyclic hierarchy from looping.
func first(in element: AXUIElement, depth: Int = 0, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 64 else { return nil }
    if matches(element) { return element }
    for child in children(element) {
        if let found = first(in: child, depth: depth + 1, where: matches) { return found }
    }
    return nil
}

func all(in element: AXUIElement, depth: Int = 0, where matches: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 64 else { return [] }
    var found = matches(element) ? [element] : []
    for child in children(element) {
        found += all(in: child, depth: depth + 1, where: matches)
    }
    return found
}

func role(_ element: AXUIElement) -> String? {
    attribute(element, kAXRoleAttribute) as? String
}

func identifier(_ element: AXUIElement) -> String? {
    attribute(element, kAXIdentifierAttribute) as? String
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin)
    AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

func waitUntil(seconds: Double = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        usleep(50000)
    } while Date() < deadline
    return condition()
}

func postMouseMoved(to point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func number(_ text: String) -> Double {
    guard let value = Double(text) else { fail(usage, code: 2) }
    return value
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { fail(usage, code: 2) }
// Set on the system-wide element, the timeout covers every element; set on one element, it covers that one alone.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

switch arguments[0] {
case "hover":
    guard arguments.count == 3 else { fail(usage, code: 2) }
    let target = CGPoint(x: number(arguments[1]), y: number(arguments[2]))
    for offset in [12.0, 8, 4, 0] {
        postMouseMoved(to: CGPoint(x: target.x - offset, y: target.y))
        usleep(30000)
    }
    print("hovered", Int(target.x), Int(target.y))
    exit(0)
case "pointer":
    let location = CGEvent(source: nil)?.location ?? .zero
    print(location.x, location.y)
    exit(0)
case "pointer-restore":
    guard arguments.count == 3 else { fail(usage, code: 2) }
    CGWarpMouseCursorPosition(CGPoint(x: number(arguments[1]), y: number(arguments[2])))
    print("restored")
    exit(0)
case "parking":
    // Centered in the menu bar, away from the hot corners, the Dock and every window.
    let bounds = CGDisplayBounds(CGMainDisplayID())
    print(bounds.midX, bounds.minY + 4)
    exit(0)
case "scale":
    let main = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
    guard let main else { fail("no main display") }
    print(main.backingScaleFactor)
    exit(0)
case "appearance":
    // A fresh process follows the system's effective appearance, whatever the preference keys say.
    let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    print(dark ? "dark" : "light")
    exit(0)
case "dock":
    guard arguments.count == 2 else { fail(usage, code: 2) }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { fail("no Dock") }
    let element = AXUIElementCreateApplication(dock.processIdentifier)
    let item = first(in: element) { role($0) == "AXDockItem" && attribute($0, kAXTitleAttribute) as? String == arguments[1] }
    guard let item, let rect = frame(item) else { fail("no Dock item: \(arguments[1])") }
    print(rect.minX, rect.minY, rect.width, rect.height, attribute(item, "AXStatusLabel") as? String ?? "-")
    exit(0)
case "crop":
    // sips crops the center instead when both offsets are 0, so a layer at the capture's top left is cut here.
    guard arguments.count == 7 else { fail(usage, code: 2) }
    let rect = CGRect(x: number(arguments[3]), y: number(arguments[4]), width: number(arguments[5]), height: number(arguments[6]))
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let cropped = image.cropping(to: rect), cropped.width == Int(rect.width), cropped.height == Int(rect.height),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot crop \(arguments[1]) to \(rect)")
    }
    CGImageDestinationAddImage(destination, cropped, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(arguments[2])") }
    print("cropped", cropped.width, cropped.height)
    exit(0)
default:
    break
}

guard arguments.count >= 2, let pid = pid_t(arguments.removeFirst()) else { fail(usage, code: 2) }
let command = arguments.removeFirst()
guard AXIsProcessTrusted() else { fail("Accessibility permission is required") }
guard let running = NSRunningApplication(processIdentifier: pid),
      let path = running.executableURL?.path, !path.hasPrefix("/Applications/") else {
    fail("refusing: not the demo instance")
}
let app = AXUIElementCreateApplication(pid)

func windows() -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

// Rooted at the windows: the application element's menu-bar subtree makes a walk take minutes.
func find(_ id: String) -> AXUIElement? {
    for window in windows() {
        if let element = first(in: window, where: { identifier($0) == id }) { return element }
    }
    return nil
}

func require(_ id: String) -> AXUIElement {
    guard let element = find(id) else { fail("not found: \(id)") }
    return element
}

func row(containing element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0 ..< 12 {
        guard let candidate = current else { return nil }
        if role(candidate) == kAXRowRole { return candidate }
        current = elementAttribute(candidate, kAXParentAttribute)
    }
    return nil
}

func activate() {
    running.activate()
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = waitUntil(seconds: 1) { running.isActive }
}

func argument() -> String {
    guard arguments.count == 1 else { fail(usage, code: 2) }
    return arguments[0]
}

switch command {
case "focus":
    let scene = argument()
    guard let window = windows().first(where: { identifier($0) == scene }) else { fail("window not found: \(scene)") }
    activate()
    AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    let focused = waitUntil {
        elementAttribute(app, kAXFocusedWindowAttribute).map { identifier($0) == scene } ?? false
    }
    guard focused else { fail("not focused: \(scene)") }
    print("focused", scene)
case "focus-table":
    let container = require(argument())
    guard let table = first(in: container, where: { role($0) == kAXTableRole }) else { fail("no table in \(arguments[0])") }
    AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let focused = waitUntil {
        elementAttribute(app, kAXFocusedUIElementAttribute).map { CFEqual($0, table) } ?? false
    }
    guard focused else { fail("table not focused: \(arguments[0])") }
    print("focused table")
case "dismiss-banners":
    var pressed = 0
    for window in windows() {
        let buttons = all(in: window) {
            role($0) == kAXButtonRole && attribute($0, kAXDescriptionAttribute) as? String == "Dismiss error"
        }
        for button in buttons where AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            pressed += 1
        }
    }
    print("dismissed", pressed)
case "value":
    print(attribute(require(argument()), kAXValueAttribute) as? String ?? "")
case "exists":
    print(find(argument()) != nil)
case "frame":
    guard let rect = frame(require(argument())) else { fail("no frame: \(arguments[0])") }
    print(rect.minX, rect.minY, rect.width, rect.height)
case "window-button":
    guard arguments.count == 2 else { fail(usage, code: 2) }
    let names = ["close": kAXCloseButtonAttribute, "minimize": kAXMinimizeButtonAttribute, "zoom": kAXZoomButtonAttribute]
    guard let name = names[arguments[1]] else { fail(usage, code: 2) }
    guard let window = windows().first(where: { identifier($0) == arguments[0] }) else { fail("window not found: \(arguments[0])") }
    guard let button = elementAttribute(window, name), let rect = frame(button) else { fail("no \(arguments[1]) button") }
    // Another window over the button would take the hover instead.
    var hit: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(rect.midX), Float(rect.midY), &hit)
    guard error == .success else { fail("hit test failed: \(error.rawValue)") }
    guard let hit, CFEqual(hit, button) else { fail("the \(arguments[1]) button is covered") }
    print(rect.minX, rect.minY, rect.width, rect.height)
case "select-row":
    guard let target = row(containing: require(argument())) else { fail("no row around \(arguments[0])") }
    let error = AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    guard error == .success else { fail("select failed: \(error.rawValue)") }
    print("selected")
case "selected":
    guard let target = row(containing: require(argument())) else { fail("no row around \(arguments[0])") }
    print(attribute(target, kAXSelectedAttribute) as? Bool ?? false)
case "press", "show-menu":
    let element = require(argument())
    activate()
    let action = command == "press" ? kAXPressAction : kAXShowMenuAction
    // Opening a menu can report cannotComplete while the menu tracks, though it opened.
    let error = AXUIElementPerformAction(element, action as CFString)
    guard error == .success || error == .cannotComplete else { fail("\(action) failed: \(error.rawValue)") }
    print(command == "press" ? "pressed" : "shown")
case "pick":
    let title = argument()
    // A status row carries its checkmark as U+FFFC, stripped so the marked row still matches. The comparison is
    // exact, so "Away" does not match "Extended Away".
    func matches(_ element: AXUIElement) -> Bool {
        guard role(element) == kAXMenuItemRole, let itemTitle = attribute(element, kAXTitleAttribute) as? String else { return false }
        return itemTitle.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) == title
    }
    var item: AXUIElement?
    _ = waitUntil {
        let roots = children(app).filter { role($0) != kAXMenuBarRole } + windows()
        let menus = roots.flatMap { root in all(in: root) { role($0) == kAXMenuRole } }
        item = menus.lazy.compactMap { menu in first(in: menu, where: matches) }.first
        return item != nil
    }
    guard let item else { fail("menu item not found: \(title)") }
    if AXUIElementPerformAction(item, kAXPressAction as CFString) != .success {
        let error = AXUIElementPerformAction(item, kAXPickAction as CFString)
        guard error == .success else { fail("pick failed: \(error.rawValue)") }
    }
    print("picked", title)
case "action":
    guard arguments.count == 2 else { fail(usage, code: 2) }
    let element = require(arguments[0])
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    guard let name = (names as? [String])?.first(where: { $0.hasPrefix("Name:\(arguments[1])") }) else {
        fail("no action \(arguments[1]) on \(arguments[0])")
    }
    let error = AXUIElementPerformAction(element, name as CFString)
    guard error == .success else { fail("action failed: \(error.rawValue)") }
    print("performed", arguments[1])
case "type":
    let text = argument()
    activate()
    // The element with the keyboard can be the field's editor, up to three levels below the identified element.
    let fieldFocused = waitUntil {
        var element = elementAttribute(app, kAXFocusedUIElementAttribute)
        for _ in 0 ..< 4 {
            guard let current = element else { return false }
            if identifier(current) == "message-field" { return true }
            element = elementAttribute(current, kAXParentAttribute)
        }
        return false
    }
    guard fieldFocused else { fail("message-field is not focused") }
    for character in text {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { fail("no keyboard event") }
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
            event.postToPid(pid)
        }
        // Paced so the field editor takes each event.
        usleep(10000)
    }
    print("typed", text.count)
case "select-text":
    guard arguments.count == 3, let start = Int(arguments[1]), let end = Int(arguments[2]), start < end else { fail(usage, code: 2) }
    let element = require(arguments[0])
    // The bubble's character bounds all answer with its whole frame, so the drag is placed from the layout:
    // MessageBubbleView's avatar (AvatarView.defaultSize) and HStack spacing, then BubbleChrome's padding, and the
    // body's default 13-point system font.
    let textLeft = 32.0 + 8 + 12
    let textTop = 12 * 0.67
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    guard let rect = frame(element) else { fail("no frame: \(arguments[0])") }
    guard let value = attribute(element, kAXValueAttribute) as? String else { fail("no value: \(arguments[0])") }
    let body = value as NSString
    guard end <= body.length else { fail("range past the text: \(body.length)") }
    func x(_ offset: Int) -> Double {
        rect.minX + textLeft + NSAttributedString(string: body.substring(to: offset), attributes: [.font: font]).size().width
    }
    let y = rect.minY + textTop + (font.ascender - font.descender + font.leading) / 2
    activate()
    let from = CGPoint(x: x(start), y: y), to = CGPoint(x: x(end), y: y)
    postMouseMoved(to: from)
    usleep(50000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
    for step in 1 ... 10 {
        let point = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 10, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20000)
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(200_000)
    // Copying reads the selection back: kVK_ANSI_C with Command.
    NSPasteboard.general.clearContents()
    for isDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: isDown) else { fail("no keyboard event") }
        event.flags = .maskCommand
        event.postToPid(pid)
    }
    var copied: String?
    _ = waitUntil {
        copied = NSPasteboard.general.string(forType: .string)
        return copied != nil
    }
    print(copied ?? "")
default:
    fail(usage, code: 2)
}
