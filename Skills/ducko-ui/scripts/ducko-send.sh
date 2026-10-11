#!/bin/bash
# Type a message in the chat input field and press Return to send.
# Targets the frontmost window with a message-field (chat window).
# Usage: ducko-send.sh MESSAGE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

MESSAGE="${1:?Usage: ducko-send.sh MESSAGE}"

RESULT=$(osascript - "$MESSAGE" << 'APPLESCRIPT'
on run argv
    set msg to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Find the chat window (window containing message-field)
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "message-field" then
                            set focused of elem to true
                            delay 0.2
                            keystroke "a" using command down
                            delay 0.1
                            keystroke msg
                            delay 0.3
                            keystroke return
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
    end tell
    return "ERROR: message-field not found in any window"
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Sent: $MESSAGE"
else
    echo "$RESULT" >&2
    exit 1
fi
