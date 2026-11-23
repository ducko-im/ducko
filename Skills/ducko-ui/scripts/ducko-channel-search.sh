#!/bin/bash
# Search for channels in the Join Room sheet, opening it on Contacts first when it is not open.
# Prints the JID of each room found, or "0 results", once the search has settled. Fails with the sheet's rate-limit
# notice when it shows one, with the sheet's error when this search shows one, and while an earlier search is still
# running.
# Usage: ducko-channel-search.sh QUERY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

QUERY="${1:?Usage: ducko-channel-search.sh QUERY}"

RESULT=$(osascript - "$QUERY" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            -- Join Room (File menu, ⌘⇧N) is enabled only while Contacts is the key window.
            $(ducko_as_raise_scene_window "contacts" "Contacts window not found" "contactWin")
            if (my findInSheets(contactWin, "channel-search-field")) is missing value then
                keystroke "n" using {command down, shift down}
                $(ducko_as_await_element '"channel-search-field"' contactWin sheets 5 'Join Room sheet did not open' searchField)
            end if
            set joinSheet to missing value
            repeat with s in sheets of contactWin
                if (my findByAttr(s, "AXIdentifier", "channel-search-field", 0, 30)) is not missing value then
                    set joinSheet to contents of s
                    exit repeat
                end if
            end repeat
            if joinSheet is missing value then return "ERROR: Join Room sheet not found"

            set waitNotice to my findByAttr(joinSheet, "AXIdentifier", "channel-search-wait", 0, 30)
            if waitNotice is not missing value then return "ERROR: " & (value of waitNotice)

            $(ducko_as_fill_field_by_id '"channel-search-field"' 'joinSheet' 'query' 'channel-search-field not found')
            $(ducko_as_await_field_value "fillTarget" "query")

            -- An empty field disables the button as well, so check it only once the query is typed. Requiring it
            -- enabled keeps an earlier search still in flight from settling this one.
            $(ducko_as_find_element_by_id '"channel-search-button"' 'joinSheet' 'channel-search-button not found' 'searchButton')
            if not (enabled of searchButton) then return "ERROR: a channel search is still running"
            click searchButton

            set clickedAt to current date
            set seenRunning to false
            set settled to false
            repeat until (current date) > clickedAt + 20
                delay 0.5
                set waitNotice to my findByAttr(joinSheet, "AXIdentifier", "channel-search-wait", 0, 30)
                if waitNotice is not missing value then return "ERROR: " & (value of waitNotice)
                set errorElem to my findByAttr(joinSheet, "AXIdentifier", "join-room-error", 0, 30)
                if errorElem is not missing value then return "ERROR: " & (value of errorElem)
                if enabled of searchButton then
                    if seenRunning or (current date) > clickedAt + 2 then
                        set settled to true
                        exit repeat
                    end if
                else
                    set seenRunning to true
                end if
            end repeat
            if not settled then return "ERROR: the channel search did not finish"

            set report to ""
            repeat with resultId in (my collectIdentifiers(joinSheet, "channel-result-", 0, 30))
                set report to report & (my idSuffix("channel-result-", resultId)) & linefeed
            end repeat
            if report is "" then set report to "0 results" & linefeed
            return "REPORT:" & report
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    REPORT:*) printf '%s\n' "${RESULT#REPORT:}" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
