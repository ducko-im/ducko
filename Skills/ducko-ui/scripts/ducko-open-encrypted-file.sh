#!/bin/bash
# Press the open button on an encrypted file's card in the active chat. The card shows for a file other than an image
# shared in an encrypted message as an aesgcm:// link. The press decrypts the file, saves it to the
# Downloads folder and opens it in Quick Look, or shows why it failed in place of the card's "Encrypted file" caption.
# Usage: ducko-open-encrypted-file.sh [FILE_NAME]
#   No args:     presses the first open button the chat window lists
#   FILE_NAME:   also waits up to 30 seconds for ~/Downloads/FILE_NAME and prints its path. A name already taken there
#                gets a number, so move an earlier copy away first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

FILE_NAME="${1:-}"

RESULT=$(osascript - "encrypted-file-open-button" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set buttonId to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id 'buttonId' 'chatWin' 'encrypted-file-open-button not found: the chat shows no encrypted file')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Pressed the encrypted file's open button"

if [[ -n "$FILE_NAME" ]]; then
    SAVED="$HOME/Downloads/$FILE_NAME"
    for ((attempt = 0; attempt < 60; attempt++)); do
        if [[ -e "$SAVED" ]]; then
            echo "Saved: $SAVED"
            exit 0
        fi
        sleep 0.5
    done
    echo "ERROR: $SAVED did not appear; the card's caption says why" >&2
    exit 1
fi
