#!/bin/bash
# Shared helper functions for ducko-ui automation scripts.
# Source this file: source "$SCRIPT_DIR/ducko-helpers.sh"
#
# AppleScript snippet generators output code for use inside a
# `tell process "DuckoApp"` block. The calling script uses an unquoted
# heredoc (<< APPLESCRIPT) so that $() expansions are evaluated by the shell.
#
# The element-finding snippets call recursive `my findByAttr` /
# `my findByRoleAndName` / `my collectStaticTexts` handlers instead of
# `entire contents`, which silently truncates the deeply-nested SwiftUI /
# NSTableView accessibility trees on macOS 26 (contact/room rows, Welcome
# fields, chat transcript). Each osascript block that uses these snippets must
# emit `$(ducko_as_handlers)` at its top level (before `on run`) so the
# handlers are defined — a block missing them fails with "handler not defined".

# --- AppleScript top-level handler definitions ---

# Recursive UI-element-tree handlers, defined at script top level (handlers
# cannot live inside a `tell process` block). Emit once per osascript block.
ducko_as_handlers() {
    cat << 'EOF'
on findByAttr(el, attrName, attrValue, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (value of attribute attrName of c) is attrValue then return c
                end try
                set found to my findByAttr(c, attrName, attrValue, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByAttr

on findByRoleAndName(el, roleWanted, nameWanted, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is roleWanted and (name of c) is nameWanted then return c
                end try
                set found to my findByRoleAndName(c, roleWanted, nameWanted, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByRoleAndName

-- Matches a button by its title, falling back to AXDescription when the title is empty (confirmation dialog
-- buttons carry their label only there).
on findButtonByLabel(el, labelWanted, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is "AXButton" then
                        set buttonLabel to missing value
                        try
                            set buttonLabel to value of attribute "AXTitle" of c
                        end try
                        if buttonLabel is missing value or buttonLabel is "" then set buttonLabel to value of attribute "AXDescription" of c
                        if buttonLabel is labelWanted then return c
                    end if
                end try
                set found to my findButtonByLabel(c, labelWanted, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findButtonByLabel

on collectStaticTexts(el, depth, maxDepth)
    set acc to {}
    tell application "System Events"
        if depth > maxDepth then return acc
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is "AXStaticText" then set end of acc to (contents of c)
                end try
                set acc to acc & (my collectStaticTexts(c, depth + 1, maxDepth))
            end repeat
        end try
    end tell
    return acc
end collectStaticTexts

on collectByRole(el, roleWanted, depth, maxDepth)
    set acc to {}
    tell application "System Events"
        if depth > maxDepth then return acc
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is roleWanted then set end of acc to (contents of c)
                end try
                set acc to acc & (my collectByRole(c, roleWanted, depth + 1, maxDepth))
            end repeat
        end try
    end tell
    return acc
end collectByRole
EOF
}

# --- AppleScript snippet generators ---

# Find a window containing an element with the given AXIdentifier.
# Sets the AppleScript variable $var_name (default: targetWin).
# Args: identifier [error_msg] [var_name]
ducko_as_find_window_by_id() {
    local identifier="$1"
    local error_msg="${2:-window not found}"
    local var_name="${3:-targetWin}"
    cat << EOF
            set ${var_name} to missing value
            repeat with win in windows
                if (my findByAttr(win, "AXIdentifier", "${identifier}", 0, 30)) is not missing value then
                    set ${var_name} to win
                    exit repeat
                end if
            end repeat
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Find a window containing an element with the given AXIdentifier and raise it.
# System Events window references are positional, so the raise can re-point
# the variable at another window; the window is found again afterwards.
# Args: identifier [error_msg] [var_name] [raise_delay]
ducko_as_raise_window_by_id() {
    local identifier="$1"
    local error_msg="${2:-window not found}"
    local var_name="${3:-targetWin}"
    local raise_delay="${4:-0.3}"
    ducko_as_find_window_by_id "$identifier" "$error_msg" "$var_name"
    cat << EOF
            perform action "AXRaise" of ${var_name}
            delay ${raise_delay}
EOF
    ducko_as_find_window_by_id "$identifier" "$error_msg" "$var_name"
}

# Find an element by AXIdentifier within a window variable.
# The id_expr is an AppleScript expression: a quoted string like "\"foo\""
# or a variable name like targetId.
# Sets the AppleScript variable $var_name (default: targetElem).
# Args: id_expr window_var [error_msg] [var_name]
ducko_as_find_element_by_id() {
    local id_expr="$1"
    local window_var="${2:-targetWin}"
    local error_msg="${3:-element not found}"
    local var_name="${4:-targetElem}"
    cat << EOF
            set ${var_name} to my findByAttr(${window_var}, "AXIdentifier", ${id_expr}, 0, 30)
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Click an element found by AXIdentifier. Combines find + click.
# Args: id_expr window_var [error_msg]
ducko_as_click_element_by_id() {
    local id_expr="$1"
    local window_var="${2:-targetWin}"
    local error_msg="${3:-button not found}"
    ducko_as_find_element_by_id "$id_expr" "$window_var" "$error_msg" "clickTarget"
    echo "            click clickTarget"
}

# Find a message by text content within a window variable.
# Searches AXStaticText elements, scoped to the transcript (message-list) when
# present to bound the walk. If search_text_var is empty, selects the last
# message; otherwise the first message whose text contains search_text_var.
# Sets the AppleScript variable $var_name (default: targetElem).
# Args: search_text_var [window_var] [error_msg] [var_name]
ducko_as_find_message_by_text() {
    local search_text_var="$1"
    local window_var="${2:-chatWin}"
    local error_msg="${3:-no matching message found}"
    local var_name="${4:-targetElem}"
    cat << EOF
            set msgRoot to my findByAttr(${window_var}, "AXIdentifier", "message-list", 0, 30)
            if msgRoot is missing value then set msgRoot to ${window_var}
            set msgTexts to my collectStaticTexts(msgRoot, 0, 30)
            set ${var_name} to missing value
            if ${search_text_var} is "" then
                if (count of msgTexts) > 0 then set ${var_name} to item -1 of msgTexts
            else
                repeat with mt in msgTexts
                    try
                        if (value of mt) contains ${search_text_var} then
                            set ${var_name} to contents of mt
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Open an element's menu (a right-click context menu or a SwiftUI `Menu`
# pull-down) and select a named menu item. AXShowMenu returns success without
# opening the menu on a control that does not advertise it, such as a `Menu`
# inside a grouped `Form`.
# The transient SwiftUI menu may render at process level (a sibling of the
# windows) or under the window, so search the process's menus first, then fall
# back to walking the window subtree. A missing or greyed-out item keys Escape
# while DuckoApp is still frontmost, so the open menu can't swallow later
# scripts' input.
# Args: menu_item_name source_var [window_var] [error_msg] [on_success]
ducko_as_click_context_menu_item() {
    local menu_item_name="$1"
    local source_var="${2:-targetElem}"
    local window_var="${3:-targetWin}"
    local error_msg="${4:-${menu_item_name} menu item not found}"
    local on_success="${5:-return}"
    cat << EOF
            if "AXShowMenu" is in (name of actions of ${source_var}) then
                perform action "AXShowMenu" of ${source_var}
            else
                perform action "AXPress" of ${source_var}
            end if
            delay 0.5
            set menuItem to missing value
            repeat with m in menus
                set menuItem to my findByRoleAndName(m, "AXMenuItem", "${menu_item_name}", 0, 8)
                if menuItem is not missing value then exit repeat
            end repeat
            if menuItem is missing value then set menuItem to my findByRoleAndName(${window_var}, "AXMenuItem", "${menu_item_name}", 0, 30)
            if menuItem is missing value then
                if frontmost then key code 53
                return "ERROR: ${error_msg}"
            end if
            -- A click on a greyed-out item does nothing and reports no error.
            if not (enabled of menuItem) then
                if frontmost then key code 53
                return "ERROR: ${error_msg}"
            end if
            click menuItem
EOF
    if [[ "$on_success" == return ]]; then
        echo '            return "ok"'
    fi
}

# Select the table row enclosing an element. A System Events `click` on a
# combined SwiftUI row element is an AX press, which does not change the
# NSTableView selection. Walk up to the AXRow and set it selected instead.
# Args: element_var [error_msg]
ducko_as_select_table_row() {
    local element_var="${1:-targetElem}"
    local error_msg="${2:-table row not found}"
    cat << EOF
            set rowElem to ${element_var}
            try
                repeat until (role of rowElem) is "AXRow"
                    set rowElem to value of attribute "AXParent" of rowElem
                end repeat
                set value of attribute "AXSelected" of rowElem to true
            on error
                return "ERROR: ${error_msg}"
            end try
            delay 0.3
            if (value of attribute "AXSelected" of rowElem) is not true then return "ERROR: ${error_msg}"
EOF
}

# Click a button by its label (title, or AXDescription when untitled) anywhere
# in a window, including its attached sheets (e.g. a confirmation dialog's
# destructive button).
# Args: button_label window_var [error_msg]
ducko_as_click_button_by_label() {
    local button_label="$1"
    local window_var="${2:-targetWin}"
    local error_msg="${3:-${button_label} button not found}"
    cat << EOF
            delay 0.5
            set labeledButton to my findButtonByLabel(${window_var}, "${button_label}", 0, 30)
            if labeledButton is missing value then return "ERROR: ${error_msg}"
            click labeledButton
EOF
}

# Navigate a file picker via Cmd+Shift+G.
# The path_var is an AppleScript variable name holding the file path.
# Args: path_var
ducko_as_navigate_file_picker() {
    local path_var="$1"
    cat << EOF
            delay 1.5
            keystroke "g" using {command down, shift down}
            delay 1
            keystroke ${path_var}
            delay 0.5
            keystroke return
            delay 1
            keystroke return
            delay 2
EOF
}

# --- Bash utility functions ---

# Refuse destructive automation while more than one DuckoApp runs: `process "DuckoApp"` resolves to an arbitrary
# instance, which may be an installed production app.
ducko_require_single_app() {
    local pids
    pids=$(pgrep -x DuckoApp || true)
    # pgrep prints one PID per line, so a newline means more than one instance.
    if [[ "$pids" == *$'\n'* ]]; then
        echo "ERROR: more than one DuckoApp process is running; quit all but the one to drive" >&2
        exit 1
    fi
}

# Standard result handler. Prints success message or error and exits.
# Args: result success_msg
ducko_check_result() {
    local result="$1"
    local success_msg="$2"
    if [[ "$result" == ok ]]; then
        echo "$success_msg"
    else
        echo "$result" >&2
        exit 1
    fi
}
