#!/bin/bash
# Invite a user to a room via its context menu.
# Succeeds once the Invite User sheet has closed, and fails with the sheet's error when it shows one.
# Usage: ducko-invite-user.sh ROOM_JID INVITEE_JID
#   ROOM_JID:    The JID of the room (must be visible in the Rooms section)
#   INVITEE_JID: The JID of the user to invite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-invite-user.sh ROOM_JID INVITEE_JID" >&2
    exit 1
fi

ROOM_JID="$1"
INVITEE_JID="$2"

RESULT=$(osascript - "$ROOM_JID" "$INVITEE_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set roomJID to item 1 of argv
    set inviteeJID to item 2 of argv
    set targetId to "room-row-" & roomJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'room row not found for " & roomJID & "' 'targetRow')
            $(ducko_as_click_context_menu_item "Invite User…" targetRow contactWin "Invite User… menu item not found" continue)
            $(ducko_as_await_element '"invite-user-jid-field"' contactWin sheets 5 'JID field not found in invite dialog' inviteField)
            $(ducko_as_fill_element "inviteField" "inviteeJID")
            -- Invite has .defaultAction keyboard shortcut
            keystroke return
            $(ducko_as_await_sheet_closed contactWin contacts '"invite-user-jid-field"' '"invite-user-error"' 10 "Invite sheet stayed open")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Invited $INVITEE_JID to $ROOM_JID"
