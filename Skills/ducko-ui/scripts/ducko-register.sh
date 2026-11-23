#!/bin/bash
# Register a new account via in-band registration.
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the deeply-nested SwiftUI hierarchy on
# macOS 26. The segmented Picker exposes each segment label via AXDescription
# (AXTitle/name is empty there), so the Register segment is matched on that.
# Waits for the outcome: the account registered and signed in, the server's own form shown because it asks for
# more or refused the registration (continue with ducko-register-fields.sh), or the error the window shows.
# Usage: ducko-register.sh SERVER USERNAME PASSWORD [EMAIL]
#   SERVER:   The XMPP server domain (e.g., xmpp.example.com)
#   USERNAME: Desired username (local part)
#   PASSWORD: Desired password
#   EMAIL:    Optional email address
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 3 ]]; then
    echo "Usage: ducko-register.sh SERVER USERNAME PASSWORD [EMAIL]" >&2
    exit 1
fi

SERVER="$1"
USERNAME="$2"
PASSWORD="$3"
EMAIL="${4:-__none__}"

RESULT=$(osascript - "$SERVER" "$USERNAME" "$PASSWORD" "$EMAIL" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set serverArg to item 1 of argv
    set usernameArg to item 2 of argv
    set passwordArg to item 3 of argv
    set emailArg to item 4 of argv
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 1
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")

            -- Select the Register segment in the setup mode picker.
            set picker to my findByAttr(win, "AXIdentifier", "setup-mode-picker", 0, 30)
            if picker is missing value then return "ERROR: setup-mode-picker not found"
            set seg to my findByAttr(picker, "AXDescription", "Register", 0, 6)
            if seg is missing value then return "ERROR: Register segment not found"
            click seg

            -- Fill in the registration fields.
            $(ducko_as_await_element '"register-server-field"' win window 5 'register-server-field not found' serverField)
            $(ducko_as_fill_element "serverField" "serverArg")
            $(ducko_as_fill_field_by_id '"register-username-field"' 'win' 'usernameArg' 'register-username-field not found')
            $(ducko_as_fill_field_by_id '"register-password-field"' 'win' 'passwordArg' 'register-password-field not found')
            if emailArg is not "__none__" then
                $(ducko_as_fill_field_by_id '"register-email-field"' 'win' 'emailArg' 'register-email-field not found')
            end if

            $(ducko_as_click_element_by_id '"register-button"' 'win' 'register-button not found')
$(ducko_as_await_welcome_outcome proc win MORE)
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok)   echo "Registered $USERNAME@$SERVER" ;;
    MORE) echo "The server asks for more details or refused the registration: fill its form with ducko-register-fields.sh fill, or read its web page with ducko-register-fields.sh redirect" ;;
    *)    echo "$RESULT" >&2; exit 1 ;;
esac
