#!/bin/bash
# Interact with the encryption menu in the chat header.
# Opens the menu, and optionally selects an action.
# Usage: ducko-encrypt.sh [on|off|fingerprints]
#   No args:       opens the encryption menu (for screenshot)
#   on:            click "Enable Encryption"
#   off:           click "Disable Encryption"
#   fingerprints:  click "Device Fingerprints…" to open the sheet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ACTION="${1:-__none__}"

RESULT=$(osascript - "$ACTION" << 'APPLESCRIPT'
on run argv
    set encAction to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Find the chat window (window containing message-field)
            set chatWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "message-field" then
                            set chatWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if chatWin is not missing value then exit repeat
            end repeat
            if chatWin is missing value then return "ERROR: chat window not found"
            -- Find and click the encryption menu
            set menuBtn to missing value
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "encryption-menu" then
                        set menuBtn to elem
                        click elem
                        exit repeat
                    end if
                end try
            end repeat
            if menuBtn is missing value then return "ERROR: encryption-menu not found"
            delay 0.5
            -- If no action requested, just return that the menu is open
            if encAction is "__none__" then return "menu-opened"
            -- Map action to menu item label
            set targetLabel to ""
            if encAction is "on" then
                set targetLabel to "Enable Encryption"
            else if encAction is "off" then
                set targetLabel to "Disable Encryption"
            else if encAction is "fingerprints" then
                set targetLabel to "Device Fingerprints…"
            else
                return "ERROR: unknown action: " & encAction
            end if
            -- Strategy 1: search within the menu attached to the encryption button
            try
                set menuElems to entire contents of menu 1 of menuBtn
                repeat with elem in menuElems
                    try
                        if role of elem is "AXMenuItem" and name of elem is targetLabel then
                            click elem
                            return "ok"
                        end if
                    end try
                end repeat
            end try
            -- Strategy 2: fallback to window contents
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem is targetLabel then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: menu item " & targetLabel & " not found"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    menu-opened) echo "Encryption menu opened" ;;
    ok)          echo "Applied: ${ACTION}" ;;
    *)           echo "$RESULT" >&2; exit 1 ;;
esac
