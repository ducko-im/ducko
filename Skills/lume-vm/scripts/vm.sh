#!/bin/zsh
# Host-side driver for the Ducko UI-test VM. See ../SKILL.md for the workflow.
set -eu

VM=${DUCKO_VM:-ducko}
STORAGE=${DUCKO_VM_STORAGE:-home}
SCRIPTS=${0:A:h}
REPO=${SCRIPTS:h:h:h}
EXCHANGE=$REPO/.build/vm-exchange
SHARES="/Volumes/My Shared Files"
GUEST_EXCHANGE="$SHARES/vm-exchange"
GUEST_REPO="$SHARES/${REPO:t}"
# The VM's writable copy of the checkout, where builds and test runs happen.
GUEST_WORK=/Users/lume/work/ducko

usage() {
    cat >&2 <<'EOF'
usage: vm.sh <command>
  start | stop | status | view       boot (repo read-only + exchange shared), shut down, show state, open a viewer
  sh <command>                       run in an SSH shell (no GUI session)
  gui <command>                      run in the logged-in GUI session (AX, screencapture, CGEvents, open)
  sync                               copy the working tree into the VM's build folder
  ui <script> [args]                 sync, then run a ducko-ui script in the GUI session
  itest [swift test args]            sync, package, then run the integration tests (default: --filter UILayer)
  push <host path> <guest path>      copy a file or bundle into the VM
  pull <guest path> <host path>      copy a file or bundle out of the VM
  screenshot <host png>              capture the whole VM screen
  appearance light|dark              switch the system appearance
  allow                              press Allow on pending consent alerts (Automation)
  ax list | ax press <process> <title>   list or press buttons and menu items in any app
  provision                          (re)apply the VM setup; safe to re-run
EOF
    exit 2
}

# Remote stderr arrives on stdout. The remote exit status is passed through.
guest() { lume ssh "$VM" --storage "$STORAGE" -t "${DUCKO_VM_TIMEOUT:-0}" "$1"; }

# `launchctl asuser` runs the command in the user's Aqua session; a plain SSH command runs in a Background session.
gui() { guest "sudo -n launchctl asuser 501 sudo -n -u lume -H zsh -lc ${(qq)1}"; }

# Compiles a Swift helper from this folder into the exchange folder, and prints its path inside the VM.
tool() {
    local src=$SCRIPTS/$1.swift bin=$EXCHANGE/bin/$1
    if [[ ! -x $bin || $src -nt $bin ]]; then
        mkdir -p "$EXCHANGE/bin"
        swiftc -O -o "$bin" "$src"
    fi
    print -r -- "$GUEST_EXCHANGE/bin/$1"
}

# Folders and bundles cross the exchange folder as one ditto archive: the guest cannot resolve relative symlinks
# (framework Versions/Current) read straight off the share.
push() {
    local name=push-$$ mode=
    [[ -d $1 ]] && { mode=-x; ditto -c "$1" "$EXCHANGE/$name"; } || ditto "$1" "$EXCHANGE/$name"
    local staged="$GUEST_EXCHANGE/$name"
    guest "ditto $mode ${(qq)staged} ${(qq)2}; s=\$?; rm -f ${(qq)staged}; exit \$s"
}

allow() {
    local bin=$(tool axbuttons)
    gui "p=\$(pgrep -x UserNotificationCenter) || exit 0; while ${(qq)bin} press \$p Allow 2>/dev/null; do sleep 1; done"
}

running() { lume ls --storage "$STORAGE" 2>/dev/null | awk -v vm="$VM" '$1 == vm' | grep -q running; }

# Shares are fixed at boot, so a VM started from another checkout serves that checkout's files, usually to another
# session. `start` records the full path of the checkout it booted from in the exchange folder. sync compares that path,
# because the share's folder name can match another checkout's.
sync() {
    running || { echo "the VM is not running; run vm.sh start" >&2; exit 1; }
    local serving=$(guest "cat ${(qq)GUEST_EXCHANGE}/vm-checkout 2>/dev/null" || true)
    serving=${serving//$'\r'/}
    if [[ $serving != "$REPO" ]]; then
        echo "the VM is serving ${serving:-another checkout}, probably for another session; wait for it or ask the user, and restart it from this checkout (vm.sh stop && vm.sh start) only once the user confirms it is free" >&2
        exit 1
    fi
    # The share answers the first lookup of a replaced file (editors save by replacing) with the old file, and that
    # lookup refreshes it. So a dry run walks the tree once before the copy.
    local tree="--delete --exclude /.build --exclude /IntegrationTests/.build --exclude /Ducko.app --exclude /.git ${(qq)GUEST_REPO}/ ${(qq)GUEST_WORK}/"
    guest "mkdir -p ${(qq)GUEST_WORK} && rsync -an $tree >/dev/null && rsync -a $tree"
    # A linked worktree's credentials file is a symlink into the main checkout, which the VM cannot resolve.
    local credentials=$REPO/IntegrationTests/.env.test
    if [[ -L $credentials ]]; then
        guest "rm -f ${(qq)GUEST_WORK}/IntegrationTests/.env.test"
        push "${credentials:A}" "$GUEST_WORK/IntegrationTests/.env.test"
    fi
}

(( $# )) || usage
command=$1
shift
case $command in
start)
    if ! running; then
        mkdir -p "$EXCHANGE"
        # lume mangles `path:ro` (".../ducko:ro" becomes ".../duckoo"); the trailing slash avoids that.
        lume run "$VM" --storage "$STORAGE" --detach --display none --shared-dir "$REPO/:ro" --shared-dir "$EXCHANGE"
        print -r -- "$REPO" >"$EXCHANGE/vm-checkout"
    fi
    # Ready once the auto-login session's Dock runs.
    for _ in {1..60}; do
        DUCKO_VM_TIMEOUT=10 guest 'pgrep -x Dock >/dev/null' >/dev/null 2>&1 && { echo "$VM ready"; exit 0; }
        sleep 3
    done
    echo "$VM: no GUI session after 3 minutes" >&2
    exit 1
    ;;
stop)
    # `lume stop` ends the VM process without a guest shutdown, so shut down from inside first.
    running || exit 0
    DUCKO_VM_TIMEOUT=10 guest 'sudo -n shutdown -h now' >/dev/null 2>&1 || true
    for _ in {1..30}; do running || exit 0; sleep 2; done
    lume stop "$VM" --storage "$STORAGE"
    ;;
status) lume ls --storage "$STORAGE" | awk -v vm="$VM" 'NR == 1 || $1 == vm' ;;
view) lume attach "$VM" --storage "$STORAGE" ;;
sh) (( $# == 1 )) || usage; guest "$1" ;;
gui) (( $# == 1 )) || usage; gui "$1" ;;
sync) (( $# == 0 )) || usage; sync ;;
ui)
    (( $# >= 1 )) || usage
    sync
    script=$GUEST_WORK/Skills/ducko-ui/scripts/$1
    shift
    environment="DUCKO_UI_OUTPUT_DIR=${(qq)GUEST_EXCHANGE}/ducko-ui"
    [[ -n ${DUCKO_PROFILE-} ]] && environment+=" DUCKO_PROFILE=${(qq)DUCKO_PROFILE}"
    gui "$environment ${(qq)script} ${(j: :)${(@qq)@}}"
    ;;
itest)
    sync
    arguments=("$@")
    # SwiftPM combines several --filter flags with OR, so the default applies only when the caller names none.
    (( ${arguments[(I)--filter(|=*)]} )) || arguments+=(--filter UILayer)
    # Packaging produces the Ducko.app the UI suites launch, and builds every product, including the DuckoCLI the CLI
    # suites spawn.
    gui "cd ${(qq)GUEST_WORK} && SIGNING_MODE=adhoc ./Scripts/package_app.sh debug && swift test --package-path IntegrationTests ${(j: :)${(@qq)arguments}}"
    ;;
push) (( $# == 2 )) || usage; push "$1" "$2" ;;
pull)
    (( $# == 2 )) || usage
    staged="$GUEST_EXCHANGE/pull-$$"
    guest "if [ -d ${(qq)1} ]; then ditto -c ${(qq)1} ${(qq)staged}.cpio; else ditto ${(qq)1} ${(qq)staged}; fi"
    if [[ -e $EXCHANGE/pull-$$.cpio ]]; then
        ditto -x "$EXCHANGE/pull-$$.cpio" "$2" && rm -f "$EXCHANGE/pull-$$.cpio"
    else
        ditto "$EXCHANGE/pull-$$" "$2" && rm -f "$EXCHANGE/pull-$$"
    fi
    ;;
screenshot)
    (( $# == 1 )) || usage
    staged="$GUEST_EXCHANGE/screen-$$.png"
    gui "screencapture -x ${(qq)staged}"
    mv "$EXCHANGE/screen-$$.png" "$1"
    ;;
appearance)
    [[ $# == 1 && ( $1 == light || $1 == dark ) ]] || usage
    [[ $1 == dark ]] && dark=true || dark=false
    gui "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to $dark'"
    ;;
allow) allow ;;
ax)
    bin=$(tool axbuttons)
    case "${1-}" in
    list) gui "${(qq)bin} list" ;;
    press) (( $# == 3 )) || usage; gui "${(qq)bin} press \$(pgrep -x ${(qq)2}) ${(qq)3}" ;;
    *) usage ;;
    esac
    ;;
provision)
    # Peekaboo.app, copied from the host before the guest script grants it.
    [[ -d /Applications/Peekaboo.app ]] && push /Applications/Peekaboo.app /Applications/Peekaboo.app
    # Xcode, since the Command Line Tools cannot build Ducko. Any Xcode that builds it will do, so an existing one stays.
    if ! guest '[ -d /Applications/Xcode.app ]'; then
        push /Applications/Xcode.app /Applications/Xcode.app
    fi
    guest "zsh ${(qq)GUEST_REPO}/Skills/lume-vm/scripts/provision-guest.sh ${(qq)$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')}"
    # The peekaboo CLI and its folder, copied from the host's install when present.
    if peekaboo=$(readlink -f "$(command -v peekaboo)" 2>/dev/null); then
        push "${peekaboo:h}" /tmp/peekaboo
        guest "sudo mkdir -p /usr/local/libexec /usr/local/bin && sudo rm -rf /usr/local/libexec/peekaboo && sudo mv /tmp/peekaboo /usr/local/libexec/peekaboo && sudo ln -sf /usr/local/libexec/peekaboo/peekaboo /usr/local/bin/peekaboo"
    fi
    # The first Apple Event to an app raises a consent alert; allow it in the background while the event waits.
    tool axbuttons >/dev/null
    ( sleep 3; allow ) &
    gui "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to POSIX file \"/System/Library/Desktop Pictures/Solid Colors/Stone.png\"'"
    ( sleep 3; allow ) &
    gui "osascript -e 'tell application \"Finder\" to close every window'"
    wait
    ;;
*) usage ;;
esac
