#!/bin/bash
# Open the Blocked Contacts sheet from Preferences > Accounts, or act on the open sheet.
# Usage: ducko-blocked-contacts.sh <open|list|add|remove> [JID]
#   open:        open the sheet from the first account's Actions pull-down and wait for its list to load
#   list:        print the addresses the sheet lists, one per line
#   add JID:     block JID (a full JID blocks one device of the contact) and wait for its row
#   remove JID:  press the row's Unblock button and wait for the row to go
#
# `open` needs the account connected, since the Actions pull-down appears only then. The other actions need
# the sheet already open.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

USAGE="Usage: ducko-blocked-contacts.sh <open|list|add|remove> [JID]"
ACTION="${1:-}"
JID="${2:-}"

case "$ACTION" in
    open|list)
        if [[ -n "$JID" ]]; then echo "$USAGE" >&2; exit 1; fi ;;
    add|remove)
        if [[ -z "$JID" ]]; then echo "Usage: ducko-blocked-contacts.sh $ACTION JID" >&2; exit 1; fi ;;
    *)
        echo "$USAGE" >&2; exit 1 ;;
esac

if [[ "$ACTION" == open ]]; then
    "$SCRIPT_DIR/ducko-preferences.sh" > /dev/null
    "$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null
fi

RESULT=$(osascript - "$ACTION" "$JID" << APPLESCRIPT
$(ducko_as_handlers)
on blockedContactsWindow()
    tell application "System Events"
        repeat with win in (windows of process "DuckoUITest")
            if (my findInSheets(win, "blocked-contacts-view")) is not missing value then return contents of win
        end repeat
    end tell
    return missing value
end blockedContactsWindow

on run argv
    set blockAction to item 1 of argv
    set blockJID to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        if blockAction is "open" then
$(ducko_as_click_account_action "Blocked Contacts…")
$(ducko_as_await_element '"blocked-contacts-content"' prefsWin sheets 10 'the Blocked Contacts sheet did not finish loading' blockedContent)
            return "ok"
        end if

        set prefsWin to my blockedContactsWindow()
        if prefsWin is missing value then return "ERROR: Blocked Contacts sheet not open (run ducko-blocked-contacts.sh open first)"

        if blockAction is "list" then
            set entryList to ""
            repeat with entryId in (my collectIdentifiers(prefsWin, "blocked-contact-", 0, 30))
                set entryList to entryList & (my idSuffix("blocked-contact-", entryId)) & linefeed
            end repeat
            return "LIST:" & entryList
        end if

        set rowId to "blocked-contact-" & blockJID
        tell process "DuckoUITest"
            if blockAction is "add" then
$(ducko_as_raise_scene_window "$DUCKO_SETTINGS_SCENE" "Preferences window not found" "prefsWin")
$(ducko_as_fill_field_by_id '"block-address-field"' 'prefsWin' 'blockJID' 'block-address-field not found')
$(ducko_as_click_element_by_id '"block-address-button"' 'prefsWin' 'block-address-button not found')
            else
$(ducko_as_click_element_by_id '"unblock-button-" & blockJID' 'prefsWin' 'no Unblock button for that address')
            end if
        end tell

        set deadline to (current date) + 10
        repeat until (current date) > deadline
            delay 0.5
            set rowShown to (my findInSheets(prefsWin, rowId)) is not missing value
            if rowShown is (blockAction is "add") then return "ok"
        end repeat
        set errorText to my findInSheets(prefsWin, "blocked-contacts-error")
        if errorText is not missing value then return "ERROR: " & (value of errorText)
        if blockAction is "add" then return "ERROR: no row for the address appeared"
        return "ERROR: the row for the address stayed"
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    LIST:*) ENTRIES="${RESULT#LIST:}"; [[ -z "$ENTRIES" ]] || printf '%s\n' "$ENTRIES" ;;
    ok)     echo "Blocked Contacts action '$ACTION' ${JID:+for $JID }succeeded" ;;
    *)      echo "$RESULT" >&2; exit 1 ;;
esac
