#!/bin/bash
# Set presence status and optional status message.
# Usage: ducko-status.sh STATUS [MESSAGE]
#   STATUS: available|away|xa|dnd|offline
#   MESSAGE: optional status message text
#
# MESSAGE is typed into the Custom Status sheet with keystrokes, which go to
# the frontmost app, so the instance has to stay frontmost while it runs.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-status.sh STATUS [MESSAGE]" >&2
    exit 1
fi

STATUS="$1"
MESSAGE="${2:-__none__}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$STATUS" "$MESSAGE" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set statusArg to item 1 of argv
    set messageArg to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            $(ducko_as_raise_window_by_id "contact-list" "Contacts window not found" "contactWin")

            -- Map status arg to display name
            set targetLabel to ""
            if statusArg is "available" then
                set targetLabel to "Available"
            else if statusArg is "away" then
                set targetLabel to "Away"
            else if statusArg is "xa" then
                set targetLabel to "Extended Away"
            else if statusArg is "dnd" then
                set targetLabel to "Do Not Disturb"
            else if statusArg is "offline" then
                set targetLabel to "Offline"
            else
                return "ERROR: unknown status: " & statusArg
            end if

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
                delay 0.5

                $(ducko_as_find_element_by_id '"custom-status-message-field"' 'contactWin' 'custom-status-message-field not found' 'msgField')
                set focused of msgField to true
                delay 0.2
                keystroke "a" using command down
                delay 0.1
                keystroke messageArg
                delay 0.2
                -- Set button carries .defaultAction.
                keystroke return
                delay 0.3
            end if

            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    if [[ "$MESSAGE" != "__none__" ]]; then
        echo "Status set to ${STATUS} with message"
    else
        echo "Status set to ${STATUS}"
    fi
else
    echo "$RESULT" >&2
    exit 1
fi
