#!/bin/bash
# Invite a user to a room via its context menu.
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
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'room row not found for " & roomJID & "' 'targetRow')

            -- Open the context menu and select "Invite User…". The menu may render
            -- at process level (a sibling of the windows) or under the window.
            perform action "AXShowMenu" of targetRow
            delay 0.5
            set menuItem to missing value
            repeat with m in menus
                set menuItem to my findByRoleAndName(m, "AXMenuItem", "Invite User…", 0, 8)
                if menuItem is not missing value then exit repeat
            end repeat
            if menuItem is missing value then set menuItem to my findByRoleAndName(contactWin, "AXMenuItem", "Invite User…", 0, 30)
            if menuItem is missing value then return "ERROR: Invite User menu item not found"
            click menuItem
            delay 0.5

            -- Fill the JID field in the invite dialog.
            $(ducko_as_find_element_by_id '"invite-user-jid-field"' 'contactWin' 'JID field not found in invite dialog' 'jidField')
            set focused of jidField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke inviteeJID
            delay 0.2
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Invited $INVITEE_JID to $ROOM_JID"
