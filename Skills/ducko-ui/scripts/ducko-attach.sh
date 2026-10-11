#!/bin/bash
# Attach a file via the attachment button in the active chat window.
# Opens the system file picker, fills it through ducko-file-panel.swift, and checks that it closed.
# Usage: ducko-attach.sh FILE_PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

FILE_PATH="${1:?Usage: ducko-attach.sh FILE_PATH}"

# Resolve to absolute path
if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(cd "$(dirname "$FILE_PATH")" && pwd)/$(basename "$FILE_PATH")"
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "ERROR: File not found: $FILE_PATH" >&2
    exit 1
fi

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5

        tell process "DuckoUITest"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id '"attachment-button"' 'chatWin' "attachment-button not found")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_fill_open_panel "$RESULT" "$FILE_PATH"
echo "File attached: $FILE_PATH"
