#!/bin/bash
# Right-click a message in the active chat window and select Reveal in Finder.
# Only messages carrying a file this app saved offer the item; a link a contact sent does not.
# Usage: ducko-reveal.sh [TEXT]
#   No args:   reveals the last message's saved files
#   TEXT:      reveals the first message showing TEXT (e.g. the file name)
#
# A bubble carrying an attachment exposes its file card as a child element, so the file name is that child's label,
# not the bubble's. Peekaboo lists elements flat, so a matching element is mapped to the smallest bubble enclosing it,
# and that bubble is then right-clicked by its identifier.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TEXT="${1:-}"

# Peekaboo does not list elements in on-screen order (buttons come before other roles), so bubbles are ordered by their
# vertical position: a search takes the topmost match, and no search text takes the bottom-most bubble, which is the
# newest message.
BUBBLE_PICKER='
import json, sys
text = sys.argv[1]
bubbles = []
hits = []
def walk(node):
    if isinstance(node, dict):
        ident = str(node.get("identifier") or "")
        label = str(node.get("description") or node.get("label") or "")
        bounds = node.get("bounds")
        if isinstance(bounds, dict):
            x, y = bounds.get("x", 0), bounds.get("y", 0)
            width, height = bounds.get("width", 0), bounds.get("height", 0)
            if ident.startswith("message-bubble"):
                bubbles.append((y, height, x, width, ident))
            if text and text in label:
                hits.append((x + width / 2, y + height / 2))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(sys.stdin))
if not text:
    if bubbles:
        print(max(bubbles)[4])
    sys.exit()
matches = []
for center_x, center_y in hits:
    enclosing = [
        bubble for bubble in bubbles
        if bubble[0] <= center_y <= bubble[0] + bubble[1] and bubble[2] <= center_x <= bubble[2] + bubble[3]
    ]
    if enclosing:
        smallest = min(enclosing, key=lambda bubble: bubble[1])
        matches.append((smallest[0], smallest[4]))
if matches:
    print(min(matches)[1])
'

WID=$("$SCRIPT_DIR/ducko-window-id.sh")
SHOT_DIR="$(mktemp -d)"
if ! ELEMENTS=$(peekaboo see --window-id "$WID" --capture-engine classic --path "$SHOT_DIR/ducko-reveal.png" --json 2>/dev/null); then
    rm -rf "$SHOT_DIR"
    echo "ERROR: Peekaboo could not read the chat window" >&2
    exit 1
fi
rm -rf "$SHOT_DIR"
BUBBLE_ID=$(printf '%s' "$ELEMENTS" | python3 -c "$BUBBLE_PICKER" "$TEXT" 2>/dev/null || true)

if [[ -z "$BUBBLE_ID" ]]; then
    echo "ERROR: no matching message found" >&2
    exit 1
fi

RESULT=$(osascript - "$BUBBLE_ID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set bubbleID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "no chat window found" "chatWin")

            set targetElem to my findByAttr(chatWin, "AXIdentifier", bubbleID, 0, 30)
            if targetElem is missing value then return "ERROR: no matching message found"

            $(ducko_as_click_context_menu_item "Reveal in Finder" 'targetElem' 'chatWin')
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Revealed in Finder"
