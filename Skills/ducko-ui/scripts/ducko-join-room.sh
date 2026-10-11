#!/bin/bash
# Open the Join Room sheet from the contact list, fill in a room JID and nickname, and join.
# The room chat opens in a separate window. Uses accessibility identifiers for reliable targeting.
# Usage: ducko-join-room.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-join-room.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-__none__}"

RESULT=$(osascript - "$ROOM_JID" "$NICKNAME" << 'APPLESCRIPT'
on run argv
    set roomJid to item 1 of argv
    set nick to item 2 of argv
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
            -- Join Room is on the File menu (⌘⇧N).
            keystroke "n" using {command down, shift down}
            delay 1
            -- Fill room JID using identifier
            set filled to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "room-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke roomJid
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: room-jid-field not found"
            delay 0.3
            -- Fill nickname if provided
            if nick is not "__none__" then
                set allElems to entire contents of contactWin
                repeat with elem in allElems
                    try
                        set elemId to value of attribute "AXIdentifier" of elem
                        if elemId is "room-nickname-field" then
                            set focused of elem to true
                            delay 0.2
                            keystroke "a" using command down
                            delay 0.1
                            keystroke nick
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            delay 0.3
            -- Join has .defaultAction keyboard shortcut
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Joined room $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
