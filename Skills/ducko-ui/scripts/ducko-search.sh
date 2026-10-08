#!/bin/bash
# Toggle the find bar of the frontmost Ducko window, the chat window or
# Chat History, via Cmd+F.
# With a QUERY argument, types and submits the search.
# Usage: ducko-search.sh [QUERY]
#   No args:   toggles find bar open/closed
#   QUERY:     opens find bar, types QUERY, and submits
set -euo pipefail

QUERY="${1:-}"

RESULT=$(osascript - "$QUERY" << 'APPLESCRIPT'
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            if query is "" then
                -- Toggle find bar open/closed
                keystroke "f" using command down
                delay 0.3
                return "toggled"
            end if

            -- Check if find bar is already open by looking for its identifier
            set searchField to missing value
            set frontWin to window 1
            set allElems to entire contents of frontWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "message-search-bar" then
                        set searchField to elem
                        exit repeat
                    end if
                end try
            end repeat

            -- Open find bar if not already open
            if searchField is missing value then
                keystroke "f" using command down
                delay 0.5
            else
                -- Find bar already open — ensure focus is on the search field
                set focused of searchField to true
                delay 0.2
            end if

            -- Select all existing text in search field, then type query
            keystroke "a" using command down
            delay 0.1
            keystroke query
            delay 0.3
            keystroke return
            return "searched"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)  echo "Find bar toggled" ;;
    searched) echo "Searched: $QUERY" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
