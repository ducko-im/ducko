#!/bin/bash
# Enumerate, select, cycle, or close the bottom conversation tabs in the chat window.
# Usage: ducko-chat-tabs.sh <list|select|close|next|previous|close-all> [JID]
#   list:        print the identity of all open tabs (one per line)
#   select JID:  click the tab for JID to make it active
#   close JID:   close the tab through its "Close Tab" accessibility action
#   next:        Window > Select Next Tab (⌃⇥), wrapping at the end
#   previous:    Window > Select Previous Tab (⌃⇧⇥), wrapping at the start
#   close-all:   File > Close All Chats (⌥⌘W), closing every tab and the chat window
#
# Tab identity is the bare JID when unique. When the same peer JID is open under
# more than one account, each tab is account-qualified as "{jid}|{account-jid}"
# so the two are individually addressable. `list` prints whatever form is in use.
# `select`/`close` take that string or a bare JID. A bare JID picks the first tab
# for that JID.
#
# The tab bar is an accessibility container (`.accessibilityElement(children:
# .contain)`), so each `chat-tab-{jid}` chip is one of its direct children.
# `list`, `select` and `close` read those children, because `entire contents` does
# not reach the chips on macOS 27. The chip's `chat-tab-close-{jid}` button exists
# only while the pointer is over the tab, so `close` uses the chip's named action.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-chat-tabs.sh <list|select|close|next|previous|close-all> [JID]" >&2
    exit 1
fi

ACTION="$1"
JID="${2:-}"

if [[ "$ACTION" == "select" || "$ACTION" == "close" ]] && [[ -z "$JID" ]]; then
    echo "Usage: ducko-chat-tabs.sh $ACTION <JID>" >&2
    exit 1
fi

RESULT=$(osascript - "$ACTION" "$JID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set tabAction to item 1 of argv
    set tabJID to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_find_scene_window "chat" "chatWin")
            if chatWin is missing value then return "ERROR: chat window not found"
            if tabAction is "list" or tabAction is "select" or tabAction is "close" then
                $(ducko_as_find_element_by_id '"chat-tab-bar"' 'chatWin' 'chat tab bar not found' 'tabBar')
                if tabAction is "list" then
                    set tabList to ""
                    repeat with elem in (UI elements of tabBar)
                        try
                            set elemId to value of attribute "AXIdentifier" of elem
                            if elemId starts with "chat-tab-" and elemId is not "chat-tab-overflow" then
                                set tabList to tabList & (text 10 thru -1 of elemId) & linefeed
                            end if
                        end try
                    end repeat
                    return "LIST:" & tabList
                end if
                set tabChip to my findChatTab(tabBar, tabJID)
                if tabChip is missing value then return "ERROR: tab not found"
                if tabAction is "select" then
                    click tabChip
                    return "ok"
                end if
                -- System Events names a SwiftUI named action "Name:<name>" followed by its target and selector.
                repeat with chipAction in (actions of tabChip)
                    if (name of chipAction) starts with "Name:Close Tab" then
                        perform chipAction
                        return "ok"
                    end if
                end repeat
                return "ERROR: the tab offers no Close Tab action"
            else if tabAction is "next" or tabAction is "previous" then
                -- Tab cycling acts on the focused chat window.
                perform action "AXRaise" of chatWin
                delay 0.3
                if tabAction is "next" then
                    set itemName to "Select Next Tab"
                else
                    set itemName to "Select Previous Tab"
                end if
                try
                    click menu item itemName of menu 1 of menu bar item "Window" of menu bar 1
                on error
                    return "ERROR: " & itemName & " not found or disabled (needs two or more tabs)"
                end try
                return "ok"
            else if tabAction is "close-all" then
                try
                    click menu item "Close All Chats" of menu 1 of menu bar item "File" of menu bar 1
                on error
                    return "ERROR: Close All Chats not found or disabled"
                end try
                return "ok"
            else
                return "ERROR: unknown action: " & tabAction
            end if
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    LIST:*) printf '%s' "${RESULT#LIST:}" ;;
    ok)     echo "Tab action '$ACTION' ${JID:+for $JID }succeeded" ;;
    *)      echo "$RESULT" >&2; exit 1 ;;
esac
