#!/bin/bash
# Open the Bookmarks sheet from the File menu (⌘⇧B).
# Uses accessibility identifiers for reliable targeting.
# Usage: ducko-bookmarks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoUITest" to true
    delay 0.5
    tell process "DuckoUITest"
        -- Find the Contacts window (first window with contact list)
        set contactWin to missing value
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "contact-list" then
                        set contactWin to win
                        exit repeat
                    end if
                end try
            end repeat
            if contactWin is not missing value then exit repeat
        end repeat
        -- Fall back to window 1 if contact list not found
        if contactWin is missing value then set contactWin to window 1
        -- Bookmarks is on the File menu (⌘⇧B).
        keystroke "b" using {command down, shift down}
        delay 1
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Bookmarks sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
