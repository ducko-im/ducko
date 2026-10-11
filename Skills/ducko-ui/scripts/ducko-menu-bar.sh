#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"
ducko_require_vm_or_host_opt_in

"$SCRIPT_DIR/ducko-preferences.sh"
"$SCRIPT_DIR/ducko-preferences-tab.sh" General
"$SCRIPT_DIR/ducko-toggle-preference.sh" showInMenuBarToggle
