#!/bin/bash
# Set presence status and optional status message.
# Usage: ducko-status.sh STATUS [MESSAGE]
#   STATUS: available|away|xa|dnd|offline
#   MESSAGE: optional status message text
#
# MESSAGE is typed into the Custom Status sheet with keystrokes, which go to
# the frontmost app, so the instance has to stay frontmost while it runs.
# Succeeds once the header's status pull-down shows the message, trimmed as the app trims it, or the status when no
# message is left. Offline always shows Offline, since a disconnected account shows no message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-status.sh STATUS [MESSAGE]" >&2
    exit 1
fi

STATUS="$1"
MESSAGE="${2:-__none__}"

STATUS_LABEL=$(ducko_status_label "$STATUS")

EXPECTED="$STATUS_LABEL"
if [[ "$MESSAGE" != "__none__" && "$STATUS" != offline ]]; then
    TRIMMED=$(ducko_trim "$MESSAGE")
    [[ -z "$TRIMMED" ]] || EXPECTED="$TRIMMED"
fi

RESULT=$(osascript - "$STATUS_LABEL" "$MESSAGE" "$EXPECTED" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set targetLabel to item 1 of argv
    set messageArg to item 2 of argv
    set expectedLabel to item 3 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")

            -- Find and click the status picker menu
            $(ducko_as_find_element_by_id '"status-picker"' 'contactWin' 'status-picker not found' 'pickerBtn')
            click pickerBtn
            delay 0.3

            -- Find and click the target status menu item. The SwiftUI Menu
            -- opens under the button, and has also been seen as a
            -- process-level menu (a sibling of the windows), so search both.
            set openedMenus to {}
            try
                set openedMenus to menus of pickerBtn
            end try
            set openedMenus to openedMenus & menus
            set clicked to false
            -- Match by prefix because a marked row carries a trailing checkmark or dash in its title.
            repeat with m in openedMenus
                try
                    set matches to (menu items of m whose name starts with targetLabel)
                    if (count of matches) > 0 then
                        click (item 1 of matches)
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not clicked then return "ERROR: status menu item " & targetLabel & " not found"
            delay 0.3

            -- Set a custom status message via the Custom… sheet from the pull-down,
            -- which opens pre-set to the presence just selected above.
            if messageArg is not "__none__" then
                $(ducko_as_find_element_by_id '"status-picker"' 'contactWin' 'status-picker not found' 'pickerBtn')
                click pickerBtn
                delay 0.3

                set openedMenus to {}
                try
                    set openedMenus to menus of pickerBtn
                end try
                set openedMenus to openedMenus & menus
                set customClicked to false
                repeat with m in openedMenus
                    try
                        repeat with elem in (menu items of m)
                            if (name of elem) starts with "Custom" then
                                click elem
                                set customClicked to true
                                exit repeat
                            end if
                        end repeat
                    end try
                    if customClicked then exit repeat
                end repeat
                if not customClicked then return "ERROR: Custom… menu item not found"
                $(ducko_as_await_element '"custom-status-message-field"' contactWin sheets 5 'custom-status-message-field not found' messageField)
                $(ducko_as_fill_element "messageField" "messageArg")
                -- Set button carries .defaultAction.
                keystroke return
            end if

            -- The pull-down appends counts of the accounts showing another status after " · ", so a plain prefix
            -- match would take a stale longer message for the expected one.
            set deadline to (current date) + 10
            repeat
                delay 0.5
                $(ducko_as_find_scene_window "contacts" "contactWin")
                if contactWin is missing value then return "ERROR: Contacts window not found"
                set sheetOpen to (my findInSheets(contactWin, "custom-status-message-field")) is not missing value
                set shownLabel to ""
                set picker to my findByAttr(contactWin, "AXIdentifier", "status-picker", 0, 30)
                if picker is not missing value then
                    try
                        set shownLabel to value of picker
                    end try
                end if
                if shownLabel is missing value then set shownLabel to ""
                considering case
                    set labelShown to (shownLabel is expectedLabel or shownLabel starts with (expectedLabel & " · "))
                end considering
                if not sheetOpen and labelShown then return "ok"
                if (current date) > deadline then
                    if sheetOpen then return "ERROR: the Custom Status sheet stayed open"
                    return "ERROR: the status pull-down shows " & shownLabel & " instead of " & expectedLabel
                end if
            end repeat
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Status set to $EXPECTED"
