#!/bin/bash
# Reset OMEMO encryption sessions from the active one-to-one chat.
# Usage: ducko-omemo-reset.sh <all|device> [DEVICE_ID]
#   all:                 choose "Reset Encryption Sessions" in the chat header's encryption menu, resetting the
#                        sessions with every device of the contact. The item is disabled while offline.
#   device DEVICE_ID:    press the device row's "Reset Session" button in the Device Fingerprints sheet, which must
#                        already be open (via ducko-encrypt.sh fingerprints). The row may be one of the contact's
#                        devices or one of the account's other devices.
#
# A reset with the contact's devices adds a timeline note saying what it did. A reset of one of the account's other
# devices adds none. `all` for a contact with no OMEMO devices shows a send-error banner instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

USAGE="Usage: ducko-omemo-reset.sh <all|device> [DEVICE_ID]"
ACTION="${1:-}"
DEVICE_ID="${2:-}"

case "$ACTION" in
    all)
        if [[ -n "$DEVICE_ID" ]]; then echo "$USAGE" >&2; exit 1; fi ;;
    device)
        if [[ -z "$DEVICE_ID" ]]; then echo "Usage: ducko-omemo-reset.sh device DEVICE_ID" >&2; exit 1; fi ;;
    *)
        echo "$USAGE" >&2; exit 1 ;;
esac

RESULT=$(osascript - "$ACTION" "$DEVICE_ID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set resetAction to item 1 of argv
    set deviceID to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            if resetAction is "device" then
                set targetId to "reset-session-button-" & deviceID
                set resetButton to my findInSheets(chatWin, targetId)
                if resetButton is missing value then return "ERROR: Reset Session button not found for device " & deviceID & " (is the Device Fingerprints sheet open?)"
                click resetButton
                return "ok"
            end if
            $(ducko_as_find_element_by_id '"encryption-menu"' 'chatWin' "encryption-menu not found" "encMenu")
            $(ducko_as_click_context_menu_item "Reset Encryption Sessions" "encMenu" "chatWin" "Reset Encryption Sessions is not available: it needs a one-to-one chat and a connected account")
        end tell
    end tell
end run
APPLESCRIPT
)

case "$ACTION" in
    all)    ducko_check_result "$RESULT" "Reset the encryption sessions with every device of the contact" ;;
    device) ducko_check_result "$RESULT" "Reset the session with device $DEVICE_ID" ;;
esac
