#!/bin/bash
# Capture a screenshot of the DuckoUITest window.
# Usage: ducko-screenshot.sh [FILENAME]
# Output path: $DUCKO_UI_OUTPUT_DIR/FILENAME, or /private/tmp/claude/FILENAME without it (default: ducko-screenshot.png)
# If FILENAME is an absolute path, it is used as-is.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

FILENAME="${1:-ducko-screenshot.png}"

if [[ "$FILENAME" = /* ]]; then
    OUTPUT="$FILENAME"
else
    OUTPUT="${DUCKO_UI_OUTPUT_DIR:-/private/tmp/claude}/$FILENAME"
fi
mkdir -p "$(dirname "$OUTPUT")"

WID=$("$SCRIPTS_DIR/ducko-window-id.sh")
screencapture -x -o -l "$WID" "$OUTPUT"
echo "$OUTPUT"
