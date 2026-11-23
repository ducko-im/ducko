#!/bin/bash
# View or set the room topic in the active chat window.
# The RoomSubjectView provides inline editing with a pencil button.
# Setting succeeds once the banner shows the new topic, trimmed as the app trims it, or "No topic set" for an empty one.
# Usage: ducko-room-topic.sh [TEXT]
#   No args: prints the current topic
#   TEXT: set the room topic to TEXT (one line; an empty TEXT clears the topic)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ARGS=()
if [[ $# -gt 0 ]]; then
    TEXT="$1"
    # Typed with keystrokes, so a line break would press Return and submit the field early.
    if [[ "$TEXT" == *$'\n'* || "$TEXT" == *$'\r'* ]]; then
        echo "Usage: ducko-room-topic.sh [TEXT] (TEXT must be one line)" >&2
        exit 1
    fi
    EXPECTED=$(ducko_trim "$TEXT")
    [[ -n "$EXPECTED" ]] || EXPECTED="No topic set"
    ARGS=("$TEXT" "$EXPECTED")
fi

RESULT=$(osascript - ${ARGS[@]+"${ARGS[@]}"} << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            $(ducko_as_find_element_by_id '"room-topic-text"' 'chatWin' 'room-topic-text not found (is this a room?)' 'topicLabel')

            if (count of argv) is 0 then return "TOPIC:" & (value of topicLabel)
            set topicText to item 1 of argv
            set expectedText to item 2 of argv

            $(ducko_as_click_element_by_id '"room-topic-edit-button"' 'chatWin' 'room-topic-edit-button not found')
            $(ducko_as_await_element '"room-topic-field"' chatWin window 5 'room-topic-field not found' topicField '"chat"')
            $(ducko_as_fill_element "topicField" "topicText")
            $(ducko_as_click_element_by_id '"room-topic-save-button"' 'chatWin' 'room-topic-save-button not found')

            -- The window title follows the selected tab, so find the window again on each pass.
            set deadline to (current date) + 10
            repeat until (current date) > deadline
                delay 0.5
$(ducko_as_find_scene_window "chat" "chatWin")
                set topicLabel to missing value
                if chatWin is not missing value then set topicLabel to my findByAttr(chatWin, "AXIdentifier", "room-topic-text", 0, 30)
                if topicLabel is not missing value then
                    considering case
                        set topicShown to ((value of topicLabel) is expectedText)
                    end considering
                    if topicShown then return "ok"
                end if
            end repeat
            return "ERROR: the topic did not change (needs moderator rights?)"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok)      echo "Room topic set to: $EXPECTED" ;;
    TOPIC:*) echo "Topic: ${RESULT#TOPIC:}" ;;
    *)       echo "$RESULT" >&2; exit 1 ;;
esac
