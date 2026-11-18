#!/bin/bash
# Type a message in the active chat tab and press Return to send it.
# Raises the chat window first, since the keystrokes go to whatever window is key.
# Succeeds once the message list holds more messages with the text than before.
# Usage: ducko-send.sh MESSAGE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

MESSAGE="${1:?Usage: ducko-send.sh MESSAGE}"

RESULT=$(osascript - "$MESSAGE" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set msg to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            $(ducko_as_find_element_by_id '"message-list"' 'chatWin' 'message-list not found in the chat window' 'msgRoot')
            $(ducko_as_find_element_by_id '"message-field"' 'chatWin' 'message-field not found in the chat window' 'messageField')
            -- Counted rather than searched for, so an earlier message with the same text does not confirm the send.
            set priorCount to count of (my messageTextsContaining(msgRoot, msg))
            $(ducko_as_fill_element "messageField" "msg")
            keystroke return

            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                if (count of (my messageTextsContaining(msgRoot, msg))) > priorCount then return "ok"
            end repeat
            return "ERROR: the message did not appear in the chat"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Sent: $MESSAGE"
