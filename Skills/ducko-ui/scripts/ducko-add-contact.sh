#!/bin/bash
# Open the Add Contact sheet from the contact list, fill in a JID, and submit.
# Succeeds once the sheet has closed. A change the server left unconfirmed closes it too, with a roster notice on Contacts.
# Usage: ducko-add-contact.sh JID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

JID="${1:?Usage: ducko-add-contact.sh JID}"

RESULT=$(osascript - "$JID" << APPLESCRIPT
$(ducko_as_handlers)

on run argv
    set jid to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Add Contact (Contact menu, ⌘D) is enabled only while Contacts is the key window.
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            keystroke "d" using command down
            $(ducko_as_await_element '"add-contact-jid-field"' contactWin sheets 5 'add-contact-jid-field not found' jidField)
            $(ducko_as_fill_element "jidField" "jid")
            -- Add Contact has .defaultAction keyboard shortcut
            keystroke return
            $(ducko_as_await_sheet_closed contactWin contacts '"add-contact-jid-field"' '"add-contact-error"' 10 "the Add Contact sheet stayed open")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Contact added: $JID"
