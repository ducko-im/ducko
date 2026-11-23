#!/bin/bash
# Remove the current avatar via the profile sheet.
# Opens the profile sheet if not already open, clicks "Remove Photo".
#
# Walks the profile sheet via findByAttr rather than `entire contents`, which
# collapses on the nested profile form on macOS 26.
# Usage: ducko-avatar-remove.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

# Ensure profile sheet is open
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- ducko-profile.sh opens the profile sheet on Contacts.
            $(ducko_as_find_scene_window "contacts" "contactWin")
            if contactWin is missing value then return "ERROR: Contacts window not found"
            set removeBtn to my findInSheets(contactWin, "profile-remove-photo-button")
            if removeBtn is missing value then return "ERROR: Remove Photo button not found (no avatar set?)"
            click removeBtn
            delay 2
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Avatar removed"
else
    echo "$RESULT" >&2
    exit 1
fi
