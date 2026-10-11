#!/bin/bash
# Open Room Settings sheet for a room via its context menu.
# Usage: ducko-room-settings.sh <ROOM_JID>
#   ROOM_JID: The JID of the room (must be visible in the Rooms section)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-room-settings.sh <ROOM_JID>" >&2
    exit 1
fi

ROOM_JID="$1"

RESULT=$(osascript - "$ROOM_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set roomJID to item 1 of argv
    set targetId to "room-row-" & roomJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'room row not found for " & roomJID & "' 'targetRow')
            $(ducko_as_click_context_menu_item "Room Settings…" 'targetRow' 'contactWin' "Room Settings menu item not found (are you an owner/admin?)")
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Room Settings sheet opened for $ROOM_JID"
