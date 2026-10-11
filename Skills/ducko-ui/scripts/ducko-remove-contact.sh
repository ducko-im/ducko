#!/bin/bash
# Remove a contact via its context menu and confirm the removal.
# Usage: ducko-remove-contact.sh <JID>
#   JID: The JID of the contact to remove (must be visible in the contact list)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-remove-contact.sh <JID>" >&2
    exit 1
fi

JID="$1"
ducko_require_single_app

RESULT=$(osascript - "$JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set contactJID to item 1 of argv
    set targetId to "contact-row-" & contactJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            -- A leftover confirmation would otherwise be the one the confirm step presses.
            if (count of sheets of contactWin) > 0 then return "ERROR: a dialog is already open in the Contacts window"
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'contact row not found for " & contactJID & "' 'targetRow')
            $(ducko_as_click_context_menu_item "Remove Contact…" 'targetRow' 'contactWin')
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" != "ok" ]]; then
    echo "$RESULT" >&2
    exit 1
fi

CONFIRM_RESULT=$(osascript - << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    tell application "System Events"
        tell process "DuckoUITest"
            $(ducko_as_find_window_by_id "contact-list" "Contacts window not found" "contactWin")
            $(ducko_as_click_button_by_label "Remove Contact" 'contactWin' 'remove confirmation button not found')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$CONFIRM_RESULT" "Removed contact $JID"
