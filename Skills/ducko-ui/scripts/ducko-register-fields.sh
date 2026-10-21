#!/bin/bash
# Complete the server's registration form in the Welcome window, shown after ducko-register.sh reported that the
# server asks for more, or print the web page the server sends the user to instead.
# Usage: ducko-register-fields.sh fill [NAME VALUE]...
#        ducko-register-fields.sh redirect
#   fill:      type each VALUE into the text field NAME (a legacy element such as nick, or a data form field var), press
#              Register and wait for the account to be registered and signed in, or for the error the window shows
#   redirect:  print the address of the registration page the server names
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

USAGE="Usage: ducko-register-fields.sh fill [NAME VALUE]... | redirect"
ACTION="${1:-}"
case "$ACTION" in
    fill)
        if (( ($# - 1) % 2 != 0 )); then echo "$USAGE" >&2; exit 1; fi ;;
    redirect)
        if (( $# != 1 )); then echo "$USAGE" >&2; exit 1; fi ;;
    *)
        echo "$USAGE" >&2; exit 1 ;;
esac

RESULT=$(osascript - "$@" << APPLESCRIPT
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
    set fieldAction to item 1 of argv
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 1
        if not (exists window "Welcome" of proc) then return "ERROR: Welcome window not found"
        set win to window "Welcome" of proc
        if (my findByAttr(win, "AXIdentifier", "register-server-form", 0, 30)) is missing value then return "ERROR: the server form is not shown (run ducko-register.sh first)"

        if fieldAction is "redirect" then
            set redirectLink to my findByAttr(win, "AXIdentifier", "registration-redirect-link", 0, 30)
            if redirectLink is missing value then return "ERROR: the server names no registration page"
            set pageAddress to ""
            try
                set pageAddress to title of redirectLink
            end try
            if pageAddress is missing value or pageAddress is "" then set pageAddress to description of redirectLink
            return "URL:" & pageAddress
        end if

        repeat with i from 2 to (count of argv) by 2
            set fieldName to item i of argv
            set fieldValue to item (i + 1) of argv
            if not (my fillField(win, "registration-" & fieldName & "-field", fieldValue)) then
                if not (my fillField(win, "data-form-field-" & fieldName, fieldValue)) then return "ERROR: no field " & fieldName
            end if
        end repeat

        set registerBtn to my findByAttr(win, "AXIdentifier", "register-button", 0, 30)
        if registerBtn is missing value then return "ERROR: register-button not found"
        click registerBtn
$(ducko_as_await_registration proc win)
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    URL:*) echo "${RESULT#URL:}" ;;
    ok)    echo "Registered" ;;
    *)     echo "$RESULT" >&2; exit 1 ;;
esac
