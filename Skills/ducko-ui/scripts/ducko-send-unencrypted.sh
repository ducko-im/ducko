#!/bin/bash
# Press "Send Unencrypted" in the active chat, which switches encryption off and sends the message a contact's
# request for unencrypted messages blocked. The button shows in the banner above the message field only while
# such a request blocks the last send, and not when the blocked send was an edit or files.
# Usage: ducko-send-unencrypted.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id '"send-unencrypted-button"' 'chatWin' "send-unencrypted-button not found: no request for unencrypted messages blocks a send")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Sent unencrypted"
