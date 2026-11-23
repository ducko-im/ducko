#!/bin/bash
# Toggle the find bar of the frontmost Ducko window, the chat window or
# Chat History, via Cmd+F.
# With a QUERY argument, types and submits the search, keeping a find bar that is already open, and prints the
# number of matches once the search has finished.
# Usage: ducko-search.sh [QUERY]
#   No args:   toggles find bar open/closed
#   QUERY:     opens find bar, types QUERY, submits, and prints "Matches: N"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

QUERY="${1:-}"

RESULT=$(osascript - "$QUERY" << APPLESCRIPT
$(ducko_as_handlers)

-- The total that the find bar of the window with scene id sceneId shows once its search has finished, or "0" when
-- it shows no count. Missing value while the window, the bar or its field is missing, or while the progress shows.
-- Chat History is titled after the conversation it shows, which a search changes, so the window is found again on
-- each call.
on searchBarTotal(sceneId)
    tell application "System Events"
        tell process "DuckoUITest"
$(ducko_as_find_scene_window_expr "sceneId" "searchWin")
            if searchWin is missing value then return missing value
            set searchBar to my findByAttr(searchWin, "AXIdentifier", "message-search-bar", 0, 30)
            if searchBar is missing value then return missing value
            if (my findByAttr(searchBar, "AXIdentifier", "message-search-field", 0, 5)) is missing value then return missing value
            if (my findByAttr(searchBar, "AXIdentifier", "message-search-progress", 0, 5)) is not missing value then return missing value
            set countText to my findByAttr(searchBar, "AXIdentifier", "message-search-count", 0, 5)
            if countText is missing value then return "0"
            set totalText to value of countText
            -- While a match is current, the count reads "current/total".
            if totalText contains "/" then set totalText to text ((offset of "/" in totalText) + 1) thru -1 of totalText
            return totalText
        end tell
    end tell
end searchBarTotal

on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            set frontWin to missing value
            try
                set frontWin to window 1
            end try
            if frontWin is missing value then return "ERROR: no DuckoUITest window"
            set sceneId to ""
            try
                set sceneId to value of attribute "AXIdentifier" of frontWin
            end try
            if sceneId is not "chat" and sceneId is not "transcripts" then return "ERROR: the front window is neither the chat window nor Chat History"
            $(ducko_as_require_front_window "frontWin" "the front window")

            if query is "" then
                -- Toggle find bar open/closed
                keystroke "f" using command down
                delay 0.3
                return "toggled"
            end if

            set searchField to my findByAttr(frontWin, "AXIdentifier", "message-search-field", 0, 30)
            if searchField is missing value then
                keystroke "f" using command down
                $(ducko_as_await_element '"message-search-field"' frontWin window 5 'message-search-field not found' searchField 'sceneId')
            end if
            $(ducko_as_fill_element "searchField" "query")
            keystroke return

            -- Chat History starts a search after a short delay and adds matches one day at a time while its
            -- progress shows. So the count is read only once a second has passed, and a total counts only when two
            -- passes in a row read it.
            set submittedAt to current date
            set lastTotal to missing value
            repeat until (current date) > submittedAt + 15
                delay 0.5
                set passTotal to missing value
                if (current date) > submittedAt + 1 then set passTotal to my searchBarTotal(sceneId)
                if passTotal is not missing value and passTotal is lastTotal then return "MATCHES:" & passTotal
                set lastTotal to passTotal
            end repeat
            return "ERROR: the search did not finish"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)   echo "Find bar toggled" ;;
    MATCHES:*) echo "Matches: ${RESULT#MATCHES:}" ;;
    *)         echo "$RESULT" >&2; exit 1 ;;
esac
