#!/bin/bash
# Open the Edit sheet of an account from Preferences > Accounts.
# Opens Preferences on the Accounts tab, selects the account row and presses Edit….
# Succeeds once the sheet shows allowPlainToggle.
# Usage: ducko-edit-account.sh [ACCOUNT_JID]
#   ACCOUNT_JID: the account to edit (default: the first account in the list)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACCOUNT_JID="${1:-}"

"$SCRIPT_DIR/ducko-preferences.sh" > /dev/null
"$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null
sleep 0.5

RESULT=$(osascript - "$ACCOUNT_JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set accountJid to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
$(ducko_as_select_account_row accountJid)
        tell process "DuckoUITest"
            $(ducko_as_click_element_by_id '"account-edit-button"' 'prefsWin' 'Edit button not found')
            $(ducko_as_await_element '"allowPlainToggle"' prefsWin sheets 5 'the Edit sheet did not open' plainToggle)
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Edit sheet opened"
