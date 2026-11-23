#!/bin/bash
# Add a JID to a room's affiliation list via Room Settings > Members tab.
# Opens Room Settings first, switches to Members tab, fills JID, and clicks Add.
# Succeeds once the list shows a row for the JID. The app shows no error when the server refuses the change, so a
# refusal reports only that no row appeared.
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
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null
"$SCRIPTS/ducko-room-settings-tab.sh" Members > /dev/null

RESULT=$(osascript - "$AFF_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set affJID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            $(ducko_as_await_element '"affiliation-jid-field"' contactWin sheets 5 'affiliation-jid-field not found (open Room Settings > Members first)' affField)
            $(ducko_as_fill_element "affField" "affJID")
            set addBtn to my findInSheets(contactWin, "affiliation-add-button")
            if addBtn is missing value then return "ERROR: affiliation-add-button not found"
            click addBtn

            set rowId to "affiliation-row-" & affJID
            $(ducko_as_await_element 'rowId' contactWin sheets 10 'no affiliation row for " & affJID & " appeared (refused by the server?)' affRow)
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Added $AFF_JID to affiliation list of $ROOM_JID"
