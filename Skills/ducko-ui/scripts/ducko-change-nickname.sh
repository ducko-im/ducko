#!/bin/bash
# Change MUC nickname via the participant sidebar context menu.
# Right-clicks participant rows to find the one exposing "Change Nickname…"
# (your own row), then fills the new nickname in the alert dialog. Succeeds once your
# row in the participant sidebar carries the new nickname.
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
            -- The context menu and the Escape that dismisses a wrong one act on the key window.
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")

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
                    set selfRowId to missing value
                    try
                        set selfRowId to value of attribute "AXIdentifier" of r
                    end try
                    click menuItem
                    set foundMenu to true
                    exit repeat
                end if
                key code 53
                delay 0.2
            end repeat
            if not foundMenu then return "ERROR: Change Nickname menu item not found (are you in this room?)"
            set newRowId to "participant-row-" & newNick
            if selfRowId is newRowId then return "ERROR: the nickname is already " & newNick

            -- The alert is a sheet of the chat window. Neither the identifier of its field, which does not reach
            -- accessibility, nor focus, which on macOS 27 starts on Cancel, locates the field, so find it as the
            -- only text field of the sheet.
            set nickField to missing value
            set deadline to (current date) + 5
            repeat until nickField is not missing value or (current date) > deadline
                repeat with s in sheets of chatWin
                    set sheetFields to my collectByRole(s, "AXTextField", 0, 10)
                    if (count of sheetFields) is 1 then
                        set alertSheet to contents of s
                        set nickField to item 1 of sheetFields
                        exit repeat
                    end if
                end repeat
                if nickField is missing value then delay 0.3
            end repeat
            if nickField is missing value then return "ERROR: Change Nickname alert not found"
            $(ducko_as_fill_element "nickField" "newNick")
            $(ducko_as_click_button_by_label "Change" "alertSheet")

            -- Your row takes the new nickname once the room confirms the change. Another occupant already holding
            -- that nickname makes the room refuse it, so your old row has to be gone as well.
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                if (my findByAttr(sidebarElem, "AXIdentifier", newRowId, 0, 30)) is not missing value then
                    if selfRowId is missing value or (my findByAttr(sidebarElem, "AXIdentifier", selfRowId, 0, 30)) is missing value then return "ok"
                end if
            end repeat
            return "ERROR: your row in the sidebar did not change to " & newNick
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Nickname changed to $NICKNAME"
