#!/bin/bash
# Search for channels in the Join Room dialog.
# The Join Room dialog must already be open (via ducko-join-room.sh or manually).
# Uses accessibility identifiers for reliable targeting.
# Usage: ducko-channel-search.sh QUERY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

QUERY="${1:?Usage: ducko-channel-search.sh QUERY}"

RESULT=$(osascript - "$QUERY" << 'APPLESCRIPT'
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Find the Contacts window containing the channel search field
            set contactWin to missing value
            set searchField to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "channel-search-field" then
                            set contactWin to win
                            set searchField to elem
                            exit repeat
                        end if
                    end try
                end repeat
                if contactWin is not missing value then exit repeat
            end repeat
            if contactWin is missing value then return "ERROR: channel-search-field not found (is Join Room dialog open?)"
            -- Focus the search field and type the query
            set focused of searchField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke query
            delay 0.3
            -- Click the search button to submit
            set clicked to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "channel-search-button" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            -- Fall back to pressing Return if button not found
            if not clicked then keystroke return
            delay 1
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Channel search submitted: $QUERY"
else
    echo "$RESULT" >&2
    exit 1
fi
