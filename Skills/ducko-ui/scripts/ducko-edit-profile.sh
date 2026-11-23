#!/bin/bash
# Edit profile fields and optionally save.
# Opens the profile sheet first if not already open, and waits for it to load. An empty value clears its field.
# With --save, succeeds once the sheet has closed, and fails with the sheet's error when it shows one.
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

"$SCRIPTS/ducko-profile.sh" > /dev/null

RESULT=$(osascript - "$FULLNAME" "$NICKNAME" "$EMAIL" "$SAVE" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set fullnameArg to item 1 of argv
    set nicknameArg to item 2 of argv
    set emailArg to item 3 of argv
    set saveArg to item 4 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_find_scene_window "contacts" "contactWin")
            if contactWin is missing value then return "ERROR: Contacts window not found"
            $(ducko_as_require_front_window "contactWin" "the contacts window")
            -- The sheet shows its fields once the profile has loaded.
            $(ducko_as_await_element '"profile-fullname-field"' contactWin sheets 10 'the profile did not load' loadedField)

            if fullnameArg is not "__none__" then
                $(ducko_as_fill_field_by_id '"profile-fullname-field"' 'contactWin' 'fullnameArg' 'profile-fullname-field not found')
            end if
            if nicknameArg is not "__none__" then
                $(ducko_as_fill_field_by_id '"profile-nickname-field"' 'contactWin' 'nicknameArg' 'profile-nickname-field not found')
            end if
            if emailArg is not "__none__" then
                $(ducko_as_fill_field_by_id '"profile-email-field-0"' 'contactWin' 'emailArg' 'profile-email-field-0 not found')
            end if

            if saveArg is "yes" then
                $(ducko_as_click_element_by_id '"profile-save-button"' 'contactWin' 'profile-save-button not found')
                $(ducko_as_await_sheet_closed contactWin contacts '"profile-edit-view"' '"profile-error"' 15 "Profile sheet stayed open")
            end if
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Profile updated"
