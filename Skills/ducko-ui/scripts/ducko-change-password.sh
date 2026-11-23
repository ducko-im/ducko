#!/bin/bash
# Change account password via Preferences > Accounts.
# Opens Preferences on the Accounts tab, selects the account, opens the
# Change Password sheet from the Actions pull-down, fills the fields, and submits.
# Succeeds once the sheet has closed, and fails with the sheet's error when it shows one.
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
"$SCRIPTS/ducko-preferences.sh" > /dev/null
"$SCRIPTS/ducko-preferences-tab.sh" Accounts > /dev/null
sleep 0.5

RESULT=$(osascript - "$NEW_PASSWORD" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set newPw to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
$(ducko_as_click_account_action "Change Password…")

        tell process "DuckoUITest"
            $(ducko_as_require_front_window "prefsWin" "the Preferences window")
            $(ducko_as_await_element '"new-password-field"' prefsWin sheets 5 'new-password-field not found' newField)
            $(ducko_as_fill_element "newField" "newPw")
            set confirmField to my findInSheets(prefsWin, "confirm-password-field")
            if confirmField is missing value then return "ERROR: confirm-password-field not found"
            $(ducko_as_fill_element "confirmField" "newPw")
            -- Change Password has .defaultAction keyboard shortcut
            keystroke return
            $(ducko_as_await_sheet_closed prefsWin "$DUCKO_SETTINGS_SCENE" '"new-password-field"' '"change-password-error"' 15 "Change Password sheet stayed open")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Password changed"
