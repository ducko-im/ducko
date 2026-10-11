#!/bin/bash
# Usage: [DUCKO_PID=<pid>] ducko-dismiss-roster-notice.sh [contacts|info]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in
case "${1:-contacts}" in
    contacts) NOTICE_ID="roster-notice" ;;
    info) NOTICE_ID="contact-info-roster-notice" ;;
    *) echo "Usage: ducko-dismiss-roster-notice.sh [contacts|info]" >&2; exit 1 ;;
esac
APP_PID=$(ducko_app_pid)
exec swift "$SCRIPT_DIR/ducko-dismiss.swift" "$APP_PID" "$NOTICE_ID" "Dismiss notice"
