#!/bin/bash
# Edit profile fields and optionally save.
# Opens the profile sheet first if not already open.
#
# Walks the profile sheet via findByAttr rather than `entire contents`, which
# collapses on the nested profile form on macOS 26.
# Usage: ducko-edit-profile.sh [--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

FULLNAME="__none__"
NICKNAME="__none__"
EMAIL="__none__"
SAVE="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fullname) FULLNAME="$2"; shift 2 ;;
        --nickname) NICKNAME="$2"; shift 2 ;;
        --email)    EMAIL="$2"; shift 2 ;;
        --save)     SAVE="yes"; shift ;;
        *)
            echo "Usage: ducko-edit-profile.sh [--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]" >&2
            exit 1
            ;;
    esac
done

# Open profile sheet
"$SCRIPTS/ducko-profile.sh" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$FULLNAME" "$NICKNAME" "$EMAIL" "$SAVE" << APPLESCRIPT
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
    set fullnameArg to item 1 of argv
    set nicknameArg to item 2 of argv
    set emailArg to item 3 of argv
    set saveArg to item 4 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        -- Find the window containing the profile edit view.
        set profileWin to missing value
        repeat with win in (windows of process "DuckoUITest")
            if (my findByAttr(win, "AXIdentifier", "profile-edit-view", 0, 30)) is not missing value then
                set profileWin to win
                exit repeat
            end if
        end repeat
        if profileWin is missing value then return "ERROR: profile sheet not found"

        if fullnameArg is not "__none__" then my fillField(profileWin, "profile-fullname-field", fullnameArg)
        if nicknameArg is not "__none__" then my fillField(profileWin, "profile-nickname-field", nicknameArg)
        if emailArg is not "__none__" then my fillField(profileWin, "profile-email-field-0", emailArg)

        if saveArg is "yes" then
            set saveBtn to my findByAttr(profileWin, "AXIdentifier", "profile-save-button", 0, 30)
            if saveBtn is missing value then return "ERROR: profile-save-button not found"
            click saveBtn
        end if
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Profile updated"
else
    echo "$RESULT" >&2
    exit 1
fi
