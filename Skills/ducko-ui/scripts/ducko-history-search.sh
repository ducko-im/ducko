#!/bin/bash
# Search all conversations in the Chat History window: raise the window, put
# the cursor in its toolbar search field with Opt+Cmd+F, and type QUERY.
# The window has to be open already (File > Chat History, Opt+Cmd+T).
# Usage: ducko-history-search.sh QUERY
set -euo pipefail

QUERY="${1:?Usage: ducko-history-search.sh QUERY}"

RESULT=$(osascript - "$QUERY" << 'APPLESCRIPT'
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            -- Found by its own identifier: its title is the name of the conversation it shows.
            set historyWin to missing value
            repeat with win in windows
                try
                    if value of attribute "AXIdentifier" of win is "transcripts" then
                        set historyWin to win
                        exit repeat
                    end if
                end try
            end repeat
            if historyWin is missing value then return "ERROR: Chat History window not found"
            perform action "AXRaise" of historyWin
            delay 0.3

            keystroke "f" using {command down, option down}
            delay 0.3
            -- Replace whatever the field holds.
            keystroke "a" using command down
            delay 0.1
            keystroke query
            return "searched"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    searched) echo "Searched all conversations: $QUERY" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
