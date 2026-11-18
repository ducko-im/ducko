#!/bin/bash
# Press the stop button on a direct file transfer in the active chat window.
# Only a transfer still waiting for acceptance, sending or receiving shows the button; History shows none.
# Usage: ducko-stop-transfer.sh [TEXT]
#   No args:   stops the bottom-most transfer still under way
#   TEXT:      stops the first transfer whose row shows TEXT (e.g. the file name)
#
# Every stop button carries the same identifier, so Peekaboo picks the button by its vertical position: the bottom-most
# one, or the one inside the smallest bubble or receiving row enclosing TEXT. Its rank among all stop buttons from the
# top is then pressed through System Events, which orders the buttons the same way by their own positions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TEXT="${1:-}"

# Prints "<rank> <count>": the chosen button's 1-based rank from the top and how many stop buttons the window shows.
BUTTON_PICKER='
import json, sys
text = sys.argv[1]
buttons = []
rows = []
hits = []
def walk(node):
    if isinstance(node, dict):
        ident = str(node.get("identifier") or "")
        label = str(node.get("description") or node.get("label") or "")
        bounds = node.get("bounds")
        if isinstance(bounds, dict):
            x, y = bounds.get("x", 0), bounds.get("y", 0)
            width, height = bounds.get("width", 0), bounds.get("height", 0)
            if ident == "stop-direct-transfer-button":
                buttons.append((y + height / 2, x + width / 2))
            elif ident.startswith("message-bubble") or ident == "receiving-file-row":
                rows.append((y, height, x, width))
            if text and text in label:
                hits.append((x + width / 2, y + height / 2))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(sys.stdin))
buttons.sort()
if not buttons:
    sys.exit()
if not text:
    print(len(buttons), len(buttons))
    sys.exit()
def inside(point_x, point_y, row):
    return row[0] <= point_y <= row[0] + row[1] and row[2] <= point_x <= row[2] + row[3]
matches = []
for center_x, center_y in hits:
    enclosing = [row for row in rows if inside(center_x, center_y, row)]
    if not enclosing:
        continue
    smallest = min(enclosing, key=lambda row: row[1])
    for rank, (button_y, button_x) in enumerate(buttons, start=1):
        if inside(button_x, button_y, smallest):
            matches.append(rank)
if matches:
    print(min(matches), len(buttons))
'

WID=$("$SCRIPT_DIR/ducko-window-id.sh")
SHOT_DIR="$(mktemp -d)"
if ! ELEMENTS=$(peekaboo see --window-id "$WID" --capture-engine classic --path "$SHOT_DIR/ducko-stop-transfer.png" --json 2>/dev/null); then
    rm -rf "$SHOT_DIR"
    echo "ERROR: Peekaboo could not read the chat window" >&2
    exit 1
fi
rm -rf "$SHOT_DIR"
PICK=$(printf '%s' "$ELEMENTS" | python3 -c "$BUTTON_PICKER" "$TEXT" 2>/dev/null || true)

if [[ -z "$PICK" ]]; then
    echo "ERROR: no matching transfer under way" >&2
    exit 1
fi
read -r RANK COUNT <<< "$PICK"

RESULT=$(osascript - "$RANK" "$COUNT" << APPLESCRIPT
$(ducko_as_handlers)
on collectByAttr(el, attrName, attrValue, depth, maxDepth)
    set acc to {}
    tell application "System Events"
        if depth > maxDepth then return acc
        try
            repeat with c in (UI elements of el)
                try
                    if (value of attribute attrName of c) is attrValue then set end of acc to contents of c
                end try
                set acc to acc & (my collectByAttr(c, attrName, attrValue, depth + 1, maxDepth))
            end repeat
        end try
    end tell
    return acc
end collectByAttr

on run argv
    set rankWanted to (item 1 of argv) as integer
    set countSeen to (item 2 of argv) as integer
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "no chat window found" "chatWin")

            set stopButtons to my collectByAttr(chatWin, "AXIdentifier", "stop-direct-transfer-button", 0, 30)
            if (count of stopButtons) is not countSeen then return "ERROR: the transfers changed while the window was read"

            repeat with candidate in stopButtons
                set candidateY to item 2 of (position of candidate as list)
                set rankFound to 1
                repeat with other in stopButtons
                    if (item 2 of (position of other as list)) < candidateY then set rankFound to rankFound + 1
                end repeat
                if rankFound is rankWanted then
                    click candidate
                    return "ok"
                end if
            end repeat
            return "ERROR: no matching transfer under way"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Stopped transfer"
