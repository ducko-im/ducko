#!/bin/bash
# Open the View Options menu in the contact list toolbar.
# Optionally select a sort mode or toggle Hide Offline.
# Usage: ducko-sort.sh [alphabetical|byStatus|recentConversation|hideOffline]
#   No args:         opens the menu (for visual verification)
#   alphabetical:    select "Alphabetical" sort
#   byStatus:        select "By Status" sort
#   recentConversation: select "Recent Conversation" sort
#   hideOffline:     toggle "Hide Offline"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACTION="${1:-__none__}"

RESULT=$(osascript - "$ACTION" << 'APPLESCRIPT'
on run argv
    set sortAction to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            -- Map sortAction to its View-menu label.
            set targetLabel to ""
            if sortAction is not "__none__" then
                if sortAction is "alphabetical" then
                    set targetLabel to "Alphabetical"
                else if sortAction is "byStatus" then
                    set targetLabel to "By Status"
                else if sortAction is "recentConversation" then
                    set targetLabel to "Recent Conversation"
                else if sortAction is "hideOffline" then
                    set targetLabel to "Hide Offline Contacts"
                else
                    return "ERROR: unknown sortAction: " & sortAction
                end if
            end if

            -- Sort order + Hide Offline are in the View menu (a "Sort Contacts"
            -- picker plus a "Hide Offline Contacts" toggle).
            try
                click menu bar item "View" of menu bar 1
            on error
                return "ERROR: View menu not found"
            end try
            delay 0.3
            if sortAction is "__none__" then return "menu-opened"

            set viewMenu to menu 1 of menu bar item "View" of menu bar 1
            -- Direct item (Hide Offline Contacts, or an inline sort option).
            try
                click (first menu item of viewMenu whose name is targetLabel)
                return "ok"
            end try
            -- Sort options may render under a "Sort Contacts" submenu.
            try
                set sortSub to menu 1 of (first menu item of viewMenu whose name is "Sort Contacts")
                click (first menu item of sortSub whose name is targetLabel)
                return "ok"
            end try
            return "ERROR: menu item " & targetLabel & " not found"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    menu-opened) echo "View Options menu opened" ;;
    ok)          echo "Applied: ${ACTION}" ;;
    *)           echo "$RESULT" >&2; exit 1 ;;
esac
