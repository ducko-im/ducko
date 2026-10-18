#!/bin/bash
# Copy a code block through its "Copy Code" accessibility action, which needs no hover.
# Print what the clipboard then holds, and fail when it does not change.
# Takes the last code block in the open windows, or the first whose code contains TEXT.
# Usage: [DUCKO_PID=<pid>] ducko-copy-code-block.sh [TEXT]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in
APP_PID=$(ducko_app_pid)
exec swift "$SCRIPT_DIR/ducko-copy-code-block.swift" "$APP_PID" "${1:-}"
