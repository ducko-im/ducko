#!/bin/bash
# Register a new account via in-band registration.
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the deeply-nested SwiftUI hierarchy on
# macOS 26. The segmented Picker exposes each segment label via AXDescription
# (AXTitle/name is empty there), so the Register segment is matched on that.
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
on fillField(win, fieldId, fieldValue)
    set theField to my findByAttr(win, "AXIdentifier", fieldId, 0, 30)
    if theField is missing value then return false
    tell application "System Events"
        set focused of theField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke fieldValue
    end tell
    return true
end fillField

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
        if not (exists window "Welcome" of proc) then return "ERROR: Welcome window not found"
        set win to window "Welcome" of proc

        -- Select the Register segment in the setup mode picker.
        set picker to my findByAttr(win, "AXIdentifier", "setup-mode-picker", 0, 30)
        if picker is missing value then return "ERROR: setup-mode-picker not found"
        set seg to my findByAttr(picker, "AXDescription", "Register", 0, 6)
        if seg is missing value then return "ERROR: Register segment not found"
        click seg
        delay 0.5

        -- Fill in the registration fields.
        if not (my fillField(win, "register-server-field", serverArg)) then return "ERROR: register-server-field not found"
        if not (my fillField(win, "register-username-field", usernameArg)) then return "ERROR: register-username-field not found"
        if not (my fillField(win, "register-password-field", passwordArg)) then return "ERROR: register-password-field not found"
        if emailArg is not "__none__" then
            my fillField(win, "register-email-field", emailArg)
        end if

        set registerBtn to my findByAttr(win, "AXIdentifier", "register-button", 0, 30)
        if registerBtn is missing value then return "ERROR: register-button not found"
        click registerBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Registration initiated for $USERNAME@$SERVER"
else
    echo "$RESULT" >&2
    exit 1
fi
