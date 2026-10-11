#!/bin/bash
# Open the Contact Info (Get Info) window for a contact and optionally act on it.
# Usage: ducko-contact-info.sh <JID> [block|remove]
#   No action: open Get Info via the contact's context menu (for screenshot / field reading)
#   block:     click Block/Unblock in the Contact Info window
#   remove:    click Remove Contact and confirm
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-contact-info.sh <JID> [block|remove]" >&2
    exit 1
fi

JID="$1"
ACTION="${2:-__none__}"

if [[ "$ACTION" == "remove" ]]; then
    ducko_require_single_app
fi

RESULT=$(osascript - "$JID" "$ACTION" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set contactJID to item 1 of argv
    set infoAction to item 2 of argv
    set targetId to "contact-row-" & contactJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'contact row not found for " & contactJID & "' 'targetRow')
            $(ducko_as_click_context_menu_item "Get Info" 'targetRow' 'contactWin')
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" != "ok" ]]; then
    echo "$RESULT" >&2
    exit 1
fi

if [[ "$ACTION" == "__none__" ]]; then
    echo "Opened Contact Info for $JID"
    exit 0
fi

case "$ACTION" in
    block)  BUTTON_ID="contact-info-block" ;;
    remove) BUTTON_ID="contact-info-remove" ;;
    *)      echo "ERROR: unknown action: $ACTION" >&2; exit 1 ;;
esac

ACTION_RESULT=$(osascript - "$BUTTON_ID" "$ACTION" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set buttonId to item 1 of argv
    set infoAction to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_find_window_by_id "contact-info-window" "Contact Info window not found" "infoWin")
            -- A leftover confirmation would otherwise be the one the remove step confirms.
            if infoAction is "remove" and (count of sheets of infoWin) > 0 then return "ERROR: a dialog is already open in the Contact Info window"
            $(ducko_as_click_element_by_id 'buttonId' 'infoWin' 'action button not found')
            if infoAction is "remove" then
                delay 0.5
                if (count of sheets of infoWin) is 0 then return "ERROR: remove confirmation did not appear"
                -- Search only the dialog: the form button of the window shares the "Remove Contact" name.
                set confirmSheet to sheet 1 of infoWin
                $(ducko_as_click_button_by_label "Remove Contact" 'confirmSheet' 'remove confirmation button not found')
            end if
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$ACTION_RESULT" "Contact Info action '$ACTION' for $JID succeeded"
