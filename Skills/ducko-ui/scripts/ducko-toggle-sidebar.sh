#!/bin/bash
# Toggle the participant sidebar in the active chat window.
# Only works for groupchat (MUC) conversations. Uses accessibility identifiers.
# Usage: ducko-toggle-sidebar.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoUITest" to true
    delay 0.5
    tell process "DuckoUITest"
        -- Find the toggle button in the frontmost window
        set chatWin to window 1
        set clicked to false
        set allElems to entire contents of chatWin
        repeat with elem in allElems
            try
                set elemId to value of attribute "AXIdentifier" of elem
                if elemId is "toggle-participant-sidebar" then
                    click elem
                    set clicked to true
                    exit repeat
                end if
            end try
        end repeat
        if not clicked then return "ERROR: toggle-participant-sidebar not found (is this a groupchat window?)"
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Participant sidebar toggled"
else
    echo "$RESULT" >&2
    exit 1
fi
