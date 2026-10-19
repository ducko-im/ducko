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
            delay 1
            $(ducko_as_fill_field_by_id '"add-contact-jid-field"' 'contactWin' 'jid' 'add-contact-jid-field not found')
            -- Add Contact has .defaultAction keyboard shortcut
            keystroke return
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
                if (my findInSheets(contactWin, "add-contact-jid-field")) is missing value then return "ok"
                set errorElem to my findInSheets(contactWin, "add-contact-error")
                if errorElem is not missing value then
                    try
                        return "ERROR: " & (value of errorElem)
                    on error
                        return "ERROR: the Add Contact sheet shows an error"
                    end try
                end if
            end repeat
            return "ERROR: the Add Contact sheet stayed open"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Contact added: $JID"
