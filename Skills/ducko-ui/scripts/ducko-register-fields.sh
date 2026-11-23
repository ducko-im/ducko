#!/bin/bash
# Complete the server's registration form in the Welcome window's sheet, shown after ducko-register.sh reported that
# the server asks for more or refused the registration, or print the web page the server sends the user to instead.
# Usage: ducko-register-fields.sh fill [NAME VALUE]...
#        ducko-register-fields.sh redirect
#        ducko-register-fields.sh captcha [VAR]
#   fill:      type each VALUE into the text field NAME (a legacy element such as nick, or a data form field var), press
#              the sheet's Register and wait for the account to be registered and signed in, the server's refusal over
#              a fresh form, or the error the window shows
#   redirect:  print the address of the registration page the server names
#   captcha:   print, for the CAPTCHA image, its web link, the fallback link, the unanswerable note and the answer
#              field of challenge VAR (default ocr), whether each is shown and its vertical position, then the image's
#              role, description and title
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

USAGE="Usage: ducko-register-fields.sh fill [NAME VALUE]... | redirect | captcha [VAR]"
ACTION="${1:-}"
case "$ACTION" in
    fill)
        if (( ($# - 1) % 2 != 0 )); then echo "$USAGE" >&2; exit 1; fi ;;
    redirect)
        if (( $# != 1 )); then echo "$USAGE" >&2; exit 1; fi ;;
    captcha)
        if (( $# > 2 )); then echo "$USAGE" >&2; exit 1; fi ;;
    *)
        echo "$USAGE" >&2; exit 1 ;;
esac

RESULT=$(osascript - "$@" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set fieldAction to item 1 of argv
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 1
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")
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

            if fieldAction is "captcha" then
                set challengeVar to "ocr"
                if (count of argv) > 1 then set challengeVar to item 2 of argv
                set report to ""
                repeat with elementId in {"registration-captcha-image", "registration-captcha-image-link", "registration-captcha-fallback-link", "registration-captcha-unanswerable", "data-form-field-" & challengeVar}
                    set captchaElement to my findByAttr(win, "AXIdentifier", elementId as text, 0, 30)
                    if captchaElement is missing value then
                        set report to report & elementId & ": absent" & linefeed
                    else
                        set report to report & elementId & ": y=" & (item 2 of (position of captchaElement as list)) & linefeed
                    end if
                end repeat
                set captchaImage to my findByAttr(win, "AXIdentifier", "registration-captcha-image", 0, 30)
                if captchaImage is not missing value then
                    repeat with attributeName in {"AXRole", "AXDescription", "AXTitle"}
                        set attributeValue to "none"
                        try
                            set attributeValue to (value of attribute (attributeName as text) of captchaImage) as text
                        end try
                        set report to report & "image " & attributeName & ": " & attributeValue & linefeed
                    end repeat
                end if
                return "REPORT:" & report
            end if

            repeat with i from 2 to (count of argv) by 2
                set fieldName to item i of argv
                set fieldValue to item (i + 1) of argv
                set formField to my findByAttr(win, "AXIdentifier", "registration-" & fieldName & "-field", 0, 30)
                if formField is missing value then set formField to my findByAttr(win, "AXIdentifier", "data-form-field-" & fieldName, 0, 30)
                if formField is missing value then return "ERROR: no field " & fieldName
                $(ducko_as_fill_element "formField" "fieldValue")
            end repeat

            $(ducko_as_click_element_by_id '"register-server-form-submit"' 'win' 'register-server-form-submit not found')
$(ducko_as_await_welcome_outcome proc win)
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    URL:*) echo "${RESULT#URL:}" ;;
    REPORT:*) printf '%s\n' "${RESULT#REPORT:}" ;;
    ok)    echo "Registered" ;;
    *)     echo "$RESULT" >&2; exit 1 ;;
esac
