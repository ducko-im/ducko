#!/bin/bash
# Reveal the contact-list search field (⌘F) and optionally type a query to
# filter the roster. The field is hidden until revealed.
#
# Walks the contact window via findByAttr rather than `entire contents`, which
# collapses on the NSTableView-backed contact list on macOS 26.
# Usage: ducko-contact-search.sh [QUERY]
#   No args:  toggles the search field open/closed
#   QUERY:    reveals the field, types QUERY, and prints the number of matching contact rows and their identifiers
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
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin" 0.2)

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
                $(ducko_as_await_element '"contact-search-field"' contactWin window 3 'contact-search-field not found' searchField)
            end if

            $(ducko_as_fill_element "searchField" "query")
            $(ducko_as_await_field_value "searchField" "query")
            delay 0.5

            $(ducko_as_find_element_by_id '"contact-list"' 'contactWin' 'contact-list not found' 'contactList')
            set rowIds to my collectIdentifiers(contactList, "contact-row-", 0, 30)
            set report to "Matches: " & (count of rowIds) & linefeed
            repeat with rowId in rowIds
                set report to report & rowId & linefeed
            end repeat
            return "REPORT:" & report
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)  echo "Contact search toggled" ;;
    REPORT:*) printf '%s\n' "${RESULT#REPORT:}" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
