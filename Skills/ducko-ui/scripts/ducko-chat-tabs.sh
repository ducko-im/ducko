#!/bin/bash
# Enumerate, select, cycle, or close the bottom conversation tabs in the chat window.
# Usage: ducko-chat-tabs.sh <list|select|close|next|previous|close-all> [JID]
#   list:        print the identity of all open tabs (one per line)
#   select JID:  click the tab for JID to make it active
#   close JID:   click the tab's close button (revealed on hover over the tab)
#   next:        Window > Select Next Tab (⌃⇥), wrapping at the end
#   previous:    Window > Select Previous Tab (⌃⇧⇥), wrapping at the start
#   close-all:   File > Close All Chats (⌥⌘W), closing every tab and the chat window
#
# Tab identity is the bare JID when unique. When the same peer JID is open under
# more than one account, each tab is account-qualified as "{jid}|{account-jid}"
# so the two are individually addressable. `list` prints whatever form is in use;
# pass that exact string to `select`/`close`.
#
# The tab bar is an accessibility container (`.accessibilityElement(children:
# .contain)`), so each `chat-tab-{jid}` chip is exposed as its own element —
# `list` and `select` resolve it under osascript. `close` is
# best-effort: its `chat-tab-close-{jid}` button is revealed only on hover and is
# merged into the chip's own combined element, so the identifier may not resolve.
# The integration suite (UIContactInfoTests) drives this control via Swift
# AXUIElement and is authoritative.
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
            $(ducko_as_find_window_by_id "chat-tab-bar" "chat window with tab bar not found" "chatWin")
            if tabAction is "list" then
                set tabList to ""
                set allElems to entire contents of chatWin
                repeat with elem in allElems
                    try
                        set elemId to value of attribute "AXIdentifier" of elem
                        if elemId starts with "chat-tab-" and elemId does not start with "chat-tab-close-" and elemId is not "chat-tab-bar" and elemId is not "chat-tab-new" then
                            set tabList to tabList & (text 10 thru -1 of elemId) & linefeed
                        end if
                    end try
                end repeat
                return "LIST:" & tabList
            else if tabAction is "select" then
                $(ducko_as_click_element_by_id '"chat-tab-" & tabJID' 'chatWin' 'tab not found')
                return "ok"
            else if tabAction is "close" then
                $(ducko_as_click_element_by_id '"chat-tab-close-" & tabJID' 'chatWin' 'tab close button not found')
                return "ok"
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
