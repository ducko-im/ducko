#!/bin/bash
# Right-click a message in the active chat window and select Reply.
# Usage: ducko-reply.sh [TEXT]
#   No args:   replies to the last message
#   TEXT:       replies to the first message containing TEXT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TEXT="${1:-}"

RESULT=$(osascript - "$TEXT" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set searchText to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_find_window_by_id "message-field" "no chat window found" "chatWin")

            $(ducko_as_find_message_by_text "searchText" "chatWin")

            $(ducko_as_click_context_menu_item "Reply" 'targetElem' 'chatWin')
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Reply compose bar opened"
