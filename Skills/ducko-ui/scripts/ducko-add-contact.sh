#!/bin/bash
# Open the Add Contact sheet from the contact list, fill in a JID, and submit.
# Uses accessibility identifiers for reliable targeting.
# Usage: ducko-add-contact.sh JID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

JID="${1:?Usage: ducko-add-contact.sh JID}"

RESULT=$(osascript - "$JID" << 'APPLESCRIPT'
on run argv
    set jid to item 1 of argv
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
            -- Add Contact is on the Contact menu (⌘D).
            keystroke "d" using command down
            delay 1
            -- Fill JID using identifier
            set filled to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "add-contact-jid-field" then
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
            if not filled then return "ERROR: add-contact-jid-field not found"
            delay 0.3
            -- Add Contact has .defaultAction keyboard shortcut
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Contact added: $JID"
else
    echo "$RESULT" >&2
    exit 1
fi
