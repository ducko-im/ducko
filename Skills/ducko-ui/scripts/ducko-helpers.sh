#!/bin/bash
# Shared helper functions for ducko-ui automation scripts.
# Source this file: source "$SCRIPT_DIR/ducko-helpers.sh"
#
# AppleScript snippet generators output code for use inside a
# `tell process "DuckoUITest"` block. The calling script uses an unquoted
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

-- Searches only the sheets of a window, so a polling loop does not walk the contents of the window itself each time.
on findInSheets(win, identifierWanted)
    tell application "System Events"
        try
            repeat with s in sheets of win
                set found to my findByAttr(s, "AXIdentifier", identifierWanted, 0, 30)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findInSheets

-- A chat tab chip is a direct child of chat-tab-bar. Its id is "chat-tab-{jid}", account-qualified as
-- "chat-tab-{jid}|{account-jid}" when the JID is open under more than one account, so a bare JID matches the first.
on findChatTab(tabBar, jid)
    tell application "System Events"
        set tabId to "chat-tab-" & jid
        try
            repeat with c in (UI elements of tabBar)
                try
                    set elemId to value of attribute "AXIdentifier" of c
                    if elemId is tabId or elemId starts with (tabId & "|") then return contents of c
                end try
            end repeat
        end try
    end tell
    return missing value
end findChatTab

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

-- An element of the Preferences > Accounts row for accountJid, or of the first row when accountJid is "".
-- Rows carry the JID in their identifier, so a row showing a display name is found as well.
on findAccountRow(el, accountJid, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    set elemId to value of attribute "AXIdentifier" of c
                    if elemId is ("account-row-" & accountJid) or (accountJid is "" and elemId starts with "account-row-") then return c
                end try
                set found to my findAccountRow(c, accountJid, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findAccountRow

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

-- The static texts under root whose value holds msgText. An empty msgText matches every text with a value.
on messageTextsContaining(root, msgText)
    set matchingTexts to {}
    tell application "System Events"
        repeat with mt in (my collectStaticTexts(root, 0, 30))
            try
                if (value of mt) contains msgText then set end of matchingTexts to contents of mt
            end try
        end repeat
    end tell
    return matchingTexts
end messageTextsContaining

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

-- The identifiers under el that start with prefixWanted. An element that matches is not searched further, so the
-- children of a row cannot repeat the identifier of the row.
on collectIdentifiers(el, prefixWanted, depth, maxDepth)
    set acc to {}
    tell application "System Events"
        if depth > maxDepth then return acc
        try
            repeat with c in (UI elements of el)
                set matched to false
                try
                    set elemId to value of attribute "AXIdentifier" of c
                    if elemId starts with prefixWanted then
                        set end of acc to elemId
                        set matched to true
                    end if
                end try
                if not matched then set acc to acc & (my collectIdentifiers(c, prefixWanted, depth + 1, maxDepth))
            end repeat
        end try
    end tell
    return acc
end collectIdentifiers

-- The part of idText after prefixText, such as the JID in "room-row-{jid}".
on idSuffix(prefixText, idText)
    set idString to idText as text
    return text ((length of prefixText) + 1) thru -1 of idString
end idSuffix

-- How often textItem occurs in listItems.
on countOf(textItem, listItems)
    set occurrences to 0
    repeat with listItem in listItems
        if (contents of listItem) is textItem then set occurrences to occurrences + 1
    end repeat
    return occurrences
end countOf

-- Picks the room row a join produced from the matching room-row ids. An id repeats once per account that lists the
-- room. For a room JID, the pick is its row as soon as it is listed. For a bare name, it is a row listed more often
-- than before the submit, since a room joined already keeps its row. Once past the deadline, it is the one room
-- listed. Returns the row id, "" to keep waiting, "ambiguous" when several rooms of the name are listed, or "none".
on pickRoomRow(matchingRows, priorRows, isJid, pastDeadline)
    if isJid and (count of matchingRows) > 0 then return (item 1 of matchingRows) as text
    set distinctRows to {}
    repeat with rowId in matchingRows
        set rowText to (contents of rowId) as text
        if (not isJid) and ((my countOf(rowText, matchingRows)) > (my countOf(rowText, priorRows))) then return rowText
        if rowText is not in distinctRows then set end of distinctRows to rowText
    end repeat
    if not pastDeadline then return ""
    if (count of distinctRows) is 1 then return item 1 of distinctRows
    if (count of distinctRows) > 1 then return "ambiguous"
    return "none"
end pickRoomRow
EOF
}

# --- AppleScript snippet generators ---

# The identifier SwiftUI gives the Settings window, whose title follows the selected tab.
DUCKO_SETTINGS_SCENE="com_apple_SwiftUI_Settings_window"

# Find a window containing an element with the given AXIdentifier.
# Sets the AppleScript variable $var_name (default: targetWin).
# It reads bare `windows`, so emit it inside `tell process`.
# Args: identifier [error_msg] [var_name]
ducko_as_find_window_by_id() {
    local identifier="$1"
    local error_msg="${2:-window not found}"
    local var_name="${3:-targetWin}"
    cat << EOF
            set ${var_name} to missing value
            repeat with candidateWin in windows
                if (my findByAttr(candidateWin, "AXIdentifier", "${identifier}", 0, 30)) is not missing value then
                    set ${var_name} to candidateWin
                    exit repeat
                end if
            end repeat
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Stop unless the app is frontmost and the window is its main window, since keystrokes, menu shortcuts and the Escape
# that closes a context menu go to whatever window is key. Emit it inside `tell process`.
# Args: window_var window_description
ducko_as_require_front_window() {
    local window_var="$1"
    local window_description="$2"
    cat << EOF
            if not frontmost then return "ERROR: DuckoUITest is not the frontmost app"
            if (value of attribute "AXMain" of ${window_var}) is not true then return "ERROR: ${window_description} is not in front"
EOF
}

# Find a window by its scene id (such as `contacts` or `chat`), which is the window's own
# AXIdentifier. One Apple event per window, so it suits a polling loop, unlike
# ducko_as_find_window_by_id's walk of each window's contents.
# Sets the AppleScript variable $var_name (default: targetWin), or sets it to missing value when no window matches.
# Emit it inside `tell process`.
# Args: scene_id [var_name]
ducko_as_find_scene_window() {
    ducko_as_find_scene_window_expr "\"$1\"" "${2:-targetWin}"
}

# ducko_as_find_scene_window for a scene id held in an AppleScript expression, such as a variable name.
# The loop has its own variable, since a loop that matches nothing leaves its variable at the last window.
# Args: scene_expr [var_name]
ducko_as_find_scene_window_expr() {
    local scene_expr="$1"
    local var_name="${2:-targetWin}"
    cat << EOF
            set ${var_name} to missing value
            repeat with candidateWin in windows
                try
                    if (value of attribute "AXIdentifier" of candidateWin) is ${scene_expr} then
                        set ${var_name} to contents of candidateWin
                        exit repeat
                    end if
                end try
            end repeat
EOF
}

# Wait up to timeout seconds for a window with the given scene id. Emit it inside `tell process`.
# Args: scene_id timeout error_msg [var_name]
ducko_as_await_scene_window() {
    local scene_id="$1"
    local timeout="$2"
    local error_msg="$3"
    local var_name="${4:-targetWin}"
    cat << EOF
            set windowDeadline to (current date) + ${timeout}
            repeat
EOF
    ducko_as_find_scene_window "$scene_id" "$var_name"
    cat << EOF
                if ${var_name} is not missing value then exit repeat
                if (current date) > windowDeadline then return "ERROR: ${error_msg}"
                delay 0.3
            end repeat
EOF
}

# Find a window by its scene id and raise it, then find it again and require it in front. Emit it inside `tell process`.
# Args: scene_id [error_msg] [var_name] [raise_delay]
ducko_as_raise_scene_window() {
    local scene_id="$1"
    local error_msg="${2:-window not found}"
    local var_name="${3:-targetWin}"
    local raise_delay="${4:-0.3}"
    ducko_as_find_scene_window "$scene_id" "$var_name"
    cat << EOF
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
            perform action "AXRaise" of ${var_name}
            delay ${raise_delay}
EOF
    ducko_as_find_scene_window "$scene_id" "$var_name"
    echo "            if ${var_name} is missing value then return \"ERROR: ${error_msg}\""
    ducko_as_require_front_window "$var_name" "the ${scene_id} window"
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

# Wait up to timeout seconds for an element with the given AXIdentifier, searching the whole window, or only its
# sheets when scope is `sheets`. The id_expr is an AppleScript expression, as for ducko_as_find_element_by_id.
# A sheet lists its elements while it is still opening, and once open it gives the keyboard focus to its first text
# field. So with scope `sheets`, the wait looks again half a second after the element appears, and ends on the next
# look that finds it.
# A window found by its scene id is held by its title. For a window whose title can change during the wait, such as
# the chat window, pass scene_expr (an AppleScript expression such as '"chat"') to find the window again on each pass.
# window_var then holds the current window. Emit it inside `tell process` when passing scene_expr.
# Sets the AppleScript variable $var_name (default: targetElem).
# Args: id_expr window_var scope timeout error_msg [var_name] [scene_expr]
ducko_as_await_element() {
    local id_expr="$1"
    local window_var="$2"
    local scope="$3"
    local timeout="$4"
    local error_msg="$5"
    local var_name="${6:-targetElem}"
    local scene_expr="${7:-}"
    local lookup="my findByAttr(${window_var}, \"AXIdentifier\", ${id_expr}, 0, 30)"
    local found_step="if ${var_name} is not missing value then exit repeat"
    if [[ "$scope" == sheets ]]; then
        lookup="my findInSheets(${window_var}, ${id_expr})"
        found_step="if ${var_name} is not missing value then
                    if elementSettled then exit repeat
                    set elementSettled to true
                    delay 0.5
                else"
    fi
    echo "            set elementDeadline to (current date) + ${timeout}"
    [[ "$scope" == sheets ]] && echo "            set elementSettled to false"
    cat << EOF
            repeat
EOF
    if [[ -n "$scene_expr" ]]; then
        ducko_as_find_scene_window_expr "$scene_expr" "$window_var"
        cat << EOF
                set ${var_name} to missing value
                if ${window_var} is not missing value then set ${var_name} to ${lookup}
EOF
    else
        echo "                set ${var_name} to ${lookup}"
    fi
    cat << EOF
                ${found_step}
                if (current date) > elementDeadline then return "ERROR: ${error_msg}"
                delay 0.3
EOF
    [[ "$scope" == sheets ]] && echo "                end if"
    echo "            end repeat"
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

# Type a value into a text field found by AXIdentifier, replacing its contents.
# Keystrokes, unlike `set value`, reach the SwiftUI binding.
# The value_expr is an AppleScript expression, such as a variable name.
# Args: id_expr window_var value_expr [error_msg]
ducko_as_fill_field_by_id() {
    local id_expr="$1"
    local window_var="${2:-targetWin}"
    local value_expr="$3"
    local error_msg="${4:-field not found}"
    ducko_as_find_element_by_id "$id_expr" "$window_var" "$error_msg" "fillTarget"
    ducko_as_fill_element "fillTarget" "$value_expr"
}

# Type a value into a text field element, replacing its contents, or clear it for an empty value. Stops when the
# field does not take the keyboard focus within 2 seconds, which would send the keystrokes elsewhere. A field of a
# sheet that has just opened can take it only after the sheet has settled.
# Args: element_var value_expr
ducko_as_fill_element() {
    local element_var="$1"
    local value_expr="$2"
    cat << EOF
            set focused of ${element_var} to true
            set focusDeadline to (current date) + 2
            repeat
                delay 0.2
                if (focused of ${element_var}) is true then exit repeat
                if (current date) > focusDeadline then return "ERROR: the field did not take the keyboard focus"
                set focused of ${element_var} to true
            end repeat
            keystroke "a" using command down
            delay 0.1
            if ${value_expr} is "" then
                key code 51
            else
                keystroke ${value_expr}
            end if
            delay 0.3
EOF
}

# Wait up to 2 seconds until a text field element holds exactly the typed value. Not for secure fields, whose value
# is hidden.
# Args: element_var value_expr
ducko_as_await_field_value() {
    local element_var="$1"
    local value_expr="$2"
    cat << EOF
            set fieldDeadline to (current date) + 2
            repeat
                set fieldValue to ""
                try
                    set fieldValue to value of ${element_var}
                end try
                if fieldValue is missing value then set fieldValue to ""
                considering case
                    set fieldHoldsValue to (fieldValue is ${value_expr})
                end considering
                if fieldHoldsValue then exit repeat
                if (current date) > fieldDeadline then return "ERROR: the field does not hold the typed text"
                delay 0.2
            end repeat
EOF
}

# Wait for a sheet to close after its submit. Returns the sheet's error text when it shows one, and open_msg when the
# sheet is still open after the timeout. Falls through once the sheet's field is gone. The window is found by its
# scene id again on each pass, and a window that cannot be found is an error, not a closed sheet.
# Emit it inside `tell process`. field_id_expr and error_id_expr are AppleScript expressions, such as '"profile-error"'.
# Args: window_var scene_id field_id_expr error_id_expr timeout open_msg
ducko_as_await_sheet_closed() {
    local window_var="$1"
    local scene_id="$2"
    local field_id_expr="$3"
    local error_id_expr="$4"
    local timeout="$5"
    local open_msg="$6"
    cat << EOF
            set sheetDeadline to (current date) + ${timeout}
            repeat
                delay 0.5
EOF
    ducko_as_find_scene_window "$scene_id" "$window_var"
    cat << EOF
                if ${window_var} is missing value then return "ERROR: the ${scene_id} window is gone"
                set sheetError to my findInSheets(${window_var}, ${error_id_expr})
                if sheetError is not missing value then
                    set sheetErrorText to "the sheet shows an error"
                    try
                        set sheetErrorText to (value of sheetError) as text
                    end try
                    return "ERROR: " & sheetErrorText
                end if
                if (my findInSheets(${window_var}, ${field_id_expr})) is missing value then exit repeat
                if (current date) > sheetDeadline then return "ERROR: ${open_msg}"
            end repeat
EOF
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
            set msgTexts to my messageTextsContaining(msgRoot, ${search_text_var})
            if (count of msgTexts) is 0 then return "ERROR: ${error_msg}"
            if ${search_text_var} is "" then
                set ${var_name} to item -1 of msgTexts
            else
                set ${var_name} to item 1 of msgTexts
            end if
EOF
}

# Open an element's menu (a right-click context menu or a SwiftUI `Menu`
# pull-down) and select a named menu item. AXShowMenu returns success without
# opening the menu on a control that does not advertise it, such as a `Menu`
# inside a grouped `Form`.
# The transient SwiftUI menu may render at process level (a sibling of the
# windows) or under the window, so search the process's menus first, then fall
# back to walking the window subtree. A missing or greyed-out item keys Escape
# while the app is still frontmost, so the open menu can't swallow later
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

# Select an account in Preferences > Accounts. The account_expr is an
# AppleScript expression for its JID, such as a variable name, or "" for the
# first account. Emit it inside `tell application "System Events"`, not inside
# `tell process`.
# Sets the AppleScript variable prefsWin to the Preferences window.
# Args: [account_expr]
ducko_as_select_account_row() {
    local account_expr="${1:-\"\"}"
    cat << EOF
            set prefsWin to missing value
            repeat with win in (windows of process "DuckoUITest")
                set acctRow to my findAccountRow(win, ${account_expr}, 0, 30)
                if acctRow is not missing value then
                    set prefsWin to contents of win
                    exit repeat
                end if
            end repeat
            if prefsWin is missing value then return "ERROR: account row not found"
$(ducko_as_select_table_row acctRow "could not select the account row")
            delay 0.4
EOF
}

# Select the first account in Preferences > Accounts and click an item of its
# Actions pull-down, which only appears once the account is connected. Emit it
# inside `tell application "System Events"`, not inside `tell process`.
# Sets the AppleScript variable prefsWin to the Preferences window.
# Args: menu_item_name [error_msg]
ducko_as_click_account_action() {
    local menu_item_name="$1"
    local error_msg="${2:-}"
    ducko_as_select_account_row
    cat << EOF
            -- A SwiftUI Menu bridges as a menu/pop-up button, not AXButton, so match by identifier alone.
            set actionsMenu to my findByAttr(prefsWin, "AXIdentifier", "account-actions-menu", 0, 30)
            if actionsMenu is missing value then return "ERROR: Actions menu not found (is an account row selected and connected?)"
            tell process "DuckoUITest"
EOF
    ducko_as_click_context_menu_item "$menu_item_name" actionsMenu prefsWin "$error_msg" continue
    echo "            end tell"
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

# Wait for a Connect or Register press in the Welcome window or its registration sheet to settle. Returns "ok" once
# the window has closed, since the account is then signed in, or the error the window shows. With form_shown_result,
# returns that once the sheet shows the server's registration form. Without it, also returns the error the sheet
# shows, such as the server's refusal. Returns fail_msg when none of these happens within 30 seconds.
# Args: proc_var window_var [form_shown_result] [fail_msg]
ducko_as_await_welcome_outcome() {
    local proc_var="$1"
    local window_var="$2"
    local form_shown_result="${3:-}"
    local fail_msg="${4:-the registration did not finish}"
    cat << EOF
        set deadline to (current date) + 30
        repeat until (current date) > deadline
            delay 0.5
            if not (exists window "Welcome" of ${proc_var}) then return "ok"
            set errorText to my findByAttr(${window_var}, "AXIdentifier", "setup-error", 0, 30)
            if errorText is not missing value then return "ERROR: " & (value of errorText)
EOF
    if [[ -n "$form_shown_result" ]]; then
        echo "            if (my findByAttr(${window_var}, \"AXIdentifier\", \"register-server-form\", 0, 30)) is not missing value then return \"${form_shown_result}\""
    else
        echo "            set formError to my findInSheets(${window_var}, \"register-server-form-error\")"
        echo "            if formError is not missing value then return \"ERROR: \" & (value of formError)"
    fi
    cat << EOF
        end repeat
        return "ERROR: ${fail_msg}"
EOF
}

# --- Bash utility functions ---

# Stop unless this runs in a VM (the Lume VM) or DUCKO_UI_HOST=1 says the user asked for a run on this Mac.
# On the Mac the scripts bring windows to the front and type into whatever app is frontmost.
ducko_require_vm_or_host_opt_in() {
    if [[ "${DUCKO_UI_HOST:-}" == 1 || "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" == 1 ]]; then
        return
    fi
    echo "ERROR: ducko-ui scripts run in the Lume VM (zsh Skills/lume-vm/scripts/vm.sh ui <script>). Set DUCKO_UI_HOST=1 only when the user asked for a run on this Mac." >&2
    exit 1
}

# Stop unless this runs in a VM (the Lume VM), whatever DUCKO_UI_HOST says, for a script that writes the current
# user's real data folders.
ducko_require_vm() {
    if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" == 1 ]]; then
        return
    fi
    echo "ERROR: this script writes the current user's real data folders, so it runs only in the Lume VM (zsh Skills/lume-vm/scripts/vm.sh ui <script>), even with DUCKO_UI_HOST=1." >&2
    exit 1
}

# Print the text without surrounding whitespace and line breaks, as the app trims a typed status message or topic.
# Args: text
ducko_trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# Print the status menu label for a status key (available, away, xa, dnd, offline), or fail for any other key.
# Args: status
ducko_status_label() {
    case "$1" in
        available) echo "Available" ;;
        away)      echo "Away" ;;
        xa)        echo "Extended Away" ;;
        dnd)       echo "Do Not Disturb" ;;
        offline)   echo "Offline" ;;
        *)         echo "ERROR: unknown status: $1" >&2; return 1 ;;
    esac
}

# Print this checkout's root, with symlinks resolved so it matches a running copy's command line.
ducko_repo_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")" && cd "$(pwd -P)/../../.." && pwd)
}

# Print the bundle path of this checkout's DuckoUITest copy.
ducko_copy_path() {
    echo "$(ducko_repo_root)/.build/ducko-ui/DuckoUITest.app"
}

# Print the PID of the test copy: DUCKO_PID when set, else the single running DuckoUITest.
ducko_app_pid() {
    local pid="${DUCKO_PID:-}"
    if [[ -z "$pid" ]]; then
        pid=$(pgrep -x DuckoUITest || true)
    fi
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "ERROR: expected one DuckoUITest process; set DUCKO_PID to the instance to drive" >&2
        exit 1
    fi
    echo "$pid"
}

# Refuse destructive automation while more than one DuckoUITest runs, for example copies from two checkouts:
# `process "DuckoUITest"` resolves to an arbitrary one of them.
ducko_require_single_app() {
    local pids
    pids=$(pgrep -x DuckoUITest || true)
    # pgrep prints one PID per line, so a newline means more than one instance.
    if [[ "$pids" == *$'\n'* ]]; then
        echo "ERROR: more than one DuckoUITest process is running; quit all but the one to drive" >&2
        exit 1
    fi
}

# Fill the Open panel a script just opened with a path and wait for it to close. Stops with the AppleScript result
# when opening the panel failed, and with the panel helper's error otherwise.
# Args: result path
ducko_fill_open_panel() {
    local result="$1"
    local path="$2"
    local pid
    if [[ "$result" != ok ]]; then
        echo "$result" >&2
        exit 1
    fi
    pid=$(ducko_app_pid) || exit 1
    swift "$(dirname "${BASH_SOURCE[0]}")/ducko-file-panel.swift" "$pid" "$path" || exit 1
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
