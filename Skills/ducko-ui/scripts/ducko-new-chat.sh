#!/bin/bash
# Open the New Chat sheet from the contact list, fill in a JID, optionally pick the
# sending account, and start the chat. The chat opens in a separate window.
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

RESULT=$(osascript - "$JID" "$ACCOUNT" << 'APPLESCRIPT'
on run argv
    set jid to item 1 of argv
    set acct to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Find the Contacts window (first window with contact list)
            set contactWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "contact-list" then
                            set contactWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if contactWin is not missing value then exit repeat
            end repeat
            -- Fall back to window 1 if contact list not found
            if contactWin is missing value then set contactWin to window 1
            -- New Chat is on the File menu (⌘N).
            keystroke "n" using command down
            delay 1
            -- Fill JID using identifier
            set filled to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "new-chat-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke jid
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: new-chat-jid-field not found"
            -- Optionally select the sending account. The picker is present only
            -- when more than one account is enabled; with a single account the
            -- chat opens under it and no ACCOUNT argument is needed.
            if acct is not "" then
                set picker to missing value
                set allElems to entire contents of contactWin
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "new-chat-account-picker" then
                            set picker to elem
                            exit repeat
                        end if
                    end try
                end repeat
                if picker is missing value then return "ERROR: new-chat-account-picker not found"
                click picker
                delay 0.3
                try
                    click (first menu item of menu 1 of picker whose name contains acct)
                on error
                    return "ERROR: account not in picker: " & acct
                end try
                delay 0.2
            end if
            delay 0.3
            -- Start Chat has .defaultAction keyboard shortcut
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Chat started with $JID${ACCOUNT:+ on $ACCOUNT}"
else
    echo "$RESULT" >&2
    exit 1
fi
