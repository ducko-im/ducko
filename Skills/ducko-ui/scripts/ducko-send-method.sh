#!/bin/bash
# Choose how the files queued in the active chat are sent, from the pop-up in
# the pending attachment bar. The pop-up shows only in a one-to-one chat with
# at least one file queued (see ducko-attach.sh).
# Usage: ducko-send-method.sh [upload|direct]
#   No args: print the way currently chosen
#   upload:  select "Upload"
#   direct:  select "Send Directly"; fails when the contact has no device
#            online that takes direct transfers
set -euo pipefail

ACTION="${1:-__none__}"

case "$ACTION" in
    __none__) LABEL="" ;;
    upload)   LABEL="Upload" ;;
    direct)   LABEL="Send Directly" ;;
    *)        echo "Usage: ducko-send-method.sh [upload|direct]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")
            $(ducko_as_find_element_by_id '"attachment-send-method"' 'chatWin' "attachment-send-method not found: queue a file in a one-to-one chat first" "methodElem")
            if "${LABEL}" is "" then return "value: " & (value of methodElem as text)
            $(ducko_as_click_context_menu_item "${LABEL}" "methodElem" "chatWin" "${LABEL} is not available")
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    value:*) echo "${RESULT#value: }" ;;
    *)       ducko_check_result "$RESULT" "Send method: ${LABEL}" ;;
esac
