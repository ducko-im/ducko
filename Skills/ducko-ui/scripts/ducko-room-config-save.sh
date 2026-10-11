#!/bin/bash
# Save room config in the Room Settings sheet.
# Opens Room Settings first, then clicks the Save button by its label.
# (The Save button no longer carries an accessibility identifier — SwiftUI
# does not reliably propagate `.accessibilityIdentifier` to a `Button` carrying
# `.keyboardShortcut(.defaultAction)` on macOS 26 — so this script resolves
# the button by visible label inside the topmost sheet, mirroring
# `AppAccessor.clickSheetButton(label:)` in the integration tests.)
# Usage: ducko-room-config-save.sh ROOM_JID
#   ROOM_JID: The JID of the room (must be visible in the Rooms section)
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-room-config-save.sh ROOM_JID" >&2
    exit 1
fi

ROOM_JID="$1"

# Open Room Settings sheet
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoUITest" to true
    delay 0.3
    tell process "DuckoUITest"
        -- Find the Save button inside the topmost sheet by matching its
        -- visible label against AXDescription / AXTitle. SwiftUI
        -- `Button("Save") { ... }` publishes the label through
        -- AXDescription on macOS 26. The button is nested inside the
        -- `HStack` inside the sheet, so `entire contents of theSheet` walks the
        -- subtree — `buttons of theSheet` would only see direct children.
        repeat with win in windows
            try
                set theSheet to sheet 1 of win
                set sheetButtons to (every button of (entire contents of theSheet))
                repeat with btn in sheetButtons
                    try
                        if description of btn is "Save" then
                            click btn
                            return "ok"
                        end if
                    end try
                    try
                        if name of btn is "Save" then
                            click btn
                            return "ok"
                        end if
                    end try
                end repeat
            end try
        end repeat
        return "ERROR: Save button not found in any room settings sheet"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Room config saved for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
