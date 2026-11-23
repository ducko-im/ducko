#!/bin/bash
# Search all conversations in the Chat History window: raise the window, put
# the cursor in its toolbar search field with Opt+Cmd+F, and type QUERY.
# Succeeds once the field holds QUERY.
# The window has to be open already (File > Chat History, Opt+Cmd+T).
# Usage: ducko-history-search.sh QUERY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

QUERY="${1:?Usage: ducko-history-search.sh QUERY}"

RESULT=$(osascript - "$QUERY" << APPLESCRIPT
$(ducko_as_handlers)

-- The search field in the Chat History toolbar, or missing value. It is looked up by role inside the toolbar only,
-- so the field of the find bar cannot match.
on toolbarSearchField()
    tell application "System Events"
        tell process "DuckoUITest"
$(ducko_as_find_scene_window "transcripts" "historyWin")
            if historyWin is missing value then return missing value
            try
                return item 1 of (my collectByRole(toolbar 1 of historyWin, "AXTextField", 0, 10))
            end try
        end tell
    end tell
    return missing value
end toolbarSearchField

on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Found by its own identifier: its title is the name of the conversation it shows.
            $(ducko_as_raise_scene_window "transcripts" "Chat History window not found" "historyWin")

            keystroke "f" using {command down, option down}
            delay 0.3
            set toolbarSearch to my toolbarSearchField()
            if toolbarSearch is missing value then return "ERROR: the toolbar search field was not found"
            $(ducko_as_fill_element "toolbarSearch" "query")
            -- The search changes the window title to the conversation it shows, which leaves a field reference made
            -- under the old title pointing nowhere, so the field is found again on each pass.
            set fieldDeadline to (current date) + 2
            repeat
                set fieldValue to ""
                try
                    set fieldValue to value of (my toolbarSearchField())
                end try
                if fieldValue is missing value then set fieldValue to ""
                considering case
                    if fieldValue is query then return "ok"
                end considering
                if (current date) > fieldDeadline then return "ERROR: the field does not hold the typed text"
                delay 0.2
            end repeat
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Searched all conversations: $QUERY"
