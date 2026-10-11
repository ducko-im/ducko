#!/bin/bash
# Select a setup mode on the Welcome screen's segmented control.
# Usage: ducko-select-mode.sh <Import|Login|Register>
#
# Walks the window's UI-element tree directly rather than via
# `entire contents`, which collapses to zero on the Welcome window's
# deeply-nested SwiftUI hierarchy on macOS 26.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

MODE="${1:?Usage: ducko-select-mode.sh <Import|Login|Register>}"

case "$MODE" in
    Import | Login | Register) ;;
    *)
        echo "ERROR: mode must be Import, Login, or Register (got '$MODE')" >&2
        exit 1
        ;;
esac

RESULT=$(osascript - "$MODE" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set targetMode to item 1 of argv
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set proc to process "DuckoUITest"
        set frontmost of proc to true
        delay 1
        if not (exists window "Welcome" of proc) then return "ERROR: Welcome window not found"
        set win to window "Welcome" of proc

        set picker to my findByAttr(win, "AXIdentifier", "setup-mode-picker", 0, 30)
        if picker is missing value then return "ERROR: setup-mode-picker not found"

        -- The SwiftUI segmented Picker exposes each segment label via
        -- AXDescription; AXTitle/name is empty on macOS 26, so match on that.
        set seg to my findByAttr(picker, "AXDescription", targetMode, 0, 6)
        if seg is missing value then return "ERROR: " & targetMode & " segment not found"

        click seg
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Selected $MODE mode"
else
    echo "$RESULT" >&2
    exit 1
fi
