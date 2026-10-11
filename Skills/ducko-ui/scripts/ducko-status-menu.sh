#!/bin/bash
# Set presence from the Status menu bar menu. Unlike the borderless status
# pull-down in the Contacts header (ducko-status.sh), menu-bar items are
# reliably scriptable.
# Usage: ducko-status-menu.sh <available|away|xa|dnd|offline|toggle|custom>
#   available..offline: pick that status (clears any status message)
#   toggle:             the ⌘Y item — "Custom Away…" when Available (opens the
#                       Custom Status sheet on Contacts), "Available" otherwise
#   custom:             "Custom…", opening the Custom Status sheet on Contacts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-status-menu.sh <available|away|xa|dnd|offline|toggle|custom>" >&2
    exit 1
fi

case "$1" in
    available) LABEL="Available" ;;
    away)      LABEL="Away" ;;
    xa)        LABEL="Extended Away" ;;
    dnd)       LABEL="Do Not Disturb" ;;
    offline)   LABEL="Offline" ;;
    toggle|custom) LABEL="" ;;
    *) echo "Usage: ducko-status-menu.sh <available|away|xa|dnd|offline|toggle|custom>" >&2; exit 1 ;;
esac

RESULT=$(osascript - "$1" "$LABEL" << 'APPLESCRIPT'
on run argv
    set statusAction to item 1 of argv
    set statusLabel to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            try
                set statusMenu to menu 1 of menu bar item "Status" of menu bar 1
            on error
                return "ERROR: Status menu not found"
            end try
            try
                if statusAction is "custom" then
                    click menu item "Custom…" of statusMenu
                else if statusAction is "toggle" then
                    -- The toggle follows the status rows, so it is the last "Available" when not titled "Custom Away…".
                    if exists menu item "Custom Away…" of statusMenu then
                        click menu item "Custom Away…" of statusMenu
                    else
                        click (last menu item of statusMenu whose name is "Available")
                    end if
                else
                    -- Status rows come first, so the first match is the row rather than the toggle. Match by prefix
                    -- because a marked row carries a trailing checkmark or dash in its title.
                    click (first menu item of statusMenu whose name starts with statusLabel)
                end if
            on error
                return "ERROR: Status menu item for " & statusAction & " not found or disabled"
            end try
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok) echo "Status menu: $1" ;;
    *)  echo "$RESULT" >&2; exit 1 ;;
esac
