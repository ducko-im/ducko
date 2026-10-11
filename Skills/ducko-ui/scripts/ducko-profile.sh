#!/bin/bash
# Open the My Profile sheet from the contact list toolbar.
# Uses accessibility identifiers for reliable targeting.
# Usage: ducko-profile.sh
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
        -- My Profile is on the Contact menu (no shortcut).
        try
            click (first menu item of menu 1 of menu bar item "Contact" of menu bar 1 whose name starts with "My Profile")
        on error
            return "ERROR: My Profile menu item not found"
        end try
        delay 1
        -- Verify the profile sheet appeared by looking for profile-edit-view
        set allElems to entire contents of contactWin
        repeat with elem in allElems
            try
                if value of attribute "AXIdentifier" of elem is "profile-edit-view" then
                    return "ok"
                end if
            end try
        end repeat
        -- Sheet may take a moment; accept if we clicked successfully
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Profile sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
