#!/bin/bash
# View or set the room topic in the active chat window.
# The RoomSubjectView provides inline editing with a pencil button.
#
# Walks the chat window via findByAttr / findByRole rather than `entire
# contents`, which collapses on the nested chat hierarchy on macOS 26.
# Usage: ducko-room-topic.sh [TEXT]
#   No args: prints the current topic
#   TEXT: set the room topic to TEXT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TEXT="${1:-__none__}"

RESULT=$(osascript - "$TEXT" << APPLESCRIPT
$(ducko_as_handlers)
on findByRole(el, roleWanted, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is roleWanted then return c
                end try
                set found to my findByRole(c, roleWanted, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByRole

on run argv
    set topicText to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        -- Find the chat window (window containing message-field).
        set chatWin to missing value
        repeat with win in (windows of process "DuckoUITest")
            if (my findByAttr(win, "AXIdentifier", "message-field", 0, 30)) is not missing value then
                set chatWin to win
                exit repeat
            end if
        end repeat
        if chatWin is missing value then return "ERROR: chat window not found"

        set subjectView to my findByAttr(chatWin, "AXIdentifier", "room-subject-view", 0, 30)
        if subjectView is missing value then return "ERROR: room-subject-view not found (is this a room?)"

        -- Read mode: return the current topic text.
        if topicText is "__none__" then
            set topicLabel to my findByRole(subjectView, "AXStaticText", 0, 10)
            if topicLabel is missing value then return "No topic set"
            return value of topicLabel
        end if

        -- Edit mode: click the pencil edit button.
        set pencil to my findByRole(subjectView, "AXButton", 0, 10)
        if pencil is missing value then return "ERROR: edit button not found in room-subject-view"
        click pencil
        delay 0.3

        -- Fill the text field that appears after clicking edit.
        set topicField to my findByRole(subjectView, "AXTextField", 0, 10)
        if topicField is missing value then return "ERROR: topic text field not found"
        set focused of topicField to true
        delay 0.2
        keystroke "a" using command down
        delay 0.1
        keystroke topicText
        delay 0.3

        set saveBtn to my findByRoleAndName(chatWin, "AXButton", "Save", 0, 30)
        if saveBtn is missing value then return "ERROR: Save button not found"
        click saveBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok)     echo "Room topic set" ;;
    ERROR*) echo "$RESULT" >&2; exit 1 ;;
    *)      echo "Topic: $RESULT" ;;
esac
