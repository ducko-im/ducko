#!/bin/bash
# Open the Connection Info sheet from Preferences > Accounts tab.
# Uses script composition to ensure the Accounts tab is active first.
#
# Best-effort: selecting the account row drives a SwiftUI `List(selection:)`,
# which synthetic clicks cannot reliably trigger. The Actions pull-down holding
# "Connection Info…" only appears once the account is connected. It is located
# via findByAttr rather than `entire contents`, which collapses on macOS 26.
# Usage: ducko-connection-info.sh [open|close]
# Closing targets DUCKO_PID when set, else the single running DuckoUITest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

case "${1:-open}" in
    open) ;;
    close)
        APP_PID=$(ducko_app_pid)
        exec swift "$SCRIPT_DIR/ducko-dismiss.swift" "$APP_PID" "connection-info-view" "Done" ;;
    *) echo "Usage: ducko-connection-info.sh [open|close]" >&2; exit 1 ;;
esac

# Ensure Preferences window is open on the Accounts tab
"$SCRIPT_DIR/ducko-preferences.sh" > /dev/null 2>&1 || true
"$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1 || true

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
$(ducko_as_click_account_action "Connection Info…" "Connection Info… menu item not found (does the account have TLS info?)")
        delay 0.5
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Connection Info sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
