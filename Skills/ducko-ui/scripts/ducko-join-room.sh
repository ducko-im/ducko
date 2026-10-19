#!/bin/bash
# Open the Join Room sheet from the contact list, fill in a room JID and nickname, and join.
# Succeeds once the sheet has closed and the room has a row in the contact list.
# The room chat opens in a separate window.
# Usage: ducko-join-room.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-join-room.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-}"

RESULT=$(osascript - "$ROOM_JID" "$NICKNAME" << APPLESCRIPT
$(ducko_as_handlers)

on run argv
    set roomJid to item 1 of argv
    set nick to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Join Room (File menu, ⌘⇧N) is enabled only while Contacts is the key window.
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            keystroke "n" using {command down, shift down}
            delay 1
            $(ducko_as_fill_field_by_id '"room-jid-field"' 'contactWin' 'roomJid' 'room-jid-field not found')
            if nick is not "" then
                $(ducko_as_fill_field_by_id '"room-nickname-field"' 'contactWin' 'nick' 'room-nickname-field not found')
            end if
            -- Join has .defaultAction keyboard shortcut
            keystroke return
            -- The room chat opens in front, which re-points window references, so find Contacts again each time.
            set roomRowId to "room-row-" & roomJid
            set contactsFound to false
            set sheetOpen to false
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                $(ducko_as_find_scene_window "contacts" "contactWin")
                if contactWin is not missing value then
                    set contactsFound to true
                    -- A room new to the server opens its Room Settings sheet on Contacts, so look for a field of the
                    -- Join Room sheet rather than for any sheet.
                    set sheetOpen to (my findInSheets(contactWin, "room-jid-field")) is not missing value
                    if not sheetOpen and (my findByAttr(contactWin, "AXIdentifier", roomRowId, 0, 30)) is not missing value then return "ok"
                end if
            end repeat
            if not contactsFound then return "ERROR: Contacts window not found after joining"
            if sheetOpen then return "ERROR: the Join Room sheet stayed open"
            return "ERROR: no row for " & roomJid & " appeared in the contact list"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Joined room $ROOM_JID"
