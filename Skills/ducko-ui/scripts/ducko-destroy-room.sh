#!/bin/bash
# Destroy a room via Room Settings sheet.
# Opens Room Settings first, then clicks the Destroy Room button.
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested settings sheet on macOS 26.
# Usage: ducko-destroy-room.sh ROOM_JID
#   ROOM_JID: The JID of the room to destroy (must be visible in the Rooms section)
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-destroy-room.sh ROOM_JID" >&2
    exit 1
fi

ROOM_JID="$1"

# Open Room Settings sheet
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        -- Find and click the destroy button.
        set destroyBtn to missing value
        set destroyWin to missing value
        repeat with win in (windows of process "DuckoUITest")
            set destroyBtn to my findByAttr(win, "AXIdentifier", "room-settings-destroy", 0, 30)
            if destroyBtn is not missing value then
                set destroyWin to win
                exit repeat
            end if
        end repeat
        if destroyBtn is missing value then return "ERROR: room-settings-destroy button not found"
        click destroyBtn
        $(ducko_as_click_button_by_label "Destroy" 'destroyWin' 'Destroy confirmation button not found')
        return "ok"
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Destroy room initiated for $ROOM_JID"
