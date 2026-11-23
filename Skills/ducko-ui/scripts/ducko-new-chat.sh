#!/bin/bash
# Open the New Chat sheet (File menu, ⌘N), fill in a JID, optionally pick the
# sending account, and start the chat. The sheet and the chat open in the chat window.
# Succeeds once the sheet has closed and the chat window has a tab for the JID, and fails with the sheet's error when
# it shows one.
# Usage: ducko-new-chat.sh JID [ACCOUNT]
#   JID:     the peer JID to start a chat with
#   ACCOUNT: optional account label to select in the account picker — shown only
#            when more than one account is enabled; matches the picker row text
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

JID="${1:?Usage: ducko-new-chat.sh JID [ACCOUNT]}"
ACCOUNT="${2:-}"

RESULT=$(osascript - "$JID" "$ACCOUNT" << APPLESCRIPT
$(ducko_as_handlers)

on run argv
    set jid to item 1 of argv
    set acct to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            keystroke "n" using command down
            $(ducko_as_await_scene_window "chat" 5 "chat window not found" "chatWin")
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            -- The window can be open already, before its sheet is.
            $(ducko_as_await_element '"new-chat-jid-field"' chatWin sheets 5 'new-chat-jid-field not found' jidField '"chat"')
            $(ducko_as_fill_element "jidField" "jid")
            -- Optionally select the sending account. The picker is present only
            -- when more than one account is enabled; with a single account the
            -- chat opens under it and no ACCOUNT argument is needed.
            if acct is not "" then
                $(ducko_as_find_element_by_id '"new-chat-account-picker"' 'chatWin' 'new-chat-account-picker not found' 'picker')
                click picker
                delay 0.3
                try
                    click (first menu item of menu 1 of picker whose name contains acct)
                on error
                    return "ERROR: account not in picker: " & acct
                end try
                delay 0.2
            end if
            -- Start Chat has .defaultAction keyboard shortcut
            keystroke return
            $(ducko_as_await_sheet_closed chatWin chat '"new-chat-jid-field"' '"new-chat-error"' 15 "the New Chat sheet stayed open")
            -- The window title follows the selected tab, which can change again once its conversation has loaded, so
            -- find the window again on each pass.
            set deadline to (current date) + 5
            repeat
$(ducko_as_find_scene_window "chat" "chatWin")
                set tabBar to missing value
                if chatWin is not missing value then set tabBar to my findByAttr(chatWin, "AXIdentifier", "chat-tab-bar", 0, 30)
                if tabBar is not missing value then
                    if (my findChatTab(tabBar, jid)) is not missing value then return "ok"
                end if
                if (current date) > deadline then return "ERROR: no chat tab for " & jid & " appeared"
                delay 0.5
            end repeat
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Chat started with $JID${ACCOUNT:+ on $ACCOUNT}"
