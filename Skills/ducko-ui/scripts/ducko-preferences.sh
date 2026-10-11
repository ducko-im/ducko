#!/bin/bash
# Open the Preferences (Settings) window via Cmd+,.
# If the window is already open, raises it to the front.
# Note: macOS titles this window after the selected tab (e.g. "General", "Accounts").
# Usage: ducko-preferences.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoUITest" to true
    delay 0.3
    tell process "DuckoUITest"
        -- The Settings window title matches the active tab name.
        set tabNames to {"General", "Accounts", "Chat", "Status", "Appearance", "Advanced"}
        set settingsOpen to false
        repeat with win in windows
            if name of win is in tabNames then
                -- Verify this is the Settings window (not a chat window with the same title)
                -- by checking that its toolbar contains tab buttons matching tabNames.
                set isSettings to false
                try
                    set tbElems to entire contents of toolbar 1 of win
                    repeat with elem in tbElems
                        try
                            if role of elem is "AXButton" and name of elem is in tabNames then
                                set isSettings to true
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                if isSettings then
                    perform action "AXRaise" of win
                    set settingsOpen to true
                    exit repeat
                end if
            end if
        end repeat

        if settingsOpen then return "ok"

        keystroke "," using command down
        delay 0.5

        -- Verify the Settings window actually appeared (check toolbar to distinguish from chat windows)
        repeat with win in windows
            if name of win is in tabNames then
                try
                    set tbElems to entire contents of toolbar 1 of win
                    repeat with elem in tbElems
                        try
                            if role of elem is "AXButton" and name of elem is in tabNames then
                                return "ok"
                            end if
                        end try
                    end repeat
                end try
            end if
        end repeat
        return "ERROR: Settings window did not open after Cmd+,"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Preferences window opened"
else
    echo "$RESULT" >&2
    exit 1
fi
