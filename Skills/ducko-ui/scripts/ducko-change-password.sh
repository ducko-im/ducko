#!/bin/bash
# Change account password via Preferences > Accounts.
# Opens Preferences on the Accounts tab, selects the account, opens the
# Change Password sheet from the Actions pull-down, fills the fields, and submits.
#
# The Actions pull-down only appears once the account is connected. Fields and
# buttons are located via findByAttr / findByRoleAndName rather than
# `entire contents`, which collapses on macOS 26.
# Usage: ducko-change-password.sh NEW_PASSWORD
#   NEW_PASSWORD: The new password to set
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-change-password.sh NEW_PASSWORD" >&2
    exit 1
fi

NEW_PASSWORD="$1"

# Open Preferences > Accounts
"$SCRIPTS/ducko-preferences.sh" > /dev/null 2>&1
"$SCRIPTS/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$NEW_PASSWORD" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set newPw to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
$(ducko_as_click_account_action "Change Password…")
        delay 0.5

        set newField to my findByAttr(prefsWin, "AXIdentifier", "new-password-field", 0, 30)
        if newField is missing value then return "ERROR: new-password-field not found"
        set focused of newField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke newPw

        set confirmField to my findByAttr(prefsWin, "AXIdentifier", "confirm-password-field", 0, 30)
        if confirmField is missing value then return "ERROR: confirm-password-field not found"
        set focused of confirmField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke newPw
        delay 0.2

        keystroke return
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Password change submitted"
else
    echo "$RESULT" >&2
    exit 1
fi
