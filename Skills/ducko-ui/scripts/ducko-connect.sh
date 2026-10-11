#!/bin/bash
# Reconnect a running DuckoUITest by restarting it.
# The app auto-connects on launch accounts that have stored credentials and Connect on Launch on.
# Usage: ducko-connect.sh
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

"$SCRIPTS_DIR/ducko-stop.sh"
sleep 1
"$SCRIPTS_DIR/ducko-launch.sh"
