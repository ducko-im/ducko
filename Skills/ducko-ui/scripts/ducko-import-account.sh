#!/bin/bash
# Stage the Welcome window's Import mode in the Lume VM: seed the account data its discovery reads, tick an account
# and type its password, and remove the seeded data afterwards. Runs only in the VM, even with DUCKO_UI_HOST=1, since
# it writes the current user's real data folders.
# Usage: ducko-import-account.sh seed ACCOUNT...
#        ducko-import-account.sh fill ID PASSWORD
#        ducko-import-account.sh clean
#   seed:   write the data for each ACCOUNT (UID, or UID,SERVER,PORT) and print the ID each one got. Needs
#           DUCKO_PROFILE set to a fresh profile, and refuses when that profile's folder or the Adium 2.0 folder
#           already exists, or the profile's defaults hold values. Launch the app with ducko-launch.sh afterwards,
#           since Welcome discovers only once
#   fill:   tick account ID in the running Welcome window and type PASSWORD into its password field
#   clean:  stop the app, remove the seeded folder and the profile folder, and empty the profile's defaults. Run it
#           only after a seed that succeeded
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm

USAGE="Usage: ducko-import-account.sh seed ACCOUNT... | fill ID PASSWORD | clean"
ACTION="${1:-}"

# The volume is case-insensitive, so UITEST names the uitest profile's folder as well.
require_fresh_profile() {
    local profile="${DUCKO_PROFILE:-}"
    if [[ -z "$profile" || "$profile" == [uU][iI][tT][eE][sS][tT] || "$profile" == . || "$profile" == .. || ! "$profile" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: set DUCKO_PROFILE to a fresh profile name of its own (letters, digits, '.', '-' and '_'), not uitest" >&2
        exit 1
    fi
}

case "$ACTION" in
    seed)
        if (( $# < 2 )); then echo "$USAGE" >&2; exit 1; fi
        require_fresh_profile
        shift
        swift "$SCRIPT_DIR/ducko-import-seed.swift" seed "$DUCKO_PROFILE" "$@"
        echo "Next: launch the app with DUCKO_PROFILE=$DUCKO_PROFILE ducko-launch.sh"
        exit 0
        ;;
    clean)
        if (( $# != 1 )); then echo "$USAGE" >&2; exit 1; fi
        require_fresh_profile
        "$SCRIPT_DIR/ducko-stop.sh"
        swift "$SCRIPT_DIR/ducko-import-seed.swift" clean "$DUCKO_PROFILE"
        exit 0
        ;;
    fill)
        if (( $# != 3 )); then echo "$USAGE" >&2; exit 1; fi
        ;;
    *)
        echo "$USAGE" >&2
        exit 1
        ;;
esac

RESULT=$(osascript - "$2" "$3" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set accountId to item 1 of argv
    set pw to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")
            set accountToggle to my findByAttr(win, "AXIdentifier", "account-toggle-" & accountId, 0, 30)
            if accountToggle is missing value then return "ERROR: no account " & accountId & " in the Import list (seeded before the launch?)"
            if (value of accountToggle) is 0 then click accountToggle
            set passwordId to "account-password-" & accountId
            $(ducko_as_await_element 'passwordId' win window 5 'no password field for account " & accountId & "' passwordField)
            $(ducko_as_fill_element "passwordField" "pw")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Account $2 ticked and its password typed"
