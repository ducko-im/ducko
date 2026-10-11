#!/bin/bash
# Remove a bookmark from the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), finds the bookmark row
# by its AXIdentifier, then clicks that row's remove button.
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested bookmark list on macOS 26.
# Usage: ducko-remove-bookmark.sh ROOM_JID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-remove-bookmark.sh ROOM_JID}"

# Ensure Bookmarks sheet is open
"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$ROOM_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set roomJID to item 1 of argv
    set targetRowId to "bookmark-row-" & roomJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        -- Find the bookmark row, then the remove button nested within it.
        set bookmarkRow to missing value
        repeat with win in (windows of process "DuckoUITest")
            set bookmarkRow to my findByAttr(win, "AXIdentifier", targetRowId, 0, 30)
            if bookmarkRow is not missing value then exit repeat
        end repeat
        if bookmarkRow is missing value then return "ERROR: bookmark not found for " & roomJID
        set removeBtn to my findByAttr(bookmarkRow, "AXIdentifier", "remove-bookmark-button", 0, 30)
        if removeBtn is missing value then return "ERROR: remove button not found"
        click removeBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Bookmark removed for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
