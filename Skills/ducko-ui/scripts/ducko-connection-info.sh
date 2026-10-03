#!/bin/bash
# Open the Connection Info sheet from Preferences > Accounts tab.
# Uses script composition to ensure the Accounts tab is active first.
#
# Best-effort: selecting the account row drives a SwiftUI `List(selection:)`,
# which synthetic clicks cannot reliably trigger. The Actions pull-down holding
# "Connection Info…" only appears once the account is connected. It is located
# via findByAttr rather than `entire contents`, which collapses on macOS 26.
# Usage: ducko-connection-info.sh [open|close]
# Closing requires DUCKO_PID to target the intended instance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
case "${1:-open}" in
    open) ;;
    close)
        if [[ ! "${DUCKO_PID:-}" =~ ^[0-9]+$ ]]; then
            echo "Set DUCKO_PID to the intended Ducko instance's PID." >&2
            exit 1
        fi
        exec swift "$SCRIPT_DIR/ducko-dismiss.swift" "$DUCKO_PID" "connection-info-view" "Done" ;;
    *) echo "Usage: ducko-connection-info.sh [open|close]" >&2; exit 1 ;;
esac

# Ensure Preferences window is open on the Accounts tab
"$SCRIPT_DIR/ducko-preferences.sh" > /dev/null 2>&1 || true
"$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1 || true

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on findAccountRow(el, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    set v to value of c
                    if v is not missing value and v contains "@" then return c
                end try
                set found to my findAccountRow(c, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findAccountRow

on run
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        -- Select the first account so the detail pane (with the Actions pull-down) renders.
        set prefsWin to missing value
        repeat with win in (windows of process "DuckoApp")
            set acctRow to my findAccountRow(win, 0, 30)
            if acctRow is not missing value then
                set prefsWin to contents of win
                try
                    click acctRow
                end try
                exit repeat
            end if
        end repeat
        if prefsWin is missing value then return "ERROR: account row not found"
        delay 0.4

        -- A SwiftUI Menu bridges as a menu/pop-up button, not AXButton, so match by identifier alone.
        set actionsMenu to my findByAttr(prefsWin, "AXIdentifier", "account-actions-menu", 0, 30)
        if actionsMenu is missing value then return "ERROR: Actions menu not found (is an account row selected and connected?)"
        tell process "DuckoApp"
$(ducko_as_click_context_menu_item "Connection Info…" 'actionsMenu' 'prefsWin' "Connection Info… menu item not found (does the account have TLS info?)" continue)
        end tell
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
