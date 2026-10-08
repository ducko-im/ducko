#!/bin/bash
# Click a chat-header toolbar button (Profile info or History) in the active chat window.
# Usage: ducko-chat-header.sh <info|history>
#   info:    click the Profile-info (i) button — opens the Contact Info window
#   history: click the History (clock) button — opens the Chat History window on the contact
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-chat-header.sh <info|history>" >&2
    exit 1
fi

case "$1" in
    info)    BUTTON_ID="contact-info-button" ;;
    history) BUTTON_ID="history-button" ;;
    *)       echo "Usage: ducko-chat-header.sh <info|history>" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$BUTTON_ID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set buttonId to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id 'buttonId' 'chatWin' 'header button not found')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Clicked chat-header button: $1"
