#!/bin/bash
# Upload an avatar image via the profile sheet.
# Opens the profile sheet if not already open, clicks "Change Photo",
# fills the file importer through ducko-file-panel.swift, and checks that it closed.
# Usage: ducko-avatar.sh IMAGE_PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

IMAGE_PATH="${1:?Usage: ducko-avatar.sh IMAGE_PATH}"

# Resolve to absolute path
if [[ "$IMAGE_PATH" != /* ]]; then
    IMAGE_PATH="$(cd "$(dirname "$IMAGE_PATH")" && pwd)/${IMAGE_PATH##*/}"
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "ERROR: File not found: $IMAGE_PATH" >&2
    exit 1
fi

# Ensure profile sheet is open
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5

        tell process "DuckoUITest"
            -- ducko-profile.sh opens the profile sheet on Contacts.
            $(ducko_as_find_scene_window "contacts" "contactWin")
            if contactWin is missing value then return "ERROR: Contacts window not found"
            set photoButton to my findInSheets(contactWin, "profile-change-photo-button")
            if photoButton is missing value then return "ERROR: Change Photo button not found"
            click photoButton
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_fill_open_panel "$RESULT" "$IMAGE_PATH"
echo "Avatar uploaded"
