#!/bin/zsh
# Guest half of `vm.sh provision`. Runs inside the VM as the lume user over SSH and is safe to re-run.
# Usage: provision-guest.sh <time zone, e.g. Europe/Berlin>
set -eu

# Passwordless sudo, which the GUI-session runner (`launchctl asuser`) needs.
if ! sudo -n true 2>/dev/null; then
    echo lume | sudo -S -p "" sh -c 'echo "lume ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/lume && chmod 440 /etc/sudoers.d/lume'
fi

# Command Line Tools, for python3 and swift inside the VM.
if ! xcode-select -p >/dev/null 2>&1; then
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    label=$(softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)
    sudo softwareupdate -i "$label"
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi

# Xcode, which `vm.sh provision` copies in: the Command Line Tools lack the SwiftData macro plugin Ducko needs.
if [[ -d /Applications/Xcode.app ]]; then
    sudo xcode-select -s /Applications/Xcode.app
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
fi

# Pre-answer Sparkle's first-launch prompt for im.ducko, the bundle the integration suites launch, because the prompt
# holds back the Welcome window.
defaults write im.ducko SUEnableAutomaticChecks -bool false
defaults write im.ducko SUHasLaunchedBefore -bool true

# TCC charges commands run over SSH to the sshd binaries, so they hold the grants every command inherits.
# Writing the system TCC.db needs SIP off. The user TCC.db (Automation) stays unreadable even then; `vm.sh allow` covers it.
csrutil status | grep -q disabled || { echo "SIP is on in the VM; turn it off first (SKILL.md, Creating the VM from scratch)" >&2; exit 1; }
DB="/Library/Application Support/com.apple.TCC/TCC.db"
for client in /usr/libexec/sshd-keygen-wrapper /usr/libexec/sshd-session; do
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent; do
        sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('$service', '$client', 1, 2, 4, 1, 0)"
    done
done
# Peekaboo.app is its own TCC client, keyed by bundle id and code requirement.
if [[ -d /Applications/Peekaboo.app ]]; then
    codesign -d -r- /Applications/Peekaboo.app 2>&1 | sed -n 's/^designated => //p' > /tmp/peekaboo-req.txt
    csreq -r /tmp/peekaboo-req.txt -b /tmp/peekaboo-req.bin
    req=$(xxd -p /tmp/peekaboo-req.bin | tr -d '\n')
    rm -f /tmp/peekaboo-req.txt /tmp/peekaboo-req.bin
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent; do
        sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) VALUES ('$service', 'boo.peekaboo.mac', 0, 2, 4, 1, X'$req', 0)"
    done
fi
sudo killall tccd 2>/dev/null || true

# Suppress the recurring "bypass the system private window picker" alert for the same clients.
python3 - <<'EOF'
import datetime, os, plistlib
path = os.path.expanduser("~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
approvals = plistlib.load(open(path, "rb")) if os.path.exists(path) else {}
far = datetime.datetime(2100, 1, 1)
for client in ("/usr/libexec/sshd-keygen-wrapper", "/usr/libexec/sshd-session"):
    approvals.setdefault(client, {}).update(
        kScreenCaptureApprovalLastAlerted=far, kScreenCaptureApprovalLastUsed=far,
        kScreenCapturePrivacyHintDate=far, kScreenCapturePrivacyHintPolicy=3153600000,
        kScreenCaptureAlertableUsageCount=0)
os.makedirs(os.path.dirname(path), exist_ok=True)
plistlib.dump(approvals, open(path, "wb"))
EOF

# Quiet desktop: host time zone, no hot corners, no update checks, no indexing, no screen saver, no desktop widgets,
# and no click-wallpaper-to-show-desktop.
sudo ln -sf "/var/db/timezone/zoneinfo/$1" /etc/localtime
for corner in tl tr bl br; do
    defaults write com.apple.dock "wvous-$corner-corner" -int 1
    defaults write com.apple.dock "wvous-$corner-modifier" -int 0
done
for key in AutomaticCheckEnabled AutomaticDownload CriticalUpdateInstall ConfigDataInstall AutomaticallyInstallMacOSUpdates; do
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate "$key" -bool false
done
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
sudo mdutil -a -i off >/dev/null
defaults write com.apple.screensaver idleTime -int 0
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
killall Dock WindowManager 2>/dev/null || true
