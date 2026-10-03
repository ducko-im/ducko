#!/bin/bash
# Change account password via Preferences > Accounts.
# Opens Preferences on the Accounts tab, selects the account, opens the
# Change Password sheet from the Actions pull-down, fills the fields, and submits.
#
# Best-effort: selecting the account row drives a SwiftUI `List(selection:)`,
# which synthetic clicks cannot reliably trigger. Fields and buttons are located
# via findByAttr / findByRoleAndName rather than `entire contents`, which
# collapses on macOS 26.
# Usage: ducko-change-password.sh NEW_PASSWORD
#   NEW_PASSWORD: The new password to set
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-change-password.sh NEW_PASSWORD" >&2
    exit 1
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
NEW_PASSWORD="$1"

# Open Preferences > Accounts
"$SCRIPTS/ducko-preferences.sh" > /dev/null 2>&1
"$SCRIPTS/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$NEW_PASSWORD" << APPLESCRIPT
$(ducko_as_handlers)
on findAccountRow(el, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    set v to value of c
                    if v is not missing value and v contains "@" then return c
                end try
                set found to my findAccountRow(c, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findAccountRow

on run argv
    set newPw to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        set prefsWin to missing value
        repeat with win in (windows of process "DuckoApp")
            set acctRow to my findAccountRow(win, 0, 30)
            if acctRow is not missing value then
                set prefsWin to win
                try
                    click acctRow
                end try
                exit repeat
            end if
        end repeat
        if prefsWin is missing value then return "ERROR: account row not found"
        delay 0.4

        -- A SwiftUI Menu bridges as a menu/pop-up button, not AXButton, so match by identifier alone.
        set actionsMenu to my findByAttr(prefsWin, "AXIdentifier", "account-actions-menu", 0, 30)
        if actionsMenu is missing value then return "ERROR: Actions menu not found (is an account row selected and connected?)"
        tell process "DuckoApp"
$(ducko_as_click_context_menu_item "Change Password…" 'actionsMenu' 'prefsWin' "" continue)
        end tell
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
