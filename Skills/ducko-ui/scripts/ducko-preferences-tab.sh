#!/bin/bash
# Switch to a specific tab in the Preferences (Settings) window.
# The Preferences window must already be open (use ducko-preferences.sh first).
# Note: macOS titles this window after the selected tab (e.g. "General", "Accounts").
# Usage: ducko-preferences-tab.sh <General|Accounts|Chat|Status|Appearance|Advanced>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TAB="${1:?Usage: ducko-preferences-tab.sh <General|Accounts|Chat|Status|Appearance|Advanced>}"

RESULT=$(osascript - "$TAB" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set tabName to item 1 of argv
    set tabNames to {"General", "Accounts", "Chat", "Status", "Appearance", "Advanced"}
    if tabName is not in tabNames then return "ERROR: unknown tab: " & tabName
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "preferences-window" "Settings window not found (open it with ducko-preferences.sh first)" "settingsWin")

            -- Click the tab button in the toolbar
            try
                set tb to toolbar 1 of settingsWin
                set allTbElems to entire contents of tb
                repeat with elem in allTbElems
                    try
                        if role of elem is "AXButton" and name of elem is tabName then
                            click elem
                            delay 0.3
                            return "ok"
                        end if
                    end try
                end repeat
            end try

            -- Fallback: search entire window contents for a button with the tab name
            set allElems to entire contents of settingsWin
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is tabName then
                        click elem
                        delay 0.3
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: tab " & tabName & " not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Switched to tab: $TAB"
else
    echo "$RESULT" >&2
    exit 1
fi
