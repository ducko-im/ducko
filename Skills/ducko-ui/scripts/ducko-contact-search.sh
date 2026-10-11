#!/bin/bash
# Reveal the contact-list search field (⌘F) and optionally type a query to
# filter the roster. The field is hidden until revealed.
#
# Walks the contact window via findByAttr rather than `entire contents`, which
# collapses on the NSTableView-backed contact list on macOS 26.
# Usage: ducko-contact-search.sh [QUERY]
#   No args:  toggles the search field open/closed
#   QUERY:    reveals the field and types QUERY to filter the roster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

QUERY="${1:-}"

RESULT=$(osascript - "$QUERY" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin" 0.2)

            if query is "" then
                -- Toggle: ⌘F reveals or hides the field.
                keystroke "f" using command down
                delay 0.3
                return "toggled"
            end if

            -- Reveal the field if it is not already shown.
            set searchField to my findByAttr(contactWin, "AXIdentifier", "contact-search-field", 0, 30)
            if searchField is missing value then
                keystroke "f" using command down
                delay 0.5
                set searchField to my findByAttr(contactWin, "AXIdentifier", "contact-search-field", 0, 30)
            end if
            if searchField is missing value then return "ERROR: contact-search-field not found"

            set focused of searchField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke query
            delay 0.3
            return "searched"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)  echo "Contact search toggled" ;;
    searched) echo "Filtered contacts: $QUERY" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
