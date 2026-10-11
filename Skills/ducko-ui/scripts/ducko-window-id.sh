#!/bin/bash
# Print the window ID of the first DuckoUITest window, or fail.
# Usage: ducko-window-id.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

PID=$(ducko_app_pid)
exec swift "$SCRIPT_DIR/ducko-window-id.swift" "$PID"
