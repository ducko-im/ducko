#!/bin/bash
# Stop the DuckoUITest copy that ducko-launch.sh started from this checkout, leaving every other Ducko running.
# Usage: ducko-stop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

# pgrep reads an extended regular expression, so the path's own characters are escaped.
COPY_PATTERN=$(ducko_copy_path | sed 's/[][\.*^$(){}?+|]/\\&/g')
PATTERN="^${COPY_PATTERN}/Contents/MacOS/DuckoUITest( |$)"

running() { pgrep -f "$PATTERN" 2>/dev/null || true; }

# SIGTERM ends the app without the disconnect a normal quit sends. KILL covers a process that ignores it.
wait_for_exit() {
    local attempt
    for ((attempt = 0; attempt < $1; attempt++)); do
        [[ -z "$(running)" ]] && return 0
        sleep 0.5
    done
    return 1
}

PIDS=$(running)
if [[ -z "$PIDS" ]]; then
    echo "DuckoUITest is not running"
    exit 0
fi
kill -TERM $PIDS 2>/dev/null || true
if ! wait_for_exit 20; then
    kill -KILL $(running) 2>/dev/null || true
    if ! wait_for_exit 10; then
        echo "ERROR: DuckoUITest did not stop (PIDs: $(echo $(running)))" >&2
        exit 1
    fi
fi
echo "DuckoUITest stopped (PIDs: $(echo $PIDS))"
