#!/bin/bash
# Switch to a specific tab in the Room Settings sheet.
# The Room Settings sheet must already be open (use ducko-room-settings.sh first).
#
# The tabs are a SwiftUI Picker: `.tabs` style on macOS 27, `.segmented` below.
# Either way the segments expose their label through AXDescription and leave
# AXTitle/name empty, so the lookup matches on that attribute. The sheet
# is found via findByAttr rather than `entire contents`, which collapses on the
# nested hierarchy.
# Usage: ducko-room-settings-tab.sh <General|Members>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

TAB="${1:?Usage: ducko-room-settings-tab.sh <General|Members>}"

RESULT=$(osascript - "$TAB" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set tabName to item 1 of argv
    set tabNames to {"General", "Members"}
    if tabName is not in tabNames then return "ERROR: unknown tab: " & tabName
    tell application "System Events"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 0.3
        -- Find the window/sheet containing the room settings view.
        set settingsWin to missing value
        repeat with win in (windows of proc)
            if (my findByAttr(win, "AXIdentifier", "room-settings-view", 0, 30)) is not missing value then
                set settingsWin to win
                exit repeat
            end if
        end repeat
        if settingsWin is missing value then return "ERROR: room settings sheet not found (open it with ducko-room-settings.sh first)"
        set tabSeg to my findByAttr(settingsWin, "AXDescription", tabName, 0, 30)
        if tabSeg is missing value then return "ERROR: tab " & tabName & " not found in room settings"
        click tabSeg
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Switched to tab: $TAB"
else
    echo "$RESULT" >&2
    exit 1
fi
