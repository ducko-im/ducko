#!/bin/bash
# Switch to Import mode on the Welcome screen, click Import, and wait for the outcome.
# Tick an account and type its password with ducko-import-account.sh fill first, since Import stays disabled while a
# ticked account has no password.
# Succeeds with "Import Complete", followed by the connected-account count when the import included accounts.
# Fails with the failed accounts for "No Accounts Connected", with an account's error for a rejected password, and
# when an account's server offers only PLAIN.
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the deeply-nested SwiftUI hierarchy on
# macOS 26. The segmented Picker exposes the Import label via AXDescription.
# import-button exists only in the data-found branch of the Import view; the
# no-data branch instead exposes choose-adium-folder-button.
# Usage: ducko-import.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

RESULT=$(osascript << APPLESCRIPT
$(ducko_as_handlers)
on run
    tell application "System Events"
        if not (exists process "DuckoUITest") then return "ERROR: DuckoUITest is not running"
        set frontmost of process "DuckoUITest" to true
        delay 1
        tell process "DuckoUITest"
            $(ducko_as_raise_scene_window "welcome" "Welcome window not found" "win")

            -- Ensure the Import segment is selected.
            set picker to my findByAttr(win, "AXIdentifier", "setup-mode-picker", 0, 30)
            if picker is missing value then return "ERROR: setup-mode-picker not found"
            set seg to my findByAttr(picker, "AXDescription", "Import", 0, 6)
            if seg is missing value then return "ERROR: Import segment not found"
            click seg
            delay 0.5

            -- Present only when discovery found accounts or logs.
            set importBtn to my findByAttr(win, "AXIdentifier", "import-button", 0, 30)
            if importBtn is missing value then return "ERROR: import-button not found (no Adium data discovered?)"
            if not (enabled of importBtn) then return "ERROR: import-button is disabled (an account is ticked without a password?)"
            click importBtn

            set deadline to (current date) + 60
            repeat until (current date) > deadline
                delay 1
                if (my findByAttr(win, "AXIdentifier", "import-done-button", 0, 30)) is not missing value then
                    set titleText to my findByAttr(win, "AXIdentifier", "import-result-title", 0, 30)
                    if titleText is missing value then return "ERROR: import-result-title not found"
                    set headline to value of titleText
                    if headline is "Import Complete" then
                        set accountsText to my findByAttr(win, "AXIdentifier", "import-result-accounts", 0, 30)
                        if accountsText is missing value then return "DONE:" & headline
                        return "DONE:" & headline & linefeed & (value of accountsText)
                    end if
                    set failures to ""
                    repeat with failureId in (my collectIdentifiers(win, "import-account-failure-", 0, 30))
                        set failureText to my findByAttr(win, "AXIdentifier", contents of failureId, 0, 30)
                        if failureText is not missing value then set failures to failures & linefeed & (value of failureText)
                    end repeat
                    return "ERROR: " & headline & failures
                end if
                set errorIds to my collectIdentifiers(win, "account-error-", 0, 30)
                if (count of errorIds) > 0 then
                    set errorId to item 1 of errorIds
                    set errorText to my findByAttr(win, "AXIdentifier", errorId, 0, 30)
                    return "ERROR: " & (my idSuffix("account-error-", errorId)) & ": " & (value of errorText)
                end if
                set plainIds to my collectIdentifiers(win, "import-allow-plain-", 0, 30)
                if (count of plainIds) > 0 then return "ERROR: " & (my idSuffix("import-allow-plain-", item 1 of plainIds)) & ": the server offers only PLAIN"
            end repeat
            return "ERROR: the import did not finish"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    DONE:*) echo "${RESULT#DONE:}" ;;
    *)      echo "$RESULT" >&2; exit 1 ;;
esac
