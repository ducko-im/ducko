#!/bin/bash
# Add a bookmark via the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), clicks "Add Bookmark",
# fills in the room JID and optional nickname, then confirms.
# Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOM_JID="${1:?Usage: ducko-add-bookmark.sh ROOM_JID [NICKNAME]}"
NICKNAME="${2:-__none__}"

# Ensure Bookmarks sheet is open
"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$ROOM_JID" "$NICKNAME" << 'APPLESCRIPT'
on run argv
    set roomJID to item 1 of argv
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
            -- Click the Add Bookmark button to open the sub-sheet
            set clicked to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "add-bookmark-button" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not clicked then return "ERROR: add-bookmark-button not found"
            delay 0.5
            -- Fill room JID using identifier
            set filled to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "bookmark-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke roomJID
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: bookmark-jid-field not found"
            delay 0.3
            -- Fill nickname if provided
            if nick is not "__none__" then
                set allElems to entire contents of contactWin
                repeat with elem in allElems
                    try
                        set elemId to value of attribute "AXIdentifier" of elem
                        if elemId is "bookmark-nickname-field" then
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
            -- Confirm has .defaultAction keyboard shortcut
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Bookmark added for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
