#!/bin/bash
# Fill JID and password on the account setup screen, then click Connect.
# Uses accessibility identifiers for reliable element targeting.
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the Welcome window's deeply-nested
# SwiftUI hierarchy on macOS 26. Succeeds once the Welcome window has closed, since the account is then signed in,
# and fails with the error the window shows.
# Usage: ducko-login.sh JID PASSWORD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

JID="${1:?Usage: ducko-login.sh JID PASSWORD}"
PASSWORD="${2:?Usage: ducko-login.sh JID PASSWORD}"

RESULT=$(osascript - "$JID" "$PASSWORD" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set jid to item 1 of argv
    set pw to item 2 of argv
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 1
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")
            $(ducko_as_fill_field_by_id '"jid-field"' 'win' 'jid' 'jid-field not found')
            $(ducko_as_fill_field_by_id '"password-field"' 'win' 'pw' 'password-field not found')
            $(ducko_as_click_element_by_id '"connect-button"' 'win' 'connect-button not found')
$(ducko_as_await_welcome_outcome proc win "" "the sign-in did not finish")
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Signed in as $JID"
