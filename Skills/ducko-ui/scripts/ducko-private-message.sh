#!/bin/bash
# Send a MUC private message via the participant sidebar context menu.
# Right-clicks the target nickname's participant row and selects
# "Send Private Message", opening a new chat window for the occupant.
# Usage: ducko-private-message.sh NICKNAME
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

NICKNAME="${1:?Usage: ducko-private-message.sh NICKNAME}"

RESULT=$(osascript - "$NICKNAME" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set targetNick to item 1 of argv
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

            -- Find the participant row holding targetNick and open its context menu.
            set foundMenu to false
            repeat with r in (my collectByRole(sidebarElem, "AXGroup", 0, 30))
                set isMatch to false
                repeat with t in (my collectStaticTexts(r, 0, 6))
                    try
                        if (value of t) is targetNick then set isMatch to true
                    end try
                end repeat
                if isMatch then
                    perform action "AXShowMenu" of r
                    delay 0.4
                    set menuItem to missing value
                    repeat with m in menus
                        set menuItem to my findByAttr(m, "AXIdentifier", "send-pm-menu-item", 0, 8)
                        if menuItem is not missing value then exit repeat
                    end repeat
                    if menuItem is missing value then set menuItem to my findByAttr(chatWin, "AXIdentifier", "send-pm-menu-item", 0, 30)
                    if menuItem is not missing value then
                        click menuItem
                        set foundMenu to true
                        exit repeat
                    end if
                    key code 53
                    delay 0.2
                end if
            end repeat
            if not foundMenu then return "ERROR: Send Private Message menu item not found for " & targetNick

            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Opened PM window for $NICKNAME"
