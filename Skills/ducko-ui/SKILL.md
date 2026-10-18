---
name: ducko-ui
description: "End-to-end UI testing for the Ducko macOS app using pre-built helper scripts, run in the Lume VM so the user's Mac is not disturbed. This skill should be used when the user asks to \"test ducko\", \"test the app\", \"run E2E tests\", \"test the app end-to-end\", \"test the UI\", \"send a test message\", or wants to verify DuckoApp works from login through messaging."
---

# Ducko UI Test

Run the `/macos-ui-testing` skill first to load generic macOS UI automation patterns. This skill provides Ducko-specific helper scripts on top.

The scripts can be allowlisted in `settings.local.json` (see Permission Allowlisting at the end).

## Window Architecture

DuckoApp ships separate windows:

- **Contact List** (`id: "contacts"`) — singleton, main window after login (roster, status picker, search).
- **Chat** (`id: "chat"`) — singleton tabbed window holding every open conversation as a bottom tab (`chat-tab-bar`). Double-click or New Chat opens or raises it. A roster contact's message or file offer also opens it behind the window the user is in, without taking focus, and adds a tab for that chat without selecting it. A muted chat is left alone. Switching tabs preserves each conversation's draft, search, and sidebar state.
- **Contact Info** (`id: "contact-info"`, keyed by `ContactInfoRef`) — Get Info window: identity, roster/subscription state, vCard, and Block/Remove. Opened from the chat header (i) button, a contact's "Get Info" context item, or Contact ▸ Get Info (⌘⇧I).
- **Chat History** (`id: "transcripts"`) — singleton history window. File ▸ Chat History (⌥⌘T) opens it with the first account selected. The header clock, a contact's "History" context item, and Contact ▸ History (⌘L) retarget it to that conversation. Its title is the name of the conversation whose messages it shows, and "Chat History" while it shows none, so find it by the window's own accessibility identifier, `transcripts`.
- **MenuBarExtra** — quick status, Show Contact List, Quit.

The Chat History window has three parts. A left list holds accounts and imported histories with their conversations, under a "Filter conversations" field that narrows its rows. A day list holds the days of what is selected there, and the message pane shows the selected day. The rows of the two lists carry no identifiers. The toolbar search field searches all conversations and lists the days with matches in the day list. ⌥⌘F (Edit ▸ Search All Conversations) puts the cursor in that field. ⌘F (Edit ▸ Find…) shows and hides a find bar above the messages, which steps through the matches of the listed days.

The Chat window's tabs survive a relaunch, in their order and with the same tab selected. The window itself reopens at launch only when it was open at quit. Otherwise it stays closed, and the tabs come back once a chat is next opened. `ducko-stop.sh` followed by `ducko-launch.sh` is such a relaunch. A test run can therefore start with tabs from an earlier run, and incoming messages can add tabs it did not open. A restored chat window opens in front of Contacts, which leaves the Contacts-only menu commands (Join Room…, Bookmarks…, Add Contact…) disabled, so run `ducko-focus-contacts.sh` after `ducko-launch.sh` before any Contacts step.

A room joined through the Join Room sheet, an accepted invitation or the REPL's `/join` is joined again on every connect until Leave Room, `/leave`, or being kicked or banned. A profile that ended a run inside a room therefore starts the next one in it. To end a run clean, run `ducko-leave-room.sh` for each joined room and `ducko-chat-tabs.sh close-all` before `ducko-stop.sh`.

The Contacts window has **no toolbar**. Its actions live in the app menu bar. File holds New Chat (⌘N), Join Room… (⌘⇧N), Bookmarks… (⌘⇧B) and Close All Chats (⌥⌘W). The Contact menu holds Add Contact… (⌘D) and My Profile…. Its Get Info (⌘⇧I), History (⌘L) and Send File… (⌘⇧F) act on the selected Contacts row or the active chat, while Remove Contact… (⌘⌫) acts only on the selected Contacts row. The Status menu sets presence (⌘⇧Y Available, ⌘Y toggle, Custom…). View holds sort order and Hide Offline (⌘⇧H). Window holds Show/Hide Contact List (⌘/) and chat tab cycling (⌃⇥/⌃⇧⇥). `⌘F` reveals the roster search field (`contact-search-field`). Scripts drive these via keyboard shortcuts or menu-bar clicks (`menu bar item ... of menu bar 1`), not window buttons.

## Prerequisites

The scripts run in the Lume VM (the `/lume-vm` skill) by default. Start it with `zsh Skills/lume-vm/scripts/vm.sh start`, then run each script from the host as `zsh Skills/lume-vm/scripts/vm.sh ui <script> [args]`. Run `vm.sh` outside the Bash sandbox. Every call first copies the working tree into the VM, so edits made mid-session take effect, and it passes `DUCKO_PROFILE` through when set. When `vm.sh` reports that the VM serves another checkout, another session holds it: wait or ask the user, and never fall back to the Mac.

The scripts drive a copy of the debug app named `DuckoUITest`, which `ducko-launch.sh` builds and launches. Without a `DUCKO_PROFILE` the copy runs under the profile `uitest` (`Ducko-Dev-uitest`, `im.ducko.dev.uitest`), so it never shares a store with a debug Ducko on the default profile. Seed that profile's account with the copy's own CLI, after a first `ducko-launch.sh` has built it: `zsh Skills/lume-vm/scripts/vm.sh gui 'DUCKO_PROFILE=uitest /Users/lume/work/ducko/.build/ducko-ui/DuckoUITest.app/Contents/Resources/ducko account add …'`.

Run a script on the Mac only when the user asks for that, with `DUCKO_UI_HOST=1` in its environment. Without it, every script stops with an error before touching any app. On the Mac the scripts still drive only the `DuckoUITest` copy, so an installed Ducko keeps running. The copy does take the foreground, though. A Mac run needs:

- Peekaboo CLI installed (`/opt/homebrew/bin/peekaboo`), for `ducko-reveal.sh`
- Accessibility permissions granted for Terminal/Claude
- An unlocked GUI session. Check with `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`, run unsandboxed: `<true/>` means locked and no output means unlocked (a sandboxed `ioreg` also prints nothing). While locked, window captures fail and the scripts report windows as not found, so ask the user to unlock rather than polling.

## Scripts

All scripts are in `scripts/` relative to this skill. Run from the repo root or use absolute paths.

Scripts target SwiftUI accessibility identifiers, not positional selectors.

### Accessibility Identifiers

A row whose window is "Menu bar" or "Contacts (menu bar)" names a menu-bar item. Find such an item by its menu and title: menu-bar commands do not expose their identifiers to accessibility.

| Identifier | Element | Window |
|---|---|---|
| `contact-list` | Contact list view | Contacts |
| `contact-row-{jid}` | Individual contact row (account-qualified as `contact-row-{jid}\|{account-jid}` when the JID is on more than one account). Its leading slot shows an unread count (capped at 9+), else a typing bubble while the contact types, else the presence dot. Its accessibility value reads "N unread message(s)" or "Typing", and is empty otherwise. Its label, in the description attribute (the title is unsupported), contains its name and caption, so read it title-then-description, as `AppAccessor.label(identifier:)` does, not from the value. With Hide Offline Contacts on, an offline contact with unread messages keeps its row. | Contacts |
| `status-picker` | Presence status pull-down in the "me" header, listing status rows with colored dots, saved statuses, and Custom…. With 2+ enabled accounts, the status and saved-status rows sit under an "All Accounts" heading, followed by one submenu per account under "Each Account". SwiftUI exposes no identifiers on those submenus or their rows, so address both by title (the account's display name, else its JID). Its value is the header account's message, or its status when no message is set, followed by counts of the accounts showing another status (e.g. `Available · 1 Offline`) | Contacts |
| `custom-status-message-field` | Message field in the Custom Status sheet (status pull-down or Status menu "Custom…" / "Custom Away…") | Contacts |
| `identity-switcher` | Identity (account) switcher menu on the "me" header name, shown with 2+ enabled accounts | Contacts |
| `my-avatar` | Self avatar in the "me" header | Contacts |
| `status-preferences` | Saved-status management list in Preferences ▸ Status | Preferences |
| `saved-status-message-field` | Message field in the Preferences ▸ Status add sheet | Preferences |
| `contact-search-field` | Roster search field, revealed by ⌘F | Contacts |
| `message-field` | Message input text field | Chat |
| `send-button` | Send message button | Chat |
| `new-chat-jid-field` | JID field in New Chat sheet | Contacts |
| `new-chat-account-picker` | Account picker in New Chat sheet (shown only when more than one account is enabled) | Contacts |
| `start-chat-button` | Start Chat button in sheet | Contacts |
| `add-contact-jid-field` | JID field in Add Contact sheet | Contacts |
| `add-contact-error` | Rejected or unconfirmed contact-change error, kept in the sheet | Contacts |
| `add-contact-button` | Add Contact button in sheet | Contacts |
| `rename-contact-field` | Display-name field in the Rename Contact sheet | Contacts |
| `rename-contact-button` | Save button in the Rename Contact sheet | Contacts |
| `jid-field` | JID field in account setup | Contacts |
| `password-field` | Password field in account setup | Contacts |
| `connect-button` | Connect button in account setup | Contacts |
| `reply-compose-bar` | Reply/edit compose bar above input | Chat |
| `message-search-bar` | Cmd+F find bar above the messages. With matches it shows Previous Match and Next Match buttons and a match count. The count reads `2/7`, the current match's number and the total, or the total alone while no match is current | Chat, Chat History |
| `edit-menu-search-all-conversations` | Edit ▸ Search All Conversations (⌥⌘F): puts the cursor in the Chat History window's toolbar search field. Enabled only while that window is focused | Menu bar |
| `sort-mode-menu` | "Sort Contacts" picker, in the View menu bar | Contacts (menu bar) |
| `hide-offline-menu` | "Hide Offline Contacts" toggle (⌘⇧H), in the View menu bar | Contacts (menu bar) |
| `status-menu-{status}` | Status menu row (`available` ⌘⇧Y, `away`, `xa`, `dnd`, `offline`), applied to every enabled account. It carries a checkmark when every enabled account shows that status and a dash when only some do. With 2+ enabled accounts, the rows sit under "All Accounts", followed by the per-account submenus under "Each Account" (addressed by title) | Menu bar |
| `status-menu-toggle` | Status menu ⌘Y item: "Custom Away…" when the header account is Available (opens the Custom Status sheet on Contacts), "Available" for every enabled account otherwise | Menu bar |
| `status-menu-custom` | Status menu "Custom…" item, opening the Custom Status sheet on Contacts | Menu bar |
| `contacts-window-menu` | Window ▸ Hide Contact List / Show Contact List (⌘/): closes the Contacts window when focused, otherwise opens and raises it | Menu bar |
| `next-tab-menu` | Window ▸ Select Next Tab (⌃⇥), wrapping. ⌘⇧] does the same inside the chat window | Menu bar |
| `previous-tab-menu` | Window ▸ Select Previous Tab (⌃⇧⇥), wrapping. ⌘⇧[ does the same inside the chat window | Menu bar |
| `close-all-chats-menu` | File ▸ Close All Chats (⌥⌘W): closes every tab and the chat window | Menu bar |
| `contact-menu-get-info` | Contact ▸ Get Info (⌘⇧I) for the selected Contacts row or the active chat (1:1 contacts only) | Menu bar |
| `contact-menu-history` | Contact ▸ History (⌘L) for the selected Contacts row or the active chat | Menu bar |
| `contact-menu-send-file` | Contact ▸ Send File… (⌘⇧F): opens the chat's file picker (from Contacts, opens the chat first) | Menu bar |
| `contact-menu-remove` | Contact ▸ Remove Contact… (⌘⌫) for the selected contact, with confirmation | Menu bar |
| `room-row-{jid}` | Room row in Rooms section. Its leading slot shows the unread count (capped at 9+), else a green dot when joined or a gray ring when not. Its accessibility value reads "N unread message(s)", and is empty otherwise. Its label contains its name and, when shown, its subject or participant count, read the same way as a contact row's. | Contacts |
| `room-invite-banner` | Pending room invitation banner | Contacts |
| `room-jid-field` | Room JID field in Join Room dialog | Contacts |
| `room-nickname-field` | Nickname field in Join Room dialog | Contacts |
| `join-room-button` | Join button in Join Room dialog | Contacts |
| `browse-rooms-button` | Browse Rooms button in Join Room dialog | Contacts |
| `invite-user-jid-field` | JID field in the Invite User sheet | Contacts |
| `invite-user-reason-field` | Reason field in the Invite User sheet | Contacts |
| `invite-user-button` | Invite button in the Invite User sheet | Contacts |
| `room-subject-view` | Room topic banner (editable) | Chat |
| `participant-sidebar` | Participant sidebar list | Chat |
| `participant-row-{nickname}` | Participant row in the participant sidebar. Right-clicking it opens the participant's context menu. Its nickname text is a separate element inside it. | Chat (sidebar) |
| `toggle-participant-sidebar` | Sidebar toggle button (person.2 icon) | Chat |
| `send-pm-menu-item` | "Send Private Message" context menu item on a MUC participant | Chat (sidebar) |
| `send-directed-presence-menu-item` | "Send Directed Presence" context menu item on a contact | Contacts |
| `attachment-button` | Paperclip file picker button | Chat |
| `pending-attachments` | Pending attachment bar above input | Chat |
| `attachment-send-method` | Pop-up at the end of the pending attachment bar of a 1:1 chat, choosing Upload or Send Directly. Send Directly is greyed out unless the contact is online with a device that takes direct transfers. | Chat |
| `attachment-encryption-note` | "Not end-to-end encrypted" at the end of the pending attachment bar, beneath the pop-up where there is one, while files are queued in a chat with encryption on. Its accessibility label reads "Files are not end-to-end encrypted". | Chat |
| `direct-transfer-status` | Status line under a file sent directly (waiting for the contact to accept, sending, sent directly, or the reason it failed) or under a file being received | Chat |
| `transfer-progress` | Progress strip for a file being uploaded. A file sent directly reports on its own row through `direct-transfer-status`, and one being received on a `receiving-file-row`. | Chat |
| `receiving-file-row` | Row at the end of the message list for a file the chat's contact is sending right now, shown like one of their messages with "Receiving…" under it until the saved file's message replaces it | Chat |
| `file-drop-overlay` | Drag-and-drop overlay | Chat |
| `attachment-view` | Attachment in message bubble | Chat |
| `attachment-preview-button` | File attachment card that opens the system Quick Look panel. Absent for a file not saved on this Mac. | Chat |
| `attachment-reveal-button` | Reveal-in-Finder button on a saved file attachment, shown on hover | Chat |
| `attachment-open-button` | Open button on a remote (HTTP) file attachment | Chat |
| `attachment-load-image` | Click-to-load placeholder for a remote image, showing the file name. Absent where the image loads on sight: your own messages, and a roster contact's messages in a 1:1 chat. Tapping it loads the image inline. | Chat |
| `image-preview` | Full-size image preview sheet | Chat |
| `link-preview` | Link preview card in message bubble | Chat |
| `code-block` | Text of a code block in a message bubble: code that fills whole lines, drawn in its own box. Its "Copy Code" accessibility action copies the code without hovering. | Chat |
| `code-block-copy-button` | Copy button of a code block, present only while the pointer is over the block | Chat |
| `room-settings-menu-item` | "Room Settings…" context menu item | Contacts |
| `room-settings-view` | Room settings sheet (tabs + destroy) | Room Settings |
| `room-settings-destroy` | Destroy Room button | Room Settings |
| `room-config-view` | Room config form (General tab) | Room Settings |
| `affiliation-list-view` | Affiliation list (Members tab) | Room Settings |
| `affiliation-jid-field` | JID input for adding affiliation | Room Settings |
| `affiliation-add-button` | Add affiliation button | Room Settings |
| `change-nickname-menu-item` | "Change Nickname…" on self in sidebar | Chat (sidebar) |
| `change-nickname-field` | Nickname text field in change alert | Chat (sidebar) |
| `profile-edit-view` | Profile editing sheet | Contacts |
| `profile-fullname-field` | Full Name text field | Profile |
| `profile-nickname-field` | Nickname text field | Profile |
| `profile-given-name-field` | Given Name text field | Profile |
| `profile-family-name-field` | Family Name text field | Profile |
| `profile-email-field-{index}` | Email text field (0-indexed) | Profile |
| `profile-phone-field-{index}` | Phone text field (0-indexed) | Profile |
| `profile-org-field` | Organization text field | Profile |
| `profile-title-field` | Title text field | Profile |
| `profile-avatar-preview` | Avatar preview image/initials | Profile |
| `profile-change-photo-button` | Change Photo button | Profile |
| `profile-remove-photo-button` | Remove Photo button | Profile |
| `profile-save-button` | Save button | Profile |
| `profile-cancel-button` | Cancel button | Profile |
| `bookmark-row-{jid}` | Individual bookmark row | Bookmarks |
| `add-bookmark-button` | Add Bookmark toolbar button | Bookmarks |
| `bookmark-jid-field` | Room JID field in Add Bookmark sheet | Bookmarks |
| `bookmark-nickname-field` | Nickname field in Add Bookmark sheet | Bookmarks |
| `bookmark-autojoin-toggle` | Auto-join toggle in Add Bookmark sheet | Bookmarks |
| `add-bookmark-confirm-button` | Add button in Add Bookmark sheet | Bookmarks |
| `remove-bookmark-button` | Remove bookmark button (per row) | Bookmarks |
| `preferences-window` | Preferences TabView container | Preferences |
| `showInMenuBarToggle` | Show Ducko in Menu Bar toggle | Preferences (General) |
| `chatStatesToggle` | Chat states (typing indicators) toggle | Preferences (Chat) |
| `displayedMarkersToggle` | Displayed markers (read receipts) toggle | Preferences (Chat) |
| `contacts-compact-toggle` | Compact rows toggle (contact-list rows without avatars and captions) | Preferences (Appearance) |
| `requireTLSToggle` | Require TLS toggle | Account Edit |
| `tlsVersion` | TLS Version label | Connection Info |
| `cipherSuite` | Cipher Suite label | Connection Info |
| `certSubject` | Certificate Subject label | Connection Info |
| `certIssuer` | Certificate Issuer label | Connection Info |
| `certExpiry` | Certificate Expiry label | Connection Info |
| `connection-info-view` | TLS details sheet container | Connection Info |
| `connection-info-done-button` | Done button; Return or Escape also dismisses | Connection Info |
| `certFingerprint` | Certificate SHA-256 fingerprint | Connection Info |
| `server-info-view` | Server contact-info sheet container; Done, Return or Escape dismisses | Server Info |
| `server-info-content` | Settled (non-loading) content; wait on this rather than the sheet container, which mounts while the server request is still in flight | Server Info |
| `message-list` | Message list container: a group holding a scroll area with a table, whose rows hold the message bubbles. Every loaded message has its bubble in the tree, on screen or not. The list's scroll bar takes a value from 0 (oldest loaded) to 1 (newest). | Chat |
| `jump-to-newest` | Round button at the bottom center of the message list, labelled "Jump to Newest Message", present only while the list is scrolled away from the newest message. | Chat |
| `message-bubble-{id}` | Individual message bubble (id is ChatMessage.id) | Chat |
| `retracted-message` | Retracted message tombstone | Chat |
| `undecryptable-message` | Stand-in bubble for an encrypted message that could not be decrypted | Chat |
| `setup-mode-picker` | Import/Login/Register segmented control | Account Setup |
| `import-button` | Import & Connect / Import Logs button (Import mode) | Account Setup |
| `import-done-button` | Done button after import completes | Account Setup |
| `choose-adium-folder-button` | Browse for Adium folder (shown when no data found) | Account Setup |
| `account-toggle-{id}` | Toggle checkbox for each discovered Adium account | Account Setup |
| `account-password-{id}` | Password field for each discovered Adium account | Account Setup |
| `register-server-field` | Server domain field (Register mode) | Account Setup |
| `register-username-field` | Username field (Register mode) | Account Setup |
| `register-password-field` | Password field (Register mode) | Account Setup |
| `register-email-field` | Email field (Register mode) | Account Setup |
| `register-button` | Register button (Register mode) | Account Setup |
| `channel-search-field` | Channel search keyword field | Join Room |
| `channel-search-button` | Channel search button | Join Room |
| `new-password-field` | New password field | Change Password |
| `confirm-password-field` | Confirm password field | Change Password |
| `encrypted-indicator` | Lock icon on encrypted messages | Chat |
| `undecryptable-indicator` | Warning lock on an encrypted message that could not be decrypted, shown instead of `encrypted-indicator` | Chat |
| `delivered-indicator` | One checkmark on a sent message that reached the contact | Chat |
| `read-indicator` | Two checkmarks on a sent message the contact has read, shown instead of `delivered-indicator` | Chat |
| `timeline-note` | Note between messages, such as encryption having been switched on by a contact's encrypted message | Chat, Chat History |
| `encryption-menu` | Encryption menu button in chat header | Chat |
| `device-fingerprints-sheet` | Device fingerprints sheet | Chat |
| `device-row-{deviceID}` | Individual device row | Device Fingerprints |
| `trust-button-{deviceID}` | Trust device button | Device Fingerprints |
| `untrust-button-{deviceID}` | Untrust device button | Device Fingerprints |
| `verify-button-{deviceID}` | Verify device button | Device Fingerprints |
| `encryptByDefaultToggle` | Encrypt by default preference toggle | Preferences (Chat) |
| `tofuToggle` | Trust on first use preference toggle | Preferences (Chat) |
| `file-transfer-banner` | Incoming file offer banner, one row per offer | Chat |
| `accept-file-transfer-button` | Accept button on an incoming file offer | Chat |
| `decline-file-transfer-button` | Decline button on an incoming file offer | Chat |
| `account-actions-menu` | Actions pull-down in the account detail, shown only while connected; its items carry no identifiers, so address them by title | Account Detail |
| `registration-form-sheet` | Registration form sheet | Registration |
| `registration-form-content` | Settled (non-loading) content; wait on this rather than the sheet container, which mounts while the server request is still in flight | Registration |
| `registration-submit-button` | Submit button in registration form | Registration |
| `registration-username-field` | Username field in registration form | Registration |
| `registration-password-field` | Password field in registration form | Registration |
| `registration-email-field` | Email field in registration form | Registration |
| `contact-info-button` | Profile-info (i) button in chat header | Chat |
| `history-button` | History (clock) button in chat header | Chat |
| `disconnected-strip` | "You're offline" strip under the chat header | Chat |
| `chat-tab-bar` | Bottom conversation tab bar | Chat |
| `chat-tab-{jid}` | Individual conversation tab chip (account-qualified as `chat-tab-{jid}\|{account-jid}` when the same JID is open under more than one account). Its leading slot shows an unread count (capped at 9+), else a typing bubble while the contact types, else the presence dot or the room or private-chat icon. Its accessibility value reads "N unread message(s)" or "Typing", and is empty otherwise. | Chat |
| `chat-tab-close-{jid}` | Close button on a conversation tab (revealed on hover, replacing the leading slot; account-qualified to match the chip) | Chat |
| `chat-tab-overflow` | Dropdown for tabs that don't fit the bar width | Chat |
| `chat-empty-state` | Placeholder (with New Chat button) shown when no tab is open | Chat |
| `contact-context-get-info` | "Get Info" context menu item on a contact | Contacts |
| `contact-context-history` | "History" context menu item on a contact | Contacts |
| `contact-info-window` | Contact Info (Get Info) window container | Contact Info |
| `contact-info-nickname-field` | Editable nickname field | Contact Info |
| `contact-info-request-presence` | "Request Presence" button | Contact Info |
| `contact-info-block` | Block/Unblock button, shown only once the account's roster is loaded. A window opened while disconnected shows `Not connected to the server` in its Profile section; close and reopen it after connecting, since Get Info only raises the existing window. Choosing Offline in a running session hides the contact rows, so to reach that state open the contact's chat while online, run `ducko-status-menu.sh offline`, then `ducko-chat-header.sh info` | Contact Info |
| `contact-info-remove` | Remove Contact button, shown under the same condition as `contact-info-block` | Contact Info |
| `roster-notice` | Persistent contact-change notice, with a “Dismiss notice” button and Escape shortcut | Contacts |
| `contact-info-roster-notice` | Persistent removal notice, with a “Dismiss notice” button and Escape shortcut | Contact Info |
| `contact-context-remove` | "Remove Contact…" context-menu item (asks for confirmation) | Contacts |

The `account-actions-menu` items, in menu order: Connection Info… (only when the account has TLS info), Server Info…, Change Password…, Check Registration…, Unregister Account…. Never press Unregister Account… in a test run, because accepting its confirmation unregisters the account from the server.

## Context Menu Features

### Contact Row

Right-click a contact row in the contact list:

- **Start Chat** — open a chat tab with the contact
- **Get Info** — open the Contact Info window (identity, subscription, vCard, Block/Remove)
- **History** — open the Chat History window on this contact
- **Pin / Unpin** — pin or unpin the contact to the top of the list
- **Mute / Unmute** — mute or unmute notifications
- **Rename** — set a local alias for the contact
- **Block / Unblock** — block or unblock the contact
- **Remove Contact…** — remove from roster after a confirmation

### Room Row

Right-click a room row in the Rooms section:

- **Open Chat** — open the room chat window
- **Pin / Unpin** — pin or unpin the room to the top of the list
- **Mute / Unmute** — mute or unmute notifications
- **Invite User** — invite a JID to the room
- **Room Settings** — open room config sheet (owner only)
- **Leave Room** — leave the room

### Participant Sidebar

Right-click a participant in the chat window sidebar:

- **Kick** — kick participant (moderator required)
- **Ban** — ban participant (admin/owner required)
- **Grant Voice** — grant voice to visitor (moderator required)
- **Revoke Voice** — revoke voice from participant (moderator required)
- **Change Nickname** — change own nickname (self only)

### Script Reference

| Script | Purpose | Arguments |
|---|---|---|
| `ducko-launch.sh` | Stop an earlier copy, package the debug app as `.build/ducko-ui/DuckoUITest.app` (executable `DuckoUITest`, bundle ID `im.ducko.uitest`, automatic update checks off), launch it under `DUCKO_PROFILE`, or under the profile `uitest` without one, output window ID | none |
| `ducko-import.sh` | Switch to Import mode and click Import button | none |
| `ducko-select-mode.sh` | Select a setup mode segment on the Welcome screen | `<Import\|Login\|Register>` |
| `ducko-login.sh` | Fill JID + password, click Connect | `JID PASSWORD` |
| `ducko-new-chat.sh` | Open New Chat sheet from contact list, fill JID, optionally pick the sending account, start chat | `JID [ACCOUNT]` |
| `ducko-add-contact.sh` | Open Add Contact sheet from contact list, fill JID, submit | `JID` |
| `ducko-send.sh` | Type a message and send it in the active chat window | `MESSAGE` |
| `ducko-screenshot.sh` | Capture the frontmost `DuckoUITest` window by its window ID. Through `vm.sh ui`, a relative name lands in the host's `.build/vm-exchange/ducko-ui/` | `[FILENAME]` (optional, absolute path or relative to `$DUCKO_UI_OUTPUT_DIR`, else `/private/tmp/claude/`) |
| `ducko-search.sh` | Toggle the Cmd+F find bar of whichever Ducko window is frontmost, the chat window or Chat History, and optionally search | `[QUERY]` (optional) |
| `ducko-history-search.sh` | Raise the open Chat History window, press ⌥⌘F and type a query into its toolbar field, which searches all conversations | `QUERY` |
| `ducko-contact-search.sh` | Reveal the contact-list search (⌘F), optionally filter the roster | `[QUERY]` (optional) |
| `ducko-reply.sh` | Right-click a message and select Reply | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-sort.sh` | Open the View menu (Sort Contacts / Hide Offline), optionally select sort/filter (`hideOffline` is also ⌘⇧H with Contacts focused) | `[alphabetical\|byStatus\|recentConversation\|hideOffline]` (optional) |
| `ducko-join-room.sh` | Raise Contacts, open the Join Room sheet, fill room JID + nickname, join. Succeeds once the sheet has closed and the room's row (`room-row-{jid}`) has appeared | `ROOM_JID [NICKNAME]` |
| `ducko-toggle-sidebar.sh` | Toggle participant sidebar in active groupchat window | none |
| `ducko-focus-contacts.sh` | Raise the Contacts window to the front | none |
| `ducko-room-settings.sh` | Open Room Settings sheet via context menu | `ROOM_JID` |
| `ducko-connect.sh` | Reconnect by restarting the app | none |
| `ducko-profile.sh` | Open My Profile sheet from the Contact menu | none |
| `ducko-avatar.sh` | Upload an avatar image via profile sheet. Fills the Open panel like `ducko-attach.sh` and fails when it stays open | `IMAGE_PATH` |
| `ducko-avatar-remove.sh` | Remove current avatar via profile sheet | none |
| `ducko-preferences.sh` | Open Preferences (Settings) window via Cmd+, | none |
| `ducko-preferences-tab.sh` | Switch to a specific tab in the Preferences window | `<General\|Accounts\|Chat\|Status\|Appearance\|Advanced>` |
| `ducko-status.sh` | Set presence status and optional status message from the header's status pull-down. The message step types with keystrokes, so the instance has to stay frontmost | `STATUS [MESSAGE]` (`STATUS`: available\|away\|xa\|dnd\|offline) |
| `ducko-status-menu.sh` | Set presence from the Status menu bar menu, or run its ⌘Y toggle / Custom… items | `<available\|away\|xa\|dnd\|offline\|toggle\|custom>` |
| `ducko-account-status.sh` | Set one account's status from its submenu in the menu-bar extra, leaving the other accounts alone (needs 2+ enabled accounts and Show Ducko in Menu Bar). Not covered by the integration suite | `ACCOUNT <available\|away\|xa\|dnd\|offline>` (`ACCOUNT`: display name or JID as shown in the menu) |
| `ducko-bookmarks.sh` | Open the Bookmarks sheet from the File menu (⌘⇧B) | none |
| `ducko-add-bookmark.sh` | Add a bookmark via the Bookmarks sheet | `ROOM_JID [NICKNAME]` |
| `ducko-remove-bookmark.sh` | Remove a bookmark from the Bookmarks sheet | `ROOM_JID` |
| `ducko-leave-room.sh` | Leave a room via context menu | `ROOM_JID` |
| `ducko-retract.sh` | Retract a message via context menu | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-moderate.sh` | Moderate (remove) a message via context menu | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-reveal.sh` | Reveal a message's saved files in Finder via context menu | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-copy-code-block.sh` | Copy a code block through its "Copy Code" accessibility action and print what the clipboard then holds. Fails when the clipboard does not change. Targets `DUCKO_PID` when set, else the running `DuckoUITest` | `[TEXT]` (optional, matches the first code block whose code contains TEXT; default: last code block) |
| `ducko-encrypt.sh` | Open encryption menu, optionally toggle or open fingerprints | `[on\|off\|fingerprints]` (optional) |
| `ducko-device-trust.sh` | Trust/untrust/verify an OMEMO device | `DEVICE_ID ACTION` (`ACTION`: trust\|untrust\|verify) |
| `ducko-attach.sh` | Attach a file via the attachment button in chat. `ducko-file-panel.swift` fills the Open panel by posting key events to the panel's service process. The script succeeds only once the panel has closed. A panel still open after the wait is cancelled, and the script fails | `FILE_PATH` |
| `ducko-send-method.sh` | Print or choose how the queued files are sent | `[upload\|direct]` (optional) |
| `ducko-change-nickname.sh` | Change MUC nickname via participant sidebar context menu | `NICKNAME` |
| `ducko-private-message.sh` | Send a MUC private message via the participant sidebar context menu | `NICKNAME` |
| `ducko-room-topic.sh` | View or set the room topic | `[TEXT]` (optional; no args prints current topic) |
| `ducko-channel-search.sh` | Search for channels in the Join Room dialog | `QUERY` |
| `ducko-connection-info.sh` | Open Connection Info from Preferences > Accounts (best-effort), or close it with the shared PID-targeted Swift AX helper | `[open\|close]`; close targets `DUCKO_PID` when set, else the running `DuckoUITest` |
| `ducko-register.sh` | Register a new account via in-band registration | `SERVER USERNAME PASSWORD [EMAIL]` |
| `ducko-change-password.sh` | Change account password via Preferences > Accounts (best-effort; needs a connected account and a `List(selection:)` that synthetic clicks may not trigger) | `NEW_PASSWORD` |
| `ducko-toggle-preference.sh` | Toggle any preference checkbox by identifier | `IDENTIFIER` (e.g., chatStatesToggle, encryptByDefaultToggle, tofuToggle, contacts-compact-toggle) |
| `ducko-menu-bar.sh` | Toggle menu bar icon visibility in General preferences | none |
| `ducko-edit-profile.sh` | Edit profile fields and optionally save | `[--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]` |
| `ducko-dismiss-roster-notice.sh` | Dismiss a persistent roster outcome notice using the Swift AX helper; targets `DUCKO_PID` when set, else the running `DuckoUITest` | `[contacts\|info]` |
| `ducko-remove-contact.sh` | Remove a contact via context menu and confirm | `JID` |
| `ducko-contact-menu.sh` | Select a contact row, then run a Contact menu-bar command on it (`remove` confirms) | `JID <get-info\|history\|send-file\|remove>` |
| `ducko-toggle-contacts.sh` | Toggle the Contacts window via Window ▸ Hide/Show Contact List (⌘/) | none |
| `ducko-contact-info.sh` | Open the Contact Info window via context menu, optionally block/remove (`remove` confirms) | `JID [block\|remove]` |
| `ducko-chat-tabs.sh` | List, select, close, or cycle bottom chat tabs, or close all chats (close is best-effort; the hover-revealed close button is merged into the chip's combined element) | `<list\|select\|close\|next\|previous\|close-all> [JID]` |
| `ducko-chat-header.sh` | Click a chat-header toolbar button (Profile info / History) | `<info\|history>` |
| `ducko-message-list.sh` | Press the jump button (`jump-to-newest`) in the active chat's message list. Fails while the list is at the newest message, where the button is absent | `jump` |
| `ducko-invite-user.sh` | Invite a user to a room via context menu | `ROOM_JID INVITEE_JID` |
| `ducko-destroy-room.sh` | Destroy a room via Room Settings sheet | `ROOM_JID` |
| `ducko-room-config-save.sh` | Save room config in Room Settings sheet (best-effort; System Events cannot read the Save button's label on macOS 27) | `ROOM_JID` |
| `ducko-room-settings-tab.sh` | Switch to a tab in the Room Settings sheet | `<General\|Members>` |
| `ducko-add-affiliation.sh` | Add a JID to a room's affiliation list | `ROOM_JID JID` |
| `ducko-stop.sh` | Quit the `DuckoUITest` copy this checkout launched, forcing it after 10 seconds, and fail when it survives. Leaves every other Ducko running, including a `/preview` instance and the integration suites' bundle | none |
| `ducko-window-id.sh` | Print the window ID of the frontmost `DuckoUITest` window, read from the window list by PID (`DUCKO_PID` when set). Used by other scripts | none |

## Workflow

Each workflow runs its scripts in the VM through `vm ui`. Define `vm` in every Bash call that uses it, since shell functions do not carry between calls. Screenshots named without a path land in the host's `.build/vm-exchange/ducko-ui/`, where the Read tool opens them.

### Fresh install E2E test

For first-time setup when no account exists:

**Complete the Welcome screen first.** On a fresh profile the first-run Welcome onboarding window holds key/first-responder status. Contact-list actions like Add Contact are gated behind a focus check (Contacts must be the key window), and synthetic automation can't force that focus while Welcome is up — so contact/chat steps silently fail until Welcome is gone. Welcome can't simply be dismissed; you must *complete* it by logging in through it, or keep it from appearing by seeding the profile's account from the CLI (see Notes). The Welcome screen defaults to **Import** mode, and `ducko-login.sh` assumes **Login** mode is already selected, so select the Login segment of the `setup-mode-picker` segmented control *before* running it.

The Welcome scripts (`ducko-login.sh`, `ducko-register.sh`, `ducko-import.sh`) walk the Welcome window via the recursive `findByAttr` handler (like `ducko-select-mode.sh`) and gate their success message on the osascript result, so a missing field reports an error instead of false success. The login screen's identifiers are covered by `UILoginTests` (which drives them through the test harness's Swift AX helpers, not this script); the register/import segments have no integration test, so for all three the script's traversal and success-gating are verified by construction.

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Select Login mode (Welcome defaults to Import)
vm ui ducko-select-mode.sh Login

# 3. Log in through Welcome (fresh install only)
vm ui ducko-login.sh "USER_JID" "PASSWORD_HERE"

# 4. Screenshot to verify contact list
vm ui ducko-screenshot.sh "after-login.png"

# 5. Start a conversation (opens a chat window)
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 6. Send messages in the chat window
vm ui ducko-send.sh "Hello from Ducko!"
vm ui ducko-send.sh "Testing 1-2-3"

# 7. Screenshot to verify
vm ui ducko-screenshot.sh "after-messages.png"

# 8. Cleanup
vm ui ducko-stop.sh
```

### Relaunch E2E test (existing account)

When an account already exists with Connect on Launch on, as after a GUI login, the app auto-connects on launch using its stored credentials. No login step needed:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch (auto-connects, shows the contact list, plus the chat window if it was open at quit)
vm ui ducko-launch.sh

# 2. Screenshot to verify the contact list. Raise it first, since a restored chat window can be in front.
vm ui ducko-focus-contacts.sh
vm ui ducko-screenshot.sh "after-relaunch.png"

# 3. Start a chat and send a message
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"
vm ui ducko-send.sh "Relaunch test message"

# 4. Cleanup
vm ui ducko-stop.sh
```

### Quick message test (chat window already open)

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }
vm ui ducko-send.sh "Quick test message"
vm ui ducko-screenshot.sh
```

### Chat UI polish test (message grouping, search, reply)

Tests message grouping, find bar, reply compose bar, and context menu:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open a chat
vm ui ducko-launch.sh
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Send grouped messages (within 2-min window → single timestamp)
vm ui ducko-send.sh "Message one"
vm ui ducko-send.sh "Message two"
vm ui ducko-send.sh "Message three"
vm ui ducko-screenshot.sh "grouped-messages.png"

# 3. Test Cmd+F search
vm ui ducko-search.sh "Message two"
vm ui ducko-screenshot.sh "search-results.png"
vm ui ducko-search.sh  # toggle search off

# 4. Test reply compose bar
vm ui ducko-reply.sh "Message one"
vm ui ducko-screenshot.sh "reply-bar.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### Contact list sort/filter test

Tests sort modes and hide-offline toggle:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Open sort menu (visual verification)
vm ui ducko-sort.sh
vm ui ducko-screenshot.sh "sort-menu.png"

# 3. Select a sort mode
vm ui ducko-sort.sh byStatus
vm ui ducko-screenshot.sh "sorted-by-status.png"

# 4. Toggle hide offline
vm ui ducko-sort.sh hideOffline
vm ui ducko-screenshot.sh "hide-offline.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### MUC (Group Chat) test

Tests MUC features — join room, send group message, toggle participant sidebar:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Join a room (opens Join Room dialog, fills fields, joins)
# The room appears in the "Rooms" section of the contact list
# and a chat window opens automatically.
vm ui ducko-join-room.sh "room@conference.example.com" "mynick"

# 3. Screenshot the room chat
# Shows: room subject banner, sender nicknames (color-coded),
# participant sidebar toggle button (person.2 icon) in header
vm ui ducko-screenshot.sh "muc-joined.png"

# 4. Send a group message
vm ui ducko-send.sh "Hello room!"
vm ui ducko-screenshot.sh "muc-chat.png"

# 5. Toggle participant sidebar
# Shows occupants grouped by affiliation (Owner, Admin, Member, etc.)
vm ui ducko-toggle-sidebar.sh
vm ui ducko-screenshot.sh "muc-sidebar.png"

# 6. Verify Rooms section in contact list
vm ui ducko-focus-contacts.sh
vm ui ducko-screenshot.sh "muc-rooms-section.png"

# 7. Cleanup
vm ui ducko-stop.sh
```

### Room settings test

Tests room settings — open settings sheet from context menu, view config and affiliations:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and join a room you own
vm ui ducko-launch.sh
vm ui ducko-join-room.sh "room@conference.example.com" "mynick"

# 2. Focus contacts and open Room Settings via context menu
vm ui ducko-focus-contacts.sh
vm ui ducko-room-settings.sh "room@conference.example.com"

# 3. Screenshot room settings (General tab with config form)
vm ui ducko-screenshot.sh "room-settings-general.png"

# 4. Switch to Members tab to see affiliation list
vm ui ducko-room-settings-tab.sh Members
vm ui ducko-screenshot.sh "room-settings-members.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### Preferences window test

Tests the Preferences window — open via Cmd+,, navigate tabs, verify account management:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Open Preferences (Cmd+,)
vm ui ducko-preferences.sh

# 3. Screenshot to verify preferences window (opens on the last-viewed pane)
vm ui ducko-screenshot.sh "preferences-initial.png"

# 4. Navigate to Accounts tab
vm ui ducko-preferences-tab.sh Accounts
vm ui ducko-screenshot.sh "preferences-accounts.png"

# 5. Navigate to Chat tab (chat states toggle)
vm ui ducko-preferences-tab.sh Chat
vm ui ducko-screenshot.sh "preferences-chat.png"

# 6. Navigate to Appearance tab (contact-list compact rows and sizing)
vm ui ducko-preferences-tab.sh Appearance
vm ui ducko-screenshot.sh "preferences-appearance.png"

# 7. Navigate to Advanced tab
vm ui ducko-preferences-tab.sh Advanced
vm ui ducko-screenshot.sh "preferences-advanced.png"

# 8. Cleanup
vm ui ducko-stop.sh
```

### Profile editing test

Tests the vCard profile editing flow — open profile sheet, verify fields:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch (account must exist)
vm ui ducko-launch.sh

# 2. Open My Profile sheet from the Contact menu
vm ui ducko-profile.sh

# 3. Screenshot to verify profile fields loaded
vm ui ducko-screenshot.sh "profile-edit.png"

# 4. Cleanup
vm ui ducko-stop.sh
```

### Avatar upload/remove test

Tests avatar upload and removal via the profile sheet:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open profile
vm ui ducko-launch.sh
vm ui ducko-profile.sh

# 2. Upload avatar
vm ui ducko-avatar.sh "/path/to/test-image.png"
vm ui ducko-screenshot.sh "avatar-uploaded.png"

# 3. Remove avatar
vm ui ducko-avatar-remove.sh
vm ui ducko-screenshot.sh "avatar-removed.png"

# 4. Cleanup
vm ui ducko-stop.sh
```

### Device trust management test

Tests OMEMO encryption UI — encryption menu, device fingerprints sheet, and trust actions:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open a chat
vm ui ducko-launch.sh
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Screenshot to verify encryption menu button in chat header
vm ui ducko-screenshot.sh "encryption-menu.png"

# 3. Open the device fingerprints sheet via the encryption menu
vm ui ducko-encrypt.sh fingerprints
vm ui ducko-screenshot.sh "device-fingerprints.png"

# 4. Verify device rows show trust status
# Each device row has trust-button-{deviceID} or untrust-button-{deviceID}
vm ui ducko-screenshot.sh "device-trust-status.png"

# 5. Test encryption preference toggles
vm ui ducko-preferences.sh
vm ui ducko-preferences-tab.sh Chat
vm ui ducko-screenshot.sh "encryption-preferences.png"

# 6. Cleanup
vm ui ducko-stop.sh
```

### Presence/status test

Tests setting presence status and status message:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Set status to Away
vm ui ducko-status-menu.sh away
vm ui ducko-screenshot.sh "status-away.png"

# 3. Set status with a message
vm ui ducko-status.sh dnd "In a meeting"
vm ui ducko-screenshot.sh "status-dnd-message.png"

# 4. Back to Available
vm ui ducko-status-menu.sh available
vm ui ducko-screenshot.sh "status-available.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### Bookmarks management test

Tests bookmark lifecycle — open bookmarks, add, verify, remove:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch
vm ui ducko-launch.sh

# 2. Open bookmarks
vm ui ducko-bookmarks.sh
vm ui ducko-screenshot.sh "bookmarks-list.png"

# 3. Add a bookmark
vm ui ducko-add-bookmark.sh "room@conference.example.com" "mynick"
vm ui ducko-screenshot.sh "bookmark-added.png"

# 4. Remove the bookmark
vm ui ducko-remove-bookmark.sh "room@conference.example.com"
vm ui ducko-screenshot.sh "bookmark-removed.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### Message retraction test

Tests sending and retracting a message:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open a chat
vm ui ducko-launch.sh
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Send a message
vm ui ducko-send.sh "This message will be retracted"
vm ui ducko-screenshot.sh "before-retract.png"

# 3. Retract the message
vm ui ducko-retract.sh "This message will be retracted"
vm ui ducko-screenshot.sh "after-retract.png"

# 4. Cleanup
vm ui ducko-stop.sh
```

### OMEMO encryption test

Tests encryption toggle, device fingerprints sheet, and device trust:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open a chat
vm ui ducko-launch.sh
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Enable encryption
vm ui ducko-encrypt.sh on
vm ui ducko-screenshot.sh "encryption-enabled.png"

# 3. Open device fingerprints sheet
vm ui ducko-encrypt.sh fingerprints
vm ui ducko-screenshot.sh "device-fingerprints.png"

# 4. Verify a device (replace DEVICE_ID with actual ID from screenshot). With Trust On First Use on, the
#    default, a new device already shows as Trusted with Verify and Untrust. Trust appears only after Untrust,
#    or with `tofuToggle` off.
# vm ui ducko-device-trust.sh 12345 verify
# vm ui ducko-screenshot.sh "device-verified.png"

# 5. Cleanup
vm ui ducko-stop.sh
```

### Room management test

Tests full room lifecycle — join, topic, nickname, file attachment, leave:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and join a room
vm ui ducko-launch.sh
vm ui ducko-join-room.sh "room@conference.example.com" "mynick"

# 2. View current topic
vm ui ducko-room-topic.sh
vm ui ducko-screenshot.sh "room-topic-view.png"

# 3. Set a new topic
vm ui ducko-room-topic.sh "Welcome to the test room!"
vm ui ducko-screenshot.sh "room-topic-set.png"

# 4. Toggle sidebar and change nickname
vm ui ducko-toggle-sidebar.sh
vm ui ducko-change-nickname.sh "newnick"
vm ui ducko-screenshot.sh "nickname-changed.png"

# 5. Leave the room
vm ui ducko-focus-contacts.sh
vm ui ducko-leave-room.sh "room@conference.example.com"
vm ui ducko-screenshot.sh "room-left.png"

# 6. Cleanup
vm ui ducko-stop.sh
```

### Live-update (cross-driver) test

Verifies that an **open** chat/room window reflects server-pushed changes (subject, participant list, presence) **live, without reopening the tab** — by driving a second occupant from `DuckoCLI` while the GUI stays joined. This exercises the live-read path that backs the chat header, window title, and participant sidebar.

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. GUI joins the room as account A and stays on the tab. The launch also builds the VM's DuckoCLI.
vm ui ducko-launch.sh
vm ui ducko-join-room.sh "room@conference.example.com" "observer"
vm ui ducko-screenshot.sh "live-before.png"   # header shows e.g. "1 participant"

# 2. One-time: configure account B in its OWN profile in the VM (a fresh DUCKO_PROFILE has no account,
#    and `interactive` needs one). See the ducko-cli skill for `account add` flags.
vm gui 'DUCKO_PROFILE=clibot /Users/lume/work/ducko/.build/debug/DuckoCLI account add ...'

# 3. Account B (a DISTINCT account, its own DUCKO_PROFILE) joins from the CLI as a second occupant.
#    The REPL supports /join <room-jid> [nick], /topic <subject>, /nick <newnick>.
vm gui "printf '/join room@conference.example.com clibot\n' | DUCKO_PROFILE=clibot /Users/lume/work/ducko/.build/debug/DuckoCLI interactive"

# 4. Bring the copy frontmost WITHOUT relaunching (activating it sends CSI active, which flushes queued pushes), then screenshot.
#    Do NOT use ducko-launch.sh here. It kills and relaunches the app. The tab comes back and the room is
#    joined again on a new connection, so the screenshot would show a fresh join instead of a live update.
vm gui 'osascript -e "tell application \"System Events\" to set frontmost of process \"DuckoUITest\" to true"'
vm ui ducko-screenshot.sh "live-after.png"
# Assert: header participant count 1 -> 2 and the sidebar lists clibot — live, no tab reopen.

# 5. Cleanup
vm ui ducko-stop.sh
```

- **A DuckoApp window must be on screen while observing.** DuckoApp sends XEP-0352 `CSI inactive` while it is not the frontmost app and none of its windows is visible (hidden, minimized, fully covered, or on another Space). The server then **queues** MUC presence and subject pushes and flushes them only on `CSI active`. An observation made with no window visible sees a stale header or subject and wrongly concludes the live read is broken. Activate the app (`set frontmost`) before screenshotting, and do not relaunch.
- **Subject-change variant.** Ad-hoc MUC rooms restrict `/topic` to moderators, so the first occupant to join a fresh room owns it. To test a live subject update, have account B join the empty room **first** (becoming owner) and keep its REPL session open while the GUI joins as a guest, then issue `/topic <subject>` and assert `room-subject-view` updates live. Participant-count and presence updates (above) need no ownership and work from any second occupant.
- Use a **separate `DUCKO_PROFILE`** for the CLI account so its credentials and SwiftData don't collide with the GUI profile.

### File attachment test (full)

Tests attaching and sending a file:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch and open a chat
vm ui ducko-launch.sh
vm ui ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Attach a file, by its path inside the VM
vm ui ducko-attach.sh "/Users/lume/work/test-file.png"
vm ui ducko-screenshot.sh "file-attached.png"

# 3. Send (the attached file appears in pending-attachments bar, send delivers it).
#    Upload is preselected. To send the file straight to the contact's device instead, run the line below first.
#    It fails unless the contact is online with a device that takes direct transfers.
# vm ui ducko-send-method.sh direct
vm ui ducko-send.sh "Here's a file"
vm ui ducko-screenshot.sh "file-sent.png"

# 4. Cleanup
vm ui ducko-stop.sh
```

For image-rendering checks, confirm a generated image fixture decodes: `sips -g pixelWidth <file>` returns a number, while `file` only reads the header. Confirm a rendering verdict against a screenshot, not against stored metadata such as the MIME type.

### Connection info test

Tests viewing TLS connection details:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch (must be connected)
vm ui ducko-launch.sh

# 2. Open connection info
vm ui ducko-connection-info.sh
vm ui ducko-screenshot.sh "connection-info.png"

# 3. Cleanup
vm ui ducko-stop.sh
```

### Sparkle update check test

Sparkle's updater starts only inside an app bundle. The `DuckoUITest` copy is one, so test updates against it in the VM. Its automatic checks are off, which leaves the manual "Check for Updates…" working.

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }

# 1. Launch the copy under a throwaway profile
DUCKO_PROFILE=update-check vm ui ducko-launch.sh

# 2. Confirm the updater started: the app menu item is enabled
vm gui 'osascript -e "tell application \"System Events\" to tell process \"DuckoUITest\" to get enabled of menu item \"Check for Updates…\" of menu 1 of menu bar item 2 of menu bar 1"'

# 3. Run the check against the real appcast
vm gui 'osascript -e "tell application \"System Events\" to tell process \"DuckoUITest\" to click menu item \"Check for Updates…\" of menu 1 of menu bar item 2 of menu bar 1"'

# 4. Capture the result window: pick WINDOW_ID from the copy's window list
vm gui 'swift /Users/lume/work/ducko/Skills/demo-screenshots/scripts/windows.swift $(pgrep -x DuckoUITest)'
vm gui 'screencapture -x -o -l WINDOW_ID "/Volumes/My Shared Files/vm-exchange/ducko-ui/update-check.png"'

# 5. Cleanup: quit the copy, remove the throwaway profile
vm ui ducko-stop.sh
vm gui '/bin/rm -rf "$HOME/Library/Application Support/Ducko-Dev-update-check"'
```

- The check first shows a "Software Update" progress window, then the result in a separate untitled window. The VM's build folder has no `.git`, so the copy is version 0.0.0 build 1, and the check offers the latest release. The fresh profile's Welcome window is listed too.

### Reconnect (app disconnected)

If the app is running but disconnected (e.g. network drop), restart it to trigger auto-connect:

```bash
vm() { zsh Skills/lume-vm/scripts/vm.sh "$@"; }
vm ui ducko-connect.sh
```

## Permission Allowlisting

To allow these scripts in `settings.local.json` without prompts:

```json
{
  "permissions": {
    "allow": [
      "Bash(zsh Skills/lume-vm/scripts/vm.sh ui *)"
    ]
  }
}
```

## Notes

- Scripts use `keystroke` (not `set value`) to trigger SwiftUI bindings. Keystrokes land in whatever app is frontmost, which is one reason the scripts run in the VM: on a Mac run, a typing script such as `ducko-send.sh` can type into the user's app. Post key events to the instance's PID instead (see the `AppAccessor.postKey` note below).
- `ducko-launch.sh` starts the copy with `-ApplePersistenceIgnoreState YES`, and a copy started by hand needs the same argument. `ducko-stop.sh` ends the copy with a signal, after which macOS would restore the last run's windows at the next launch instead of opening Contacts. The app does its launch work from the Contacts window: it loads accounts there and opens Welcome or the chat window. A run that ended on Welcome would therefore start with no window at all. The chat window still reopens when it was open at quit, because the app restores it itself.
- Verifying any **live** update (subject, participant count, presence) needs a DuckoApp window on screen first. Otherwise CSI holds the pushes back (see "A DuckoApp window must be on screen while observing" above).
- Multi-step interactions are bundled in single osascript blocks to avoid focus loss.
- Element targeting uses recursive UI-element-tree walks (`findByAttr` and siblings) because `entire contents` silently collapses on deeply nested SwiftUI / NSTableView accessibility trees on macOS 26. Scripts that need these handlers source `ducko-helpers.sh` and emit `$(ducko_as_handlers)` in an unquoted heredoc. Scripts targeting shallow sheets, such as New Chat, Add Contact and Bookmarks, still use `entire contents` where it reaches their controls. SwiftUI `Picker` segments and Room Settings tabs expose their label through `AXDescription`, so scripts match that attribute. Confirmation-dialog buttons do too, so `ducko_as_click_button_by_label` falls back to it when a button has no title.
- On macOS 27, other SwiftUI buttons in a sheet, such as Room Settings' Save, expose neither a title nor `AXDescription` to System Events, although Swift AX reads their description. Drive those by identifier or through Swift AX.
- System Events window references are positional, so raising a window re-points a variable that held another one. When a script uses the window after raising it, raise it with `ducko_as_raise_window_by_id`, which finds it again after `AXRaise`.
- A window's scene id (`contacts`, `chat`, `transcripts`) is its own `AXIdentifier`, so `value of attribute "AXIdentifier" of win`, wrapped in `try` as `ducko-history-search.sh` does, finds it with one Apple event per window. Prefer that inside a polling loop: `ducko_as_find_window_by_id` walks each window's contents, which costs seconds per window.
- Scripts that confirm a removal refuse while more than one `DuckoUITest` runs, for example copies from two checkouts, because System Events could press the confirmation in the wrong process. They also refuse while a dialog is already open in the target window, so a leftover dialog is never the one they act on. `ducko-contact-menu.sh` applies the open-dialog check to every action.
- To verify a destructive confirm step without confirming, open the dialog and resolve its confirm button inside the dialog sheet with `findButtonByLabel(<sheetVar>, "<label>", 0, 30)` (from `$(ducko_as_handlers)`) without clicking it. Scope the lookup to the sheet, because a window can hold a same-named button outside the dialog (Contact Info does). Then dismiss the dialog with the generated `ducko_as_click_button_by_label "Cancel" <sheetVar>` snippet, which exercises the same lookup and click path end to end.
- Keep apostrophes out of osascript heredoc bodies. `/bin/bash` 3.2, which the scripts' shebang selects, rejects a `$(… << EOF …)` body with an odd apostrophe count, while Homebrew bash 5 accepts it, so check with `/bin/bash -n` rather than a bare `bash -n`.
- Limit `ducko-helpers.sh` and the wrapper scripts to bash builtins and the commands DuckoScriptTests stubs. Its capture fixture runs them with a PATH holding only stubs plus `cat` and `dirname`, and rejects absolute command paths.
- Idle auto-away switches the status to Away after about five minutes without mouse movement or key presses, so an unattended run can observe Away unexpectedly. AX actions and clicks without movement don't count as input. Set the status explicitly (e.g. `ducko-status-menu.sh available`), which cancels auto-away, before asserting on it.
- The scripts marked best-effort in the Script Reference table (`ducko-chat-tabs.sh`, `ducko-connection-info.sh`, `ducko-change-password.sh`, `ducko-room-config-save.sh`) hit osascript limitations covered authoritatively by the integration suite instead; each table row names the specific control. `UIPreferencesTests` covers `ducko-connection-info.sh` and `ducko-change-password.sh`, and `UIMUCTests` covers the Room Settings Save.
- The contact list and chat windows are both singletons (`Window`). The chat window holds all open conversations as bottom tabs (`chat-tab-bar`); `ducko-send.sh` targets the active tab in the frontmost chat window. Contact Info is a `WindowGroup` keyed by `ContactInfoRef`.
- Pass runtime values as arguments to `osascript -` and read them with `on run argv`. Keep them out of the generated AppleScript source.
- Credentials are arguments, never hardcoded.
- When the user drives the GUI on a profile, run CLI or integration tests meanwhile on other `DUCKO_PROFILE`s and accounts, so their offers and messages stay out of the user's window. Hand the GUI over by running `swift build` and launching `DUCKO_PROFILE=<name> .build/debug/DuckoApp` (a packaged bundle can be stale).
- PID-targeted AX (`AXUIElementCreateApplication(pid)`, as `ducko-dismiss.swift` does) reaches one instance whatever its name. AX actions need no focus: `AXShowMenu` on a `contact-row-*` followed by pressing its "Start Chat" menu item opens a chat, and `AXPress` works on `status-picker` and on picker radios. Prefer these to synthesized mouse clicks, which land on whatever window is frontmost.
- Open a menu with whichever action the element advertises — `AXShowMenu` returns success without opening the menu on a control that does not advertise it, such as `account-actions-menu`, a `Menu` inside a grouped `Form`, which advertises only `AXPress`. `AppAccessor.pressMenuItem` and `ducko_as_click_context_menu_item` both branch on the advertised action list.
- A throwaway `DUCKO_PROFILE` gets a persisted account from the CLI (`DuckoCLI account add --no-connect`), after which the GUI opens on Contacts with no Welcome screen. That account has Connect on Launch off, so it starts Offline: `AXPress` `status-picker`, then press its Available item. Once a session has been online, a relaunch starts Offline again but lists the contacts stored from that session. With Hide Offline Contacts on, it lists only those with unread messages. `AXShowMenu` on a row and its "Start Chat" item open the chat there without connecting.
- For a run that needs contacts with presence, avatars and a chat but no live account, point the `DuckoUITest` copy at the `/demo-screenshots` skill's stub, so these scripts can drive it. Give the run a `DUCKO_PROFILE`, a port and a VM work folder of its own: the `uitest` profile may hold a live account, and that skill's reference mode uses port 5299 and `/Users/lume/work`.
  1. Build the copy with `DUCKO_PROFILE=<profile> vm.sh ui ducko-launch.sh`, then stop it with `ducko-stop.sh`.
  2. In the work folder, copy `content.json`, render the avatars and start `stub.py` detached, as that skill's R2.2 does.
  3. Add the stub's account with the copy's own CLI, `DUCKO_PROFILE=<profile> /Users/lume/work/ducko/.build/ducko-ui/DuckoUITest.app/Contents/Resources/ducko account add … --host 127.0.0.1 --port <port> --no-connect`, and run R2.2's store `UPDATE`, in its quoting for `vm.sh gui`, on `Ducko-Dev-<profile>/default.store`.
  4. Launch again with `DUCKO_PROFILE=<profile> vm.sh ui ducko-launch.sh`. A chat opens once a message is pushed through the stub, as that skill's Step 4.3 does.

  The "Changing the Content" section of that skill covers a room row, a room invitation (`room-invite-banner`), a file offer, a code block, reply quotes and file cards. Afterwards stop the copy, kill the stub by the PID listening on its port, and remove `Ducko-Dev-<profile>`, the `im.ducko.dev.<profile>` defaults and the work folder.
- A throwaway profile folder (`~/Library/Application Support/Ducko-Dev-<profile>/`) holds file-based credentials and OMEMO keys. `rm` may be aliased to `trash` in the shell profile, so remove the folder with `/bin/rm -rf` to keep it out of the Trash.
- A packaged bundle's app menu is "Ducko" (Ducko ▸ Quit Ducko); a bare debug binary's is "DuckoApp" (DuckoApp ▸ Quit DuckoApp). A script that quits or opens app-menu items by title must use the title matching how the instance was launched.
- A leftover Open or Save panel, or a context menu left open, blocks the instance: AX walks and AppleScript calls then hang. Check for a leftover panel in the window list, which needs no AX: `Skills/demo-screenshots/scripts/windows.swift <pid>` lists every window of the instance. Cancel any panel it shows. Close a context menu as soon as its items are read, with `AXCancel` on the menu or Escape posted to the PID. Run probes and scripts under a timeout (for example `perl -e 'alarm 30; exec @ARGV' <command>`) so a stuck step fails fast.
- To get an outgoing bubble without typing into the GUI, send from a second session of the same account while the GUI is connected, such as the CLI under another profile. It arrives as a carbon.
- A `message-bubble-{id}` is one combined accessibility element whose value contains the message's text, unless the message has attachments, a link preview or a code block. Then the bubble is a container that reports no value, and its `attachment-view`, `link-preview` and `code-block` children are separate elements.
- To type into the dev instance alone, activate it by PID (`NSRunningApplication(processIdentifier:)`, not `set frontmost of process`) and post Unicode key events to that PID, as `AppAccessor.postKey` does. When `activate()` called from a background process leaves the instance behind, set the `AXFrontmost` attribute of its application element (`AXUIElementCreateApplication(pid)`) instead. This fills `new-chat-jid-field` after File ▸ New Chat; pressing `start-chat-button` then opens a chat with a JID that has no contact row.
- Neither the `-AppleInterfaceStyle Dark` launch argument nor `defaults write DuckoApp AppleInterfaceStyle Dark` switches the debug binary to dark appearance, so a dark-appearance check needs the system setting. Ask the user to switch it, or run the check in the `/lume-vm` VM and switch it there with `vm.sh appearance dark`.
- To pin how one instance looks, run a re-signed copy of the packaged debug bundle. `NSRequiresAquaSystemAppearance` as `true` in its `Info.plist` forces light appearance on a system set to Dark. A `CFBundleIdentifier` of its own that no earlier run used leaves it with no saved window frames, so the chat window opens at its default size. Step 2 of the `/demo-screenshots` skill holds the commands for the copy, and its Step 7 removes the preferences the copy leaves behind. The launch argument pair `-AppleShowScrollBars WhenScrolling` switches one instance to overlay scroll bars.
- AX titles render the status rows' checkmark and dash marks as the object replacement character `￼` (U+FFFC), so a title read shows which rows are marked but not how. Each account shows exactly one status, so among the five global status rows (Available through Offline), read a single marked row as a checkmark and two or more as dashes. A per-account submenu only ever checks one row. Saved-status rows can't be read this way, so screenshot the open menu for those, or whenever the distinction must be confirmed.
- Quit a PID-targeted instance with `NSRunningApplication(processIdentifier:).terminate()`, which takes the app's own quit path. Pressing Quit through accessibility in the app menu or the menu-bar extra works only for the frontmost instance: on a background instance the press returns success and does nothing. Tabs and the chat window's open state are saved on every change, so they survive a kill as well. Use the real quit when the quit path itself is under test, since the windows close on the way out and that must not count as the user closing the chat window.
- Allow about ten seconds for a quit, since the app disconnects first, and confirm the process has exited before launching the next instance on the same profile. An instance can ignore the quit request, and a launch then runs beside it. Stop a stuck one by PID.
- To let the user try relaunch behavior, run the debug binary in a loop that starts it again whenever it exits, such as `while [ ! -f "$STOP_FILE" ]; do DUCKO_PROFILE=<name> .build/debug/DuckoApp; sleep 1; done`, so ⌘Q shows the relaunch without a terminal. To end it, create the stop file, then quit the instance by PID.
- The chat window's saved tabs are the `chatSavedTabs` key in the profile's debug defaults domain: `im.ducko.dev.uitest` for the copy launched without a `DUCKO_PROFILE`, `im.ducko.dev.<profile>` under one, and `im.ducko.dev` only for a debug Ducko run outside these scripts. To return a profile to no saved tabs, delete the key while no instance of that profile runs, since a running one writes it again on its next tab change.
- A sheet that fetches on appear needs an identifier on its settled (non-loading) content, not only on the sheet container: the container mounts while the request is in flight, so a wait on it passes before the fetch resolves and cannot fail when the fetch breaks. `server-info-content` and `registration-form-content` follow this; give new loading sheets the same pair.
