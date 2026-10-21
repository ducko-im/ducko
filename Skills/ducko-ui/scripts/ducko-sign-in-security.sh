#!/bin/bash
# Answer the Sign-In Refused alert on the Contacts window. It shows when an account that has signed in without sending
# its password meets a server offering only a sign-in that sends it.
# Usage: ducko-sign-in-security.sh <keep|reset>
#   keep:  Keep Refusing, which hides the alert until the next refused sign-in
#   reset: Reset Sign-In Security…, then Reset and Sign In in its confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACTION="${1:-}"
case "$ACTION" in
    keep)  SUCCESS="Kept refusing the sign-in" ;;
    reset) SUCCESS="Reset sign-in security" ;;
    *) echo "Usage: ducko-sign-in-security.sh <keep|reset>" >&2; exit 1 ;;
esac

if [[ "$ACTION" == "reset" ]]; then
    ducko_require_single_app
fi

RESULT=$(osascript - "$ACTION" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set signInAction to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")
            if signInAction is "keep" then
                $(ducko_as_click_button_by_label "Keep Refusing" 'contactWin' 'Sign-In Refused alert not found')
            else
                $(ducko_as_click_button_by_label "Reset Sign-In Security…" 'contactWin' 'Sign-In Refused alert not found')
                $(ducko_as_click_button_by_label "Reset and Sign In" 'contactWin' 'reset confirmation not found')
            end if
            set deadline to (current date) + 5
            repeat while (count of sheets of contactWin) > 0
                if (current date) > deadline then return "ERROR: the Contacts window still shows a dialog"
                delay 0.2
            end repeat
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "$SUCCESS"
