#!/bin/bash
# Retract a message via its context menu in the active chat window.
# Usage: ducko-retract.sh [TEXT]
#   No args:   retracts the last outgoing message
#   TEXT:       retracts the first message containing TEXT
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
            $(ducko_as_raise_scene_window "chat" "no chat window found" "chatWin")

            $(ducko_as_find_message_by_text "searchText" "chatWin")

            $(ducko_as_click_context_menu_item "Retract" 'targetElem' 'chatWin' "Retract menu item not found (not an outgoing message?)")
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Message retracted"
