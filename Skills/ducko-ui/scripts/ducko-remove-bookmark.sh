#!/bin/bash
# Remove a bookmark from the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), finds the bookmark row
# by its AXIdentifier, then clicks that row's remove button.
# Succeeds once the row is gone, since the app removes the bookmark only after the server confirms.
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested bookmark list on macOS 26.
# Usage: ducko-remove-bookmark.sh ROOM_JID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-remove-bookmark.sh ROOM_JID}"

"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null

RESULT=$(osascript - "$ROOM_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set roomJID to item 1 of argv
    set targetRowId to "bookmark-row-" & roomJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_find_scene_window "contacts" "contactWin")
            if contactWin is missing value then return "ERROR: Contacts window not found"
            set bookmarkRow to my findInSheets(contactWin, targetRowId)
            if bookmarkRow is missing value then return "ERROR: bookmark not found for " & roomJID
            set removeBtn to my findByAttr(bookmarkRow, "AXIdentifier", "remove-bookmark-button", 0, 30)
            if removeBtn is missing value then return "ERROR: remove button not found"
            click removeBtn
            -- A missing row counts only while the Bookmarks sheet is still open, since a closed sheet lists nothing.
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                if (my findInSheets(contactWin, "add-bookmark-button")) is missing value then return "ERROR: the Bookmarks sheet closed before the row went"
                if (my findInSheets(contactWin, targetRowId)) is missing value then return "ok"
            end repeat
            return "ERROR: the bookmark row is still listed"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Bookmark removed for $ROOM_JID"
