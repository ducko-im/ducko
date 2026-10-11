#!/bin/bash
# Select a contact row, then run a Contact menu-bar command on it.
# Usage: ducko-contact-menu.sh <JID> <get-info|history|send-file|remove>
#   get-info:  Contact > Get Info (⌘⇧I)
#   history:   Contact > History (⌘L)
#   send-file: Contact > Send File… (⌘⇧F), opening the chat with its file picker
#   remove:    Contact > Remove Contact… (⌘⌫), then confirm
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-contact-menu.sh <JID> <get-info|history|send-file|remove>" >&2
    exit 1
fi

JID="$1"
ACTION="$2"

case "$ACTION" in
    get-info)  ITEM="Get Info" ;;
    history)   ITEM="History" ;;
    send-file) ITEM="Send File…" ;;
    remove)    ITEM="Remove Contact…" ;;
    *) echo "Usage: ducko-contact-menu.sh <JID> <get-info|history|send-file|remove>" >&2; exit 1 ;;
esac

if [[ "$ACTION" == "remove" ]]; then
    ducko_require_single_app
fi

RESULT=$(osascript - "$JID" "$ACTION" "$ITEM" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set contactJID to item 1 of argv
    set menuAction to item 2 of argv
    set itemName to item 3 of argv
    set targetId to "contact-row-" & contactJID
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            -- Refuse to run over a leftover dialog, which would block or intercept the menu command.
            if (count of sheets of contactWin) > 0 then return "ERROR: a dialog is already open in the Contacts window"
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'contact row not found for " & contactJID & "' 'targetRow')
            $(ducko_as_select_table_row 'targetRow' 'could not select the row for " & contactJID & "')
            try
                set commandItem to menu item itemName of menu 1 of menu bar item "Contact" of menu bar 1
            on error
                return "ERROR: Contact menu item " & itemName & " not found"
            end try
            if not (enabled of commandItem) then return "ERROR: Contact menu item " & itemName & " is disabled"
            click commandItem
            if menuAction is "remove" then
                $(ducko_as_click_button_by_label "Remove Contact" 'contactWin' 'remove confirmation button not found')
            end if
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Contact menu '$ACTION' for $JID succeeded"
