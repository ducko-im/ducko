#!/bin/bash
# Press the jump button in the active chat's message list, which brings the newest message into view.
# The button is only there while the list is scrolled away from the newest message.
# Usage: ducko-message-list.sh jump
set -euo pipefail

if [[ $# -lt 1 || "$1" != jump ]]; then
    echo "Usage: ducko-message-list.sh jump" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "jump-to-newest" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set buttonId to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id 'buttonId' 'chatWin' 'jump button not found: the message list is at the newest message')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Jumped to the newest message"
