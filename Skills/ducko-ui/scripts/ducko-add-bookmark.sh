#!/bin/bash
# Add a bookmark via the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), clicks "Add Bookmark",
# fills in the room JID and optional nickname, then confirms.
# Succeeds once the Add Bookmark sheet has closed and the bookmark has a row in the Bookmarks sheet, and fails with
# the sheet's error when it shows one.
# Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-}"

"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null

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
            $(ducko_as_require_front_window "contactWin" "the contacts window")
            $(ducko_as_click_element_by_id '"add-bookmark-button"' 'contactWin' 'add-bookmark-button not found')
            $(ducko_as_await_element '"bookmark-jid-field"' contactWin sheets 5 'bookmark-jid-field not found' jidField)
            $(ducko_as_fill_element "jidField" "roomJid")
            if nick is not "" then
                $(ducko_as_fill_field_by_id '"bookmark-nickname-field"' 'contactWin' 'nick' 'bookmark-nickname-field not found')
            end if
            -- Confirm has .defaultAction keyboard shortcut
            keystroke return
            set bookmarkRowId to "bookmark-row-" & roomJid
            $(ducko_as_await_sheet_closed contactWin contacts '"bookmark-jid-field"' '"add-bookmark-error"' 10 "the Add Bookmark sheet stayed open")
            $(ducko_as_await_element 'bookmarkRowId' contactWin sheets 5 'no row for " & roomJid & " appeared in the Bookmarks sheet' bookmarkRow)
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Bookmark added for $ROOM_JID"
