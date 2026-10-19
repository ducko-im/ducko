#!/bin/bash
# Add a bookmark via the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), clicks "Add Bookmark",
# fills in the room JID and optional nickname, then confirms.
# Succeeds once the Add Bookmark sheet has closed and the bookmark has a row in the Bookmarks sheet.
# Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-}"

# Ensure Bookmarks sheet is open
"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$ROOM_JID" "$NICKNAME" << APPLESCRIPT
$(ducko_as_handlers)

on run argv
    set roomJid to item 1 of argv
    set nick to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_find_scene_window "contacts" "contactWin")
            if contactWin is missing value then return "ERROR: Contacts window not found"
            $(ducko_as_click_element_by_id '"add-bookmark-button"' 'contactWin' 'add-bookmark-button not found')
            delay 0.5
            $(ducko_as_fill_field_by_id '"bookmark-jid-field"' 'contactWin' 'roomJid' 'bookmark-jid-field not found')
            if nick is not "" then
                $(ducko_as_fill_field_by_id '"bookmark-nickname-field"' 'contactWin' 'nick' 'bookmark-nickname-field not found')
            end if
            -- Confirm has .defaultAction keyboard shortcut
            keystroke return
            set bookmarkRowId to "bookmark-row-" & roomJid
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                set sheetOpen to (my findInSheets(contactWin, "bookmark-jid-field")) is not missing value
                if not sheetOpen and (my findInSheets(contactWin, bookmarkRowId)) is not missing value then return "ok"
            end repeat
            if sheetOpen then return "ERROR: the Add Bookmark sheet stayed open"
            return "ERROR: no row for " & roomJid & " appeared in the Bookmarks sheet"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Bookmark added for $ROOM_JID"
