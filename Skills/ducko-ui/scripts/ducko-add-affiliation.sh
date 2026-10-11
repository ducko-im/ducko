#!/bin/bash
# Add a JID to a room's affiliation list via Room Settings > Members tab.
# Opens Room Settings first, switches to Members tab, fills JID, and clicks Add.
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested affiliation form on macOS 26.
# Usage: ducko-add-affiliation.sh ROOM_JID JID
#   ROOM_JID: The room JID (must be visible in the Rooms section)
#   JID:      The JID to add to the affiliation list
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-add-affiliation.sh ROOM_JID JID" >&2
    exit 1
fi

ROOM_JID="$1"
AFF_JID="$2"

# Open Room Settings sheet and switch to Members tab
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
"$SCRIPTS/ducko-room-settings-tab.sh" Members > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$AFF_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set affJID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        -- Find the window/sheet containing the affiliation field.
        set affField to missing value
        set affWin to missing value
        repeat with win in (windows of process "DuckoUITest")
            set affField to my findByAttr(win, "AXIdentifier", "affiliation-jid-field", 0, 30)
            if affField is not missing value then
                set affWin to win
                exit repeat
            end if
        end repeat
        if affField is missing value then return "ERROR: affiliation-jid-field not found (open Room Settings > Members first)"

        set focused of affField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke affJID

        set addBtn to my findByAttr(affWin, "AXIdentifier", "affiliation-add-button", 0, 30)
        if addBtn is missing value then return "ERROR: affiliation-add-button not found"
        click addBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Added $AFF_JID to affiliation list of $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
