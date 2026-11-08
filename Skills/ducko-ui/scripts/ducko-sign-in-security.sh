#!/bin/bash
# Answer the Sign-In Refused alert on the Contacts window. It shows when a server offers only a sign-in that sends the
# password to an account that does not allow it.
# Usage: ducko-sign-in-security.sh <dont-allow|allow>
#   dont-allow: Don't Allow, which hides the alert until the next refused sign-in
#   allow:      Allow Sending Password…, then Allow and Sign In in its confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACTION="${1:-}"
case "$ACTION" in
    dont-allow) SUCCESS="Did not allow sending the password" ;;
    allow)      SUCCESS="Allowed sending the password" ;;
    *) echo "Usage: ducko-sign-in-security.sh <dont-allow|allow>" >&2; exit 1 ;;
esac

if [[ "$ACTION" == "allow" ]]; then
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
            if signInAction is "dont-allow" then
                $(ducko_as_click_button_by_label "Don't Allow" 'contactWin' 'Sign-In Refused alert not found')
            else
                $(ducko_as_click_button_by_label "Allow Sending Password…" 'contactWin' 'Sign-In Refused alert not found')
                $(ducko_as_click_button_by_label "Allow and Sign In" 'contactWin' 'allow confirmation not found')
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
