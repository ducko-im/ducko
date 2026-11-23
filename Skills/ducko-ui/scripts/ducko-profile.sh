#!/bin/bash
# Open the My Profile sheet from the Contact menu, raising Contacts first, since the sheet opens on it.
# Succeeds once the sheet shows, or at once when it is already open.
# Usage: ducko-profile.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            if (my findInSheets(contactWin, "profile-edit-view")) is not missing value then return "ok"
            -- My Profile is on the Contact menu (no shortcut).
            try
                set profileItem to (first menu item of menu 1 of menu bar item "Contact" of menu bar 1 whose name starts with "My Profile")
            on error
                return "ERROR: My Profile menu item not found"
            end try
            if not (enabled of profileItem) then return "ERROR: My Profile menu item is disabled"
            click profileItem
            $(ducko_as_await_element '"profile-edit-view"' contactWin sheets 5 'Profile sheet did not open' profileView)
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Profile sheet opened"
