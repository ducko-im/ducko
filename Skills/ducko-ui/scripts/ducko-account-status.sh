#!/bin/bash
# Set one account's presence from its submenu in the menu-bar extra, leaving
# the other accounts alone. The submenus appear with 2+ enabled accounts and
# need "Show Ducko in Menu Bar" on (the default).
# Usage: ducko-account-status.sh ACCOUNT <available|away|xa|dnd|offline>
#   ACCOUNT: the account's exact label in the menu (its display name, else its JID)
#   offline disconnects just that account; any other status connects it if needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

usage() {
    echo "Usage: ducko-account-status.sh ACCOUNT <available|away|xa|dnd|offline>" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage

case "$2" in
    available) LABEL="Available" ;;
    away)      LABEL="Away" ;;
    xa)        LABEL="Extended Away" ;;
    dnd)       LABEL="Do Not Disturb" ;;
    offline)   LABEL="Offline" ;;
    *) usage ;;
esac

RESULT=$(osascript - "$1" "$LABEL" << 'APPLESCRIPT'
on run argv
    set accountLabel to item 1 of argv
    set statusLabel to item 2 of argv
    tell application "System Events"
        tell process "DuckoUITest"
            try
                set extraItem to menu bar item 1 of menu bar 2
                click extraItem
                delay 0.3
                set extraMenu to menu 1 of extraItem
            on error
                return "ERROR: Menu-bar extra not found (is Show Ducko in Menu Bar on?)"
            end try
            try
                set accountItem to (first menu item of extraMenu whose name is accountLabel)
                click accountItem
                delay 0.2
            on error
                key code 53
                return "ERROR: Account submenu for " & accountLabel & " not found (needs 2+ enabled accounts)"
            end try
            try
                -- Match by prefix because the active row carries a trailing checkmark in its title.
                click (first menu item of menu 1 of accountItem whose name starts with statusLabel)
            on error
                key code 53
                return "ERROR: Status " & statusLabel & " not found in the submenu for " & accountLabel
            end try
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok) echo "Account status: $1 -> $2" ;;
    *)  echo "$RESULT" >&2; exit 1 ;;
esac
