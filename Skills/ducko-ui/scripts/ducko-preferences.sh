#!/bin/bash
# Open the Preferences (Settings) window via Cmd+, unless it is open already, and raise it to the front.
# Fails unless the window ends up in front.
# Note: macOS titles this window after the selected tab (e.g. "General", "Accounts"), so it is found by the
# identifier SwiftUI gives its Settings window.
# Usage: ducko-preferences.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.3
        tell process "DuckoUITest"
            $(ducko_as_find_scene_window "$DUCKO_SETTINGS_SCENE" "settingsWin")
            if settingsWin is missing value then
                keystroke "," using command down
                $(ducko_as_await_scene_window "$DUCKO_SETTINGS_SCENE" 5 "Settings window did not open after Cmd+," "settingsWin")
            end if
            $(ducko_as_raise_scene_window "$DUCKO_SETTINGS_SCENE" "Preferences window not found" "prefsWin")
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Preferences window opened"
