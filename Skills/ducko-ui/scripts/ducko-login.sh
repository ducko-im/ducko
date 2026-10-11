#!/bin/bash
# Fill JID and password on the account setup screen, then click Connect.
# Uses accessibility identifiers for reliable element targeting.
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the Welcome window's deeply-nested
# SwiftUI hierarchy on macOS 26. The success message is gated on the osascript
# result, so a missing field reports an error instead of false success.
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
        if not (exists window "Welcome" of proc) then return "ERROR: Welcome window not found"
        set win to window "Welcome" of proc

        set jidField to my findByAttr(win, "AXIdentifier", "jid-field", 0, 30)
        if jidField is missing value then return "ERROR: jid-field not found"
        set focused of jidField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke jid

        set pwField to my findByAttr(win, "AXIdentifier", "password-field", 0, 30)
        if pwField is missing value then return "ERROR: password-field not found"
        set focused of pwField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke pw

        set connectBtn to my findByAttr(win, "AXIdentifier", "connect-button", 0, 30)
        if connectBtn is missing value then return "ERROR: connect-button not found"
        click connectBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Login initiated for $JID"
else
    echo "$RESULT" >&2
    exit 1
fi
