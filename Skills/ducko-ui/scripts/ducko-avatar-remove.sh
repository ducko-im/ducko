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
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null 2>&1 || true

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        -- Find the window containing the profile sheet.
        set profileWin to missing value
        repeat with win in (windows of process "DuckoUITest")
            if (my findByAttr(win, "AXIdentifier", "profile-edit-view", 0, 30)) is not missing value then
                set profileWin to win
                exit repeat
            end if
        end repeat
        if profileWin is missing value then return "ERROR: Profile sheet not found"

        set removeBtn to my findByAttr(profileWin, "AXIdentifier", "profile-remove-photo-button", 0, 30)
        if removeBtn is missing value then return "ERROR: Remove Photo button not found (no avatar set?)"
        click removeBtn
        delay 2
        return "ok"
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
