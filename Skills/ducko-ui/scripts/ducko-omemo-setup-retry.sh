#!/bin/bash
# Press "Try Again" in the active chat's encryption setup banner, which sets up this Mac's encryption for the chat's
# account again. The banner shows under the chat's header, or under a room's subject, only while encryption is on in
# the chat and the account's setup is incomplete or refused.
# Usage: ducko-omemo-setup-retry.sh
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
            $(ducko_as_raise_scene_window "chat" "chat window not found" "chatWin")
            $(ducko_as_find_element_by_id '"omemo-setup-retry-button"' 'chatWin' "omemo-setup-retry-button not found: this Mac's encryption setup is not incomplete" 'retryButton')
            if not (enabled of retryButton) then return "ERROR: omemo-setup-retry-button is disabled (the account is offline, or a retry already runs)"
            click retryButton
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Retrying encryption setup"
