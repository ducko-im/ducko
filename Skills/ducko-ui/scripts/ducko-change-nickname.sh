#!/bin/bash
# Change MUC nickname via the participant sidebar context menu.
# Right-clicks participant rows to find the one exposing "Change Nickname…"
# (your own row), then fills the new nickname in the alert dialog.
# Usage: ducko-change-nickname.sh NICKNAME
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

NICKNAME="${1:?Usage: ducko-change-nickname.sh NICKNAME}"

RESULT=$(osascript - "$NICKNAME" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set newNick to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")

            -- Reveal the participant sidebar if it is not already shown.
            set sidebarElem to my findByAttr(chatWin, "AXIdentifier", "participant-sidebar", 0, 30)
            if sidebarElem is missing value then
                set toggleBtn to my findByAttr(chatWin, "AXIdentifier", "toggle-participant-sidebar", 0, 30)
                if toggleBtn is not missing value then
                    click toggleBtn
                    delay 0.5
                    set sidebarElem to my findByAttr(chatWin, "AXIdentifier", "participant-sidebar", 0, 30)
                end if
            end if
            if sidebarElem is missing value then return "ERROR: participant sidebar not found"

            -- "Change Nickname…" only appears on your own row, so probe each row
            -- context menu until it shows up, dismissing the others.
            set foundMenu to false
            repeat with r in (my collectByRole(sidebarElem, "AXGroup", 0, 30))
                perform action "AXShowMenu" of r
                delay 0.4
                set menuItem to missing value
                repeat with m in menus
                    set menuItem to my findByAttr(m, "AXIdentifier", "change-nickname-menu-item", 0, 8)
                    if menuItem is not missing value then exit repeat
                end repeat
                if menuItem is missing value then set menuItem to my findByAttr(chatWin, "AXIdentifier", "change-nickname-menu-item", 0, 30)
                if menuItem is not missing value then
                    click menuItem
                    set foundMenu to true
                    exit repeat
                end if
                key code 53
                delay 0.2
            end repeat
            if not foundMenu then return "ERROR: Change Nickname menu item not found (are you in this room?)"
            delay 0.5

            -- Fill the nickname field in the alert dialog.
            set nickField to my findByAttr(chatWin, "AXIdentifier", "change-nickname-field", 0, 30)
            if nickField is missing value then return "ERROR: change-nickname-field not found"
            set focused of nickField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke newNick
            delay 0.3

            -- Click the Change button.
            set changeBtn to my findByRoleAndName(chatWin, "AXButton", "Change", 0, 30)
            if changeBtn is missing value then return "ERROR: Change button not found"
            click changeBtn
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Nickname changed to $NICKNAME"
