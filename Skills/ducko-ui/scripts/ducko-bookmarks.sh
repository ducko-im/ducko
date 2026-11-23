#!/bin/bash
# Open the Bookmarks sheet from the File menu (⌘⇧B), raising Contacts first, since the command is enabled only while
# Contacts is the key window. Succeeds once the sheet shows, or at once when it is already open.
# Usage: ducko-bookmarks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            if (my findInSheets(contactWin, "add-bookmark-button")) is not missing value then return "ok"
            keystroke "b" using {command down, shift down}
            $(ducko_as_await_element '"add-bookmark-button"' contactWin sheets 5 'Bookmarks sheet did not open' addButton)
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Bookmarks sheet opened"
