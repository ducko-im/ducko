---
name: macos-ui-testing
description: "Background-safe macOS app UI testing using Peekaboo CLI and osascript. This skill should be used when the user asks to \"test the app UI\", \"check the UI\", \"interact with the running app\", \"take a screenshot of the app\", \"fill in the form\", \"click the button\", \"verify the UI state\", \"automate the app\", or wants to automate interaction with a running macOS application without stealing keyboard/mouse focus from the user."
---

# macOS UI Testing (Background-Safe)

Run the `/peekaboo` skill first to load full Peekaboo CLI reference. This skill adds background-safe patterns on top.

## Background Safety Rules

Simulated keystrokes (`peekaboo type`, `peekaboo paste`, `peekaboo hotkey`) go to the **frontmost app**, not the target app. Always use background-safe alternatives.

| Action | Background-Safe | Command |
|---|---|---|
| Read UI tree | Yes | `peekaboo see --app APP --json` |
| Screenshot | Yes | `peekaboo see --window-id WID --no-elements` |
| Click element | Yes | `peekaboo click --no-auto-focus --on ELEM --app APP` |
| Set text value | Yes* | `osascript` with `set value of` |
| Read text value | Yes | `osascript` with `get value of` |
| Click button | Yes | `osascript` with `click button` |
| Type keystrokes | **NO** | Lands in frontmost app |
| Paste (Cmd+V) | **NO** | Lands in frontmost app |
| Hotkeys | **NO** | Lands in frontmost app |

*`set value` updates the accessibility layer but **does not trigger SwiftUI `@State` bindings**. Use `keystroke` inside a single osascript block when SwiftUI binding updates are needed (see Multi-Step Interaction Sequences below).

## Check for a Locked Screen

While the session screen is locked, window accessibility elements report the role `AXApplication`, controls inside windows can't be resolved, and window captures fail (`screencapture -l` reports "could not create image from window"). Read the lock state before starting the workflow:

```bash
ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked
```

`<true/>` on the line after the key means locked. No output means unlocked, because the key is absent then. An `ioreg` error, such as "can't open file" inside a sandbox, leaves the lock state unknown. When the screen is locked, record the GUI check as inconclusive instead of working around it.

## A Glitch in an App's First Frames

In the observed launch, the first accessibility answer came about half a second after the process started, so a layout glitch in an app's first frames is over before the first read. A screen recording is no substitute (see Step 4). Log the geometry from inside the app instead: put a logging probe into a scratch copy of the code and launch that. To check a fix, put the same probe into scratch copies of the unfixed and the fixed code and compare the logs.

## Workflow

### Step 1: Launch the App

```bash
# For SwiftPM-built apps:
swift run AppName &>/dev/null &
APP_PID=$!
sleep 3

# For installed apps:
open -a "AppName"
```

### Step 2: Verify the App Is Running

```bash
peekaboo app list | grep -i AppName
```

### Step 3: Read the UI Tree

```bash
peekaboo see --app AppName --json
```

Parse the JSON output to find element IDs (`elem_N`), roles, and labels.

### Step 4: Take a Screenshot

Resolve the window ID first, then capture by ID:

```bash
peekaboo window list --app AppName
peekaboo see --window-id WID --no-elements --path /tmp/screenshot.png
```

Capture by window ID only. A screen recording, or a capture of the whole screen or a region of it, holds everything else the user has open, and shows whatever is in front, which may not be the app. `screencapture -l WID` has captured a window correctly while it was on another Space.

### Step 5: Interact with Elements

**Click an element** (accessibility API, no focus needed):

```bash
peekaboo click --no-auto-focus --on elem_4 --app AppName
```

**Set a text field value** (background-safe, but does NOT trigger SwiftUI bindings):

```bash
osascript -e 'tell application "System Events" to set value of text field 1 of group 1 of window 1 of process "AppName" to "text"'
```

**Read a text field value**:

```bash
osascript -e 'tell application "System Events" to get value of text field 1 of group 1 of window 1 of process "AppName"'
```

**Click a button by name**:

```bash
osascript -e 'tell application "System Events" to click button "Submit" of group 1 of window 1 of process "AppName"'
```

> **Synthetic coordinate clicks don't drive SwiftUI gestures.** AppleScript `click at {x,y}` and `peekaboo click --coords` do **not** trigger `.onTapGesture`/`.simultaneousGesture` or `List(selection:)` selection — only real user clicks or an accessibility **`AXPress`** on an actual `Button` do (`peekaboo perform-action --on ELEM --action AXPress`, or `peekaboo click --on ELEM` from `see --json`). So a `Button` is verifiable, but UI relying on tap gestures or list selection **can't be confirmed by synthetic clicks** — treat such a result as a signal, not proof, and hand the app to the user when only real clicks suffice.
>
> Peekaboo targets apps by **display name** (`--app Ducko`), not the executable name (`DuckoApp`).

### Step 6: Verify Results

Take another screenshot or read values back to confirm the interaction succeeded.

### Step 7: Stop the App

```bash
kill $APP_PID
```

## Multi-Step Interaction Sequences

Each tool call returns focus to the terminal. Multi-step flows **must** be in a single `osascript` heredoc -- splitting across tool calls loses focus between steps.

```bash
osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "AppName" to true
    delay 0.5
    tell process "AppName"
        click text field 1 of group 1 of window 1
        delay 0.3
        keystroke "username"
        delay 0.2
        keystroke tab
        delay 0.2
        keystroke "password"
        delay 0.3
        click button 1 of group 1 of window 1
    end tell
end tell
APPLESCRIPT
```

This pattern uses `keystroke` (triggers SwiftUI bindings) and keeps focus on the target app throughout the sequence.

**Important**: Use `osascript << 'APPLESCRIPT'` heredoc syntax (not `osascript -e`) to avoid shell escaping issues.

## osascript Element Discovery

When the UI hierarchy is unknown, explore it incrementally with osascript. See [references/osascript-patterns.md](references/osascript-patterns.md) for element addressing patterns and exploration techniques.

## Peekaboo Focus Timeout Issue

Peekaboo's `click` and `type` with `--app` try to activate the app first. For SwiftPM-built apps this often times out because `NSRunningApplication.activate()` is not acknowledged.

**Workarounds:**
- Use `--no-auto-focus` on `click` commands
- `see` works fine with `--app` or `--window-id` (read-only, skips focus)

**Caveat with `--no-auto-focus`**: Clicks use absolute screen coordinates. If another window overlaps the target, the click hits the wrong window. Prefer `osascript` click (accessibility API, position-independent) for reliable button clicks.

## Driving SwiftUI Controls (gotchas)

SwiftUI controls bridge to accessibility in ways that defeat naive synthetic automation:

- **Auto-focusing fields need confirmed focus and targeted input.** Activate the intended app and, for an identifiable field, confirm that its application’s `kAXFocusedUIElementAttribute` resolves to that field before typing. Ducko’s integration harness posts Unicode CGEvents to the owned PID with `postToPid`. System Events keystrokes and global event taps depend on the frontmost app, so avoid them when multiple instances are open. If a field does not expose its typed text through `kAXValue`, assert the resulting behavior, such as filtered rows.
- **A SwiftUI `Menu` (`.menuStyle(.button)`) exposes its opened menu in one of two places**: as a `kAXMenuRole` descendant of the button, or as a top-level `AXMenu` among the application's children, a sibling of the windows like a context menu. Both have been observed, and `kAXShownMenuUIElementAttribute` on the button returned neither. Search the button's descendants first, then the app's top children excluding the menu bar. To open it, use an `AXPress` (`kAXPressAction`), not a coordinate click (see the Step 5 note). The Menu's label text isn't in `kAXValue` — add `.accessibilityValue(...)` in the app so the current selection is readable (also a VoiceOver win).
- **A menu opened only to read its items stays open on screen.** Pressing an item closes a menu; `AXCancel` (`kAXCancelAction`) on it leaves it up. While it is up, another `AXShowMenu` opens nothing, so a lookup of the open menu returns the earlier one and every reading after the first is stale. Close a menu that was only read by activating the app and posting Escape to that process alone (`CGEvent.postToPid`, virtual key 53). Confirm it closed from the process's on-screen windows: in `CGWindowListCopyWindowInfo` filtered by owner PID, an open menu is a window at the pop-up-menu level (layer 101).
- **osascript `entire contents` silently truncates on deep SwiftUI AX trees** — it misses deeply-nested identifiers that `peekaboo see --json` and a Swift `AXUIElement` walk find reliably; `... of window 1` (e.g. `UI element of window 1`) only checks **direct** children, not descendants. Don't rely on osascript element-finding for deeply-nested SwiftUI elements — use peekaboo or a Swift AX walk. Menu-bar navigation (`click menu item "X" of menu 1 of menu bar item "Y" of menu bar 1`) stays reliable and is the robust way to drive menu commands from osascript.
- **A context menu opened in an AppKit `NSTableView` that hosts SwiftUI rows can hang off the table.** On macOS 27, `AXShowMenu` on a row's static text opened a menu that appeared as an `AXMenu` under the `AXTable`, not among the application's top children and not under the text. When the search of the application's top children finds nothing, search the windows for a `kAXMenuRole` element.
- **A `Button` at `.opacity(0)` was not found in the accessibility tree by identifier**, and a control inserted only while hovering (`if isHovering { … }`) exists only while the pointer is over it. To reach such a control's effect without a pointer, give an always-present element a named action (`.accessibilityAction(named:)`). It shows up in that element's action names (`AXUIElementCopyActionNames`) as a multi-line string that starts with `Name:<title>` (observed: `Name:Copy Code\nTarget:0x0\nSelector:(null)`); pass that exact string to `AXUIElementPerformAction`.
- **Key presses with modifiers can be posted to one process.** Set `flags` on the `CGEvent` (`.maskShift`, `.maskAlternate`) before `postToPid`; SwiftUI `.onKeyPress` handlers receive the modifiers. Virtual key 36 is Return, and 76 is the keypad's Enter (posted with `.maskNumericPad`). In the observed run the app had been activated with `NSRunningApplication.activate()`, yet `NSApp.keyWindow` was nil while keys were posted this way, and `NSApp.sendAction(_:to:from:)` with a nil target returned false. Confirm a key window before relying on a responder-chain action.
- **`AXScrollToVisible` scrolled an element of a `LazyVStack` into view** when performed on an element already in the tree. Confirm with a window screenshot.
- **A tooltip appears only under a resting pointer, in a window of its own.** To verify one, record the pointer position, activate the app by PID, post `mouseMoved` events to the HID event tap at a few points ending on the target, and wait about 2.5 seconds. The tooltip is then a new on-screen window owned by that PID in `CGWindowListCopyWindowInfo` (observed at layer 103 on macOS 27). Capture that window by its ID (see Step 4). Then put the pointer back at the recorded position with `CGWarpMouseCursorPosition`. This moves the user's real pointer, so tell them first, and retry once when no tooltip appears. SwiftUI `.help` text also reads back as `kAXHelpAttribute` unless the view clears its accessibility hint, so a missing attribute does not mean a missing tooltip.
- **A test that triggers a copy overwrites the user's clipboard.** Save every pasteboard item's types and data first (`NSPasteboard.general.pasteboardItems`) and read the result. Then call `clearContents()` and `writeObjects` with new `NSPasteboardItem`s built from the saved data.

## Additional Resources

- Full Peekaboo CLI reference: `peekaboo --help` or `peekaboo <subcommand> --help`
- osascript UI scripting patterns: [references/osascript-patterns.md](references/osascript-patterns.md)
