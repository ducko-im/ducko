#!/bin/bash
# Build and package the debug app as the DuckoUITest copy, launch it, and output the window ID.
# The copy's executable name and bundle ID are its own, so `process "DuckoUITest"` never reaches an installed Ducko.
# Stops an earlier copy first. Launches under DUCKO_PROFILE, or under the profile `uitest` without one, so the copy
# never shares a store with a debug Ducko on the default profile.
# Usage: ducko-launch.sh
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

ROOT_DIR="$(ducko_repo_root)"
COPY="$(ducko_copy_path)"
LOG="$(dirname "$COPY")/package.log"

"$SCRIPTS_DIR/ducko-stop.sh" >/dev/null

mkdir -p "$(dirname "$COPY")"
# Renaming the executable and editing Info.plist break the bundle's seal, so the bundle is signed again. Its nested
# code keeps the signatures packaging gave it.
if ! {
    (cd "$ROOT_DIR" && APP_BUNDLE="$COPY" SIGNING_MODE=adhoc ./Scripts/package_app.sh debug) &&
        mv "$COPY/Contents/MacOS/DuckoApp" "$COPY/Contents/MacOS/DuckoUITest" &&
        /usr/libexec/PlistBuddy \
            -c "Set :CFBundleExecutable DuckoUITest" \
            -c "Set :CFBundleIdentifier im.ducko.uitest" \
            -c "Add :SUEnableAutomaticChecks bool false" \
            "$COPY/Contents/Info.plist" &&
        codesign --force -s - --entitlements "$ROOT_DIR/Resources/Entitlements.plist" "$COPY"
} >"$LOG" 2>&1; then
    tail -20 "$LOG" >&2
    echo "ERROR: building the DuckoUITest copy failed; full output in $LOG" >&2
    exit 1
fi

# Launched by its absolute path, which ducko-stop.sh matches.
# Because ducko-stop.sh ends the copy with a signal, macOS would restore that run's windows instead of opening
# Contacts, and the app does its launch work from the Contacts window.
# Ignoring the saved state starts every run like a launch after a normal quit.
DUCKO_PROFILE="${DUCKO_PROFILE:-uitest}" nohup "$COPY/Contents/MacOS/DuckoUITest" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
APP_PID=$!

DEADLINE=$((SECONDS + 15))
while ((SECONDS < DEADLINE)); do
    if WID=$(DUCKO_PID=$APP_PID "$SCRIPTS_DIR/ducko-window-id.sh" 2>/dev/null); then
        echo "$WID"
        exit 0
    fi
    sleep 1
done

# One more lookup, for its own error message.
DUCKO_PID=$APP_PID "$SCRIPTS_DIR/ducko-window-id.sh" >/dev/null || true
echo "ERROR: DuckoUITest window did not appear within 15 seconds" >&2
kill "$APP_PID" 2>/dev/null || true
exit 1
