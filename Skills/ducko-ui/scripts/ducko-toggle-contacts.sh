#!/bin/bash
# Toggle the Contacts window via Window > Hide/Show Contact List (⌘/): closes
# it when it is the focused window, otherwise opens and raises it.
# Usage: ducko-toggle-contacts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoUITest" to true
    delay 0.3
    tell process "DuckoUITest"
        set windowMenu to menu 1 of menu bar item "Window" of menu bar 1
        try
            if exists menu item "Hide Contact List" of windowMenu then
                click menu item "Hide Contact List" of windowMenu
            else
                click menu item "Show Contact List" of windowMenu
            end if
        on error
            return "ERROR: Window > Show/Hide Contact List menu item not found"
        end try
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Contacts window toggled"
else
    echo "$RESULT" >&2
    exit 1
fi
