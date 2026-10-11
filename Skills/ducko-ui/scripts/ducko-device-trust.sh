#!/bin/bash
# Trust, untrust, or verify an OMEMO device in the DeviceFingerprintsSheet.
# The fingerprints sheet must already be open (via ducko-encrypt.sh fingerprints).
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested device list on macOS 26.
# Usage: ducko-device-trust.sh DEVICE_ID ACTION
#   DEVICE_ID: the numeric device ID
#   ACTION: trust|untrust|verify
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-device-trust.sh DEVICE_ID ACTION" >&2
    exit 1
fi

DEVICE_ID="$1"
ACTION="$2"

RESULT=$(osascript - "$DEVICE_ID" "$ACTION" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set deviceID to item 1 of argv
    set trustAction to item 2 of argv

    set btnPrefix to ""
    if trustAction is "trust" then
        set btnPrefix to "trust-button-"
    else if trustAction is "untrust" then
        set btnPrefix to "untrust-button-"
    else if trustAction is "verify" then
        set btnPrefix to "verify-button-"
    else
        return "ERROR: unknown action (use trust, untrust, or verify)"
    end if

    set targetId to btnPrefix & deviceID

    tell application "System Events"
        set frontmost of process "DuckoUITest" to true
        delay 0.5
        repeat with win in (windows of process "DuckoUITest")
            set btn to my findByAttr(win, "AXIdentifier", targetId, 0, 30)
            if btn is not missing value then
                click btn
                return "ok"
            end if
        end repeat
        return "ERROR: button not found for device " & deviceID & " (wrong trust state?)"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Device $DEVICE_ID: $ACTION"
else
    echo "$RESULT" >&2
    exit 1
fi
