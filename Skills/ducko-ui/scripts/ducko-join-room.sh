#!/bin/bash
# Open the Join Room sheet from the contact list, fill in a room JID and nickname, and join.
# Succeeds once the sheet has closed and the room has a row in the contact list, and fails with the sheet's error
# when it shows one. A name without `@` joins a room of that name at the server's room service, so the script prints
# the JID of the row that appeared, or of the one listed row of that name when the room was joined already.
# The room chat opens in a separate window.
# Usage: ducko-join-room.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-join-room.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-}"

# The dialog trims the input, and turns a name without `@` into a lowercased JID with spaces turned into hyphens, at
# its room service. The script types the trimmed input, with a bare name's spaces already turned into hyphens, so text
# substitution cannot change a run of spaces. AppleScript compares text without regard to case, so the prefix needs no
# lowercasing.
ROOM_INPUT=$(ducko_trim "$ROOM_JID")
if [[ "$ROOM_INPUT" == *@* ]]; then
    ROW_PREFIX="room-row-$ROOM_INPUT"
else
    ROOM_INPUT="${ROOM_INPUT// /-}"
    ROW_PREFIX="room-row-$ROOM_INPUT@"
fi

RESULT=$(osascript - "$ROOM_INPUT" "$NICKNAME" "$ROW_PREFIX" << APPLESCRIPT
$(ducko_as_handlers)

-- The room-row ids in the contact list of win that match the room: the id for a JID, or every id starting with the
-- name prefix for a bare name. A room open under two accounts lists two rows with the same id.
on roomRows(win, rowPrefix, roomJid)
    set matches to {}
    tell application "System Events"
        set roomList to my findByAttr(win, "AXIdentifier", "contact-list", 0, 30)
        if roomList is missing value then return matches
        repeat with rowId in (my collectIdentifiers(roomList, rowPrefix, 0, 30))
            set rowText to contents of rowId
            if (roomJid does not contain "@") or (rowText is rowPrefix) then set end of matches to rowText
        end repeat
    end tell
    return matches
end roomRows

on run argv
    set roomJid to item 1 of argv
    set nick to item 2 of argv
    set rowPrefix to item 3 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Join Room (File menu, ⌘⇧N) is enabled only while Contacts is the key window.
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            -- A room JID needs only its own row, so only a bare name looks at the rows listed before the submit.
            set priorRows to {}
            if roomJid does not contain "@" then set priorRows to my roomRows(contactWin, rowPrefix, roomJid)
            keystroke "n" using {command down, shift down}
            $(ducko_as_await_element '"room-jid-field"' contactWin sheets 5 'room-jid-field not found' roomField)
            $(ducko_as_fill_element "roomField" "roomJid")
            if nick is not "" then
                $(ducko_as_fill_field_by_id '"room-nickname-field"' 'contactWin' 'nick' 'room-nickname-field not found')
            end if
            -- Join has .defaultAction keyboard shortcut
            keystroke return
            -- A room new to the server opens its Room Settings sheet on Contacts, so wait for the field of the Join
            -- Room sheet to go rather than for every sheet.
            $(ducko_as_await_sheet_closed contactWin contacts '"room-jid-field"' '"join-room-error"' 10 "the Join Room sheet stayed open")
            set deadline to (current date) + 5
            repeat
                set picked to my pickRoomRow(my roomRows(contactWin, rowPrefix, roomJid), priorRows, (roomJid contains "@"), ((current date) > deadline))
                if picked is "ambiguous" then return "ERROR: several rooms named " & roomJid & " are listed; pass the full room JID"
                if picked is "none" then return "ERROR: no row for " & roomJid & " appeared in the contact list"
                if picked is not "" then return "JOINED:" & (my idSuffix("room-row-", picked))
                delay 0.5
            end repeat
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    JOINED:*) echo "Joined room ${RESULT#JOINED:}" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
