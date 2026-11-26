#!/bin/bash
# Press a sign-in-through-the-browser control and report whether the web authentication prompt appeared. The provider's
# login itself is not scripted.
# Usage: ducko-browser-sign-in.sh <login|add|detail|switch|later|start> [JID]
#   login JID:   Sign In with Browser… on the Welcome window's Login tab (select it first with
#                ducko-select-mode.sh Login), after entering JID
#   add JID:     Sign In with Browser… in Preferences > Accounts > Add Account, after entering JID
#   detail [JID]: Sign In with Browser… in the account details of a browser account (default: the first account)
#   switch [JID]: Switch to Browser Sign-In… in the account's Edit sheet, then its confirmation
#   later:       Later in the Contacts window's Sign In Again alert. Succeeds once Contacts shows no dialog
#   start:       Sign In with Browser… in that alert
# A control that starts a sign-in succeeds once the web authentication session's "Wants to Use … to Sign In" alert
# appears, and leaves that alert open. Answer it with `vm ax press UserNotificationCenter Cancel`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACTION="${1:-}"
JID="${2:-}"
case "$ACTION" in
    login|add)
        [[ -n "$JID" ]] || { echo "Usage: ducko-browser-sign-in.sh $ACTION JID" >&2; exit 1; } ;;
    detail|switch|later|start) ;;
    *) echo "Usage: ducko-browser-sign-in.sh <login|add|detail|switch|later|start> [JID]" >&2; exit 1 ;;
esac

case "$ACTION" in
    add)
        "$SCRIPT_DIR/ducko-preferences.sh" > /dev/null
        "$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null
        sleep 0.5 ;;
    detail)
        "$SCRIPT_DIR/ducko-preferences.sh" > /dev/null
        "$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null
        sleep 0.5 ;;
    switch)
        "$SCRIPT_DIR/ducko-edit-account.sh" "$JID" > /dev/null ;;
esac

# The web authentication session asks first whether the app may use the provider's site to sign in. That alert is
# UserNotificationCenter's, not the app's, so it is found by its Continue button. The server probe and client
# registration before it take a few seconds.
AWAIT_PROMPT_HANDLER='
on awaitPrompt()
    tell application "System Events"
        set deadline to (current date) + 20
        repeat
            if exists process "UserNotificationCenter" then
                repeat with alertWin in (windows of process "UserNotificationCenter")
                    if exists (button "Continue" of alertWin) then return "ok"
                end repeat
            end if
            if (current date) > deadline then return "ERROR: no web authentication prompt appeared"
            delay 0.3
        end repeat
    end tell
end awaitPrompt
'

if [[ "$ACTION" != "detail" && "$ACTION" != "switch" ]]; then
RESULT=$(osascript - "$ACTION" "$JID" << APPLESCRIPT
$(ducko_as_handlers)
$AWAIT_PROMPT_HANDLER

on run argv
    set signInAction to item 1 of argv
    set jid to item 2 of argv
    tell application "System Events"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 0.3
        tell process "DuckoUITest"
            if signInAction is "login" then
                $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")
                $(ducko_as_fill_field_by_id '"jid-field"' 'win' 'jid' 'jid-field not found')
                $(ducko_as_click_element_by_id '"sso-sign-in-button"' 'win' 'Sign In with Browser… not found')
                return my awaitPrompt()
            else if signInAction is "add" then
                -- The Preferences window is titled after its open tab, which ducko-preferences-tab.sh set to Accounts.
                if not (exists window "Accounts") then return "ERROR: Preferences > Accounts not found"
                set prefsWin to window "Accounts"
                $(ducko_as_click_element_by_id '"account-add-button"' 'prefsWin' 'Add Account button not found')
                delay 0.5
                set addSheet to sheet 1 of prefsWin
                -- The address field is the first text field of the sheet, nested in its form.
                set jidField to my findByAttr(addSheet, "AXRole", "AXTextField", 0, 30)
                if jidField is missing value then return "ERROR: the Add Account sheet has no address field"
                $(ducko_as_fill_element "jidField" "jid")
                $(ducko_as_click_element_by_id '"sso-sign-in-button"' 'addSheet' 'Sign In with Browser… not found')
                return my awaitPrompt()
            else if signInAction is "later" or signInAction is "start" then
                $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
                if signInAction is "later" then
                    $(ducko_as_click_button_by_label "Later" 'contactWin' 'Sign In Again alert not found')
                    set deadline to (current date) + 5
                    repeat while (count of sheets of contactWin) > 0
                        if (current date) > deadline then return "ERROR: the Contacts window still shows a dialog"
                        delay 0.2
                    end repeat
                    return "ok"
                end if
                $(ducko_as_click_button_by_label "Sign In with Browser…" 'contactWin' 'Sign In Again alert not found')
                return my awaitPrompt()
            end if
        end tell
    end tell
end run
APPLESCRIPT
)
else
RESULT=$(osascript - "$ACTION" "$JID" << APPLESCRIPT
$(ducko_as_handlers)
$AWAIT_PROMPT_HANDLER
on run argv
    set signInAction to item 1 of argv
    set accountJid to item 2 of argv
    tell application "System Events"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 0.3
        if signInAction is "detail" then
$(ducko_as_select_account_row accountJid)
        end if
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "$DUCKO_SETTINGS_SCENE" "Preferences window not found" "prefsWin")
            if signInAction is "detail" then
                $(ducko_as_click_element_by_id '"sso-detail-sign-in-button"' 'prefsWin' 'Sign In with Browser… not found; is it a browser account?')
            else
                $(ducko_as_click_element_by_id '"sso-switch-button"' 'prefsWin' 'Switch to Browser Sign-In… not found; is it a password account?')
                $(ducko_as_click_button_by_label "Switch to Browser Sign-In" 'prefsWin' 'switch confirmation not found')
            end if
        end tell
        return my awaitPrompt()
    end tell
end run
APPLESCRIPT
)
fi

case "$ACTION" in
    later) ducko_check_result "$RESULT" "Dismissed the Sign In Again alert" ;;
    *)     ducko_check_result "$RESULT" "The web authentication prompt appeared" ;;
esac
