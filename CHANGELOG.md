# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2026-10-08

### Added

- Add a search over all conversations to the Chat History window, which lists each day with a match as soon as it is found and opens the first one
- Add a find bar to the Chat History window (⌘F) that steps through the matches from day to day and shows how many there are
- Highlight the searched word inside matching messages, in Chat History and in a chat's find, and mark the match you are on
- Allow selecting and copying part of a message's text, in chats and in Chat History
- Add `ducko history --search` without an address to search every conversation of an account, and `/searchall` in interactive mode

### Changed

- Rename the Chat Transcripts window to Chat History, and show the conversation's name once, as the window's title
- Show every day of an account or an imported history when you select it in Chat History, and remember which of them you collapsed
- Show a contact's photo next to each conversation in Chat History, and the conversation's photo and name on each day of an account, an imported history or a search
- Open Chat History on your first account when you open it from the File menu
- Search a conversation's whole history with `ducko history <address> --search`, instead of its newest 500 messages
- Find messages by the name of an attached file in a chat's find, and never find retracted messages

### Removed

- Remove the conversation type filter from the Chat History toolbar
- Remove the number of messages from each day and the date of the last message from each conversation in Chat History

### Fixed

- Fix the arrow keys not moving the selection after you click a row in Chat History, Settings ▸ Accounts or Settings ▸ Status

### Security

- Prevent a received message that stacks thousands of accents on one letter from freezing Ducko while you search

## [0.7.0] - 2026-10-06

### Added

- Add a Compact rows option in Settings ▸ Appearance that shows every contact and room on one line, without avatars, status lines or room topics
- Add tooltips that show the full text of a name, status message, room topic or file name that is cut off

### Changed

- Show the date above the first message of each day in a chat
- Show a status message, room topic or reply preview that has several lines as one line, instead of only its first line

### Removed

- Remove themes, including the theme picker, the three alternative themes and loading your own theme files, so Ducko always uses the look of the former Default theme

### Fixed

- Fix your status and avatar at the top of the Contacts window being pushed against the window's edges by a long status, which is now shortened to fit
- Fix a long file name running past the edge of the placeholder for an image whose file is missing
- Fix the chat window briefly showing its header cut off under the title bar and its tabs below the window's edge while a chat is opening
- Fix rooms no longer showing new messages or their participants after your connection briefly drops, and show the messages sent during the drop
- Fix room bookmarks staying empty after your connection briefly drops
- Fix rooms not being joined when your connection drops while Ducko is signing in
- Fix still appearing in a room to others after leaving it while your connection was down
- Fix a room staying disconnected without notice when its server answers Ducko's periodic check with an unexpected error

## [0.6.0] - 2026-10-04

### Added

- Bring back the chat window after relaunching Ducko, with the same tabs in the same order and the same one selected
- Rejoin the rooms you are in whenever Ducko connects, without an auto-join bookmark, until you leave them, including rooms joined with `/join` in `ducko interactive`
- Add a button at the bottom of a chat that jumps to the newest message, shown while you are scrolled up
- Keep each chat's reading position while the chat window is open, so switching tabs and back shows a chat where you left it

### Changed

- Print a failed direct transfer in `ducko interactive` as `error: <reason> (sid: <id>)`, and mark a failed transfer in `/transfers` with `error:` as well
- Say "the contact" instead of "the peer" in file transfer and encryption errors, call the list in Device Fingerprints "Contact's Devices", and end menu items and progress labels with a proper ellipsis
- Keep what you are reading in place when older messages load, a message arrives, a link preview appears, or the window is resized, and keep the newest message in view when you are at the end of the chat
- Count messages that arrive while you are scrolled up in a chat as unread, and send the read receipt only once you are back at the newest message
- Show that a contact is typing on the chat's tab only, no longer as a row at the end of the chat
- Leave a little space between the newest message and the message field
- Open chats, show incoming messages and resize the chat window faster in chats with a long history

### Fixed

- Fix link preview cards missing from a chat after relaunching Ducko, and from older messages loaded by scrolling back, until the next message arrived
- Fix a contact's subscription request disappearing when your connection briefly drops
- Fix a folder being accepted for sending and failing only once the transfer had started, by refusing it right away
- Fix a message changing height, and the chat shifting with it, when a remote image loads, a delivery mark arrives, or a direct file transfer moves from waiting to sending
- Fix scrolling back in a chat skipping or repeating messages sent in the same second, and loading the oldest part of the server's history instead of the part right before what is shown, also in `ducko history --server`
- Fix a read receipt being sent for a chat you had already switched away from

### Security

- Prevent someone else from slipping messages into a chat's history while Ducko loads it from the server, by accepting history only from the archive that was asked and no more than was asked for

## [0.5.0] - 2026-10-03

### Added

- Send a file straight to one of a contact's devices with Send Directly in the attachment bar, or with `/senddirect` in `ducko interactive`, instead of uploading it to the server, with a note in encrypted chats that files are not end-to-end encrypted
- Switch a chat's encryption on when the contact sends an encrypted message, with a note in the chat saying so, unless you switched it off yourself
- Open a contact's chat when they write or offer a file, behind the window you are in, without taking the keyboard and without marking it read, and bounce the Dock icon once
- Show delivered and read as separate checkmarks on your messages, print read markers as they arrive in `ducko interactive`, and mark read messages `[read]` in history
- Show a typing bubble in a chat's tab while the contact types

### Changed

- Show a photo sent as a file as the photo itself instead of its link, in your own messages as well as received ones
- Load photos from people in your contact list right away in one-to-one chats, and show anyone else's as a placeholder with the file name that loads when clicked
- Trust a contact's new devices on first use by default, so a first encrypted message sends without verifying a fingerprint beforehand, and show those devices as Trusted in Device Fingerprints
- Show an encrypted message that could not be decrypted as a muted notice with a warning lock instead of as text from the sender, and mark it as an error in `ducko` output, with an `undecryptable` field in JSON
- Offer Copy Link for a shared file in the message context menu, and no longer offer Edit for it
- Show a code block in its own box with a copy button on hover, and show inline code in a monospaced font
- Insert a line break in the message field with Shift or Option plus Return or Enter, and send with the keypad's Enter key as well as Return
- Show the typing indicator and a file being received as rows at the end of the chat
- Show a chat's unread count at the start of its tab, in place of the status dot, instead of after the name
- Count a chat as read only while its window is focused, so messages that arrive while it is behind another window or the app is in the background stay unread
- Keep typing and presence updates coming while any Ducko window is on screen, also behind another app, and tell the server the app is inactive only once none is
- Title notifications with the contact's name from your contact list
- Upload a file with `ducko send --file` unless `--method jingle` is given, and accept a contact's bare address with `--method jingle`, which then picks one of their devices that takes direct transfers

### Fixed

- Fix your profile picture disappearing for your contacts after you sign in or your connection briefly drops
- Fix line breaks being lost in messages that use styling or mention you
- Fix the status dot in a chat tab sitting further from the tab's edge than the name does
- Fix link previews being unreadable inside your own message bubbles
- Fix contacts showing as offline while online after one of their devices disconnects or after your connection briefly drops
- Fix "Last seen" jumping to the moment you connect for contacts who were already offline
- Fix unreadable text in history for imported messages that carry their own background color
- Fix encrypted messages that carry no text showing up as undecryptable
- Fix a failed file upload going unreported
- Fix uploaded files losing their original name
- Fix messages sent within the same second showing in the wrong order
- Fix a delivery checkmark or send error landing on a received message instead of your own, or on your private message to another member of a room
- Fix a destroyed room reappearing when one of its messages arrives late

## [0.4.0] - 2026-09-24

### Added

- Take a single account offline or back online from its own submenu in the status menus, which now list every enabled account, including offline ones

### Changed

- Group the Contacts header status menu, the menu bar icon's menu, and the Status menu into All Accounts and Each Account sections when you have more than one account, with a dash beside a status only some of your accounts show
- Show the header account's own status in the Contacts header, followed by how many accounts show another one, such as "Available · 1 Offline"
- Connect every enabled account when you pick an online status for all accounts, including accounts that don't connect on launch
- Keep the account you picked in the Contacts header while it is offline, and show that its name opens the account switcher
- Turn on Connect on Launch for imported accounts unless their original settings turned it off

### Fixed

- Show "Not connected to the server" instead of an internal account ID when something needs a connection while an account is offline, such as a contact's profile in Get Info

## [0.3.0] - 2026-09-23

### Added

- Add Get Info (⇧⌘I), History (⌘L), and Send File… (⇧⌘F) to the Contact menu for the selected contact or the active chat, and a ⌘⌫ shortcut for Remove Contact…
- Add a Status menu to the menu bar with Available (⇧⌘Y), a ⌘Y toggle between Custom Away… and Available, and Custom…
- Add Close All Chats (⌥⌘W) to the File menu
- Add Select Next Tab (⌃⇥ or ⇧⌘]) and Select Previous Tab (⌃⇧⇥ or ⇧⌘[) to cycle through chat tabs
- Add Show/Hide Contact List (⌘/) to the Window menu
- Add a ⇧⌘H shortcut for Hide Offline Contacts

### Changed

- Fit the Settings window to the pane you are viewing, keeping the toolbar buttons in place as you switch panes
- Gather the account actions in Settings ▸ Accounts into an Actions menu, so their labels read in full instead of being cut to a letter
- Show the account and saved-status lists as bordered lists with add and remove buttons beneath them
- Ask for confirmation before removing a contact from the Contacts window
- Show the same account's status in the menu bar icon as in the Contacts header

### Removed

- Remove the Notifications settings pane, whose sound and Do Not Disturb switches had no effect

### Fixed

- Close the Server Info sheet with Escape, as the other account sheets already do
- Keep accounts you took offline disconnected when the Contacts window is closed and reopened

## [0.2.1] - 2026-09-22

### Changed

- Exit the CLI's `omemo trust` with an error when the device is unknown

### Fixed

- Keep CLI JSON output parseable for empty lists, OMEMO commands, and an invalid JID in `/avatar`
- Show usage for an unknown affiliation in the CLI's `/affiliations` instead of listing members
- Prevent the CLI from crashing when in-band registration asks for a password without a terminal
- Save avatars from `avatar get` with the file extension matching their image type
- Show the certificate issuer in Connection Info as readable names instead of raw certificate data
- Let VoiceOver reach the buttons on file attachments, link previews, and incoming file offers individually
- Remove incoming file offers once their account disconnects, instead of offering files that can no longer be accepted
- Fail a direct file transfer after two minutes when the recipient accepts but never connects, instead of waiting forever
- Fail a direct file transfer that stalls for 30 seconds, instead of leaving it stuck

### Security

- Accept block list updates only from your own server, ignoring ones sent by another client of your account or with a malformed sender

## [0.2.0] - 2026-09-21

### Added

- Add a General setting to show or hide Ducko's menu bar icon

### Changed

- Require Apple Silicon for the app and bundled CLI
- Report confirmed contact changes separately from incomplete local synchronization or subscription requests
- Show an unavailable cipher suite explicitly in connection details

### Removed

- Remove the nonfunctional "Show Ducko in Dock" setting

### Fixed

- Allow closing Connection Info with Done, Return, or Escape
- Prevent a failed message-history write from crashing Ducko
- Preserve account and conversation settings when first saving them
- Preserve reply context in synced and archived messages
- Keep conversation history aligned with the latest conversation, date and search selection
- Keep contact changes and the saved roster version consistent across disconnects, reconnections, and local save failures
- Prevent a connection attempt from restoring an account after it has been disconnected
- Keep delayed room-join updates from restoring participants after leaving
- Close pending direct file-transfer connections when cancelling or going offline
- Finish signing out without a half-second wait when the connection has already dropped
- Prevent a failed OMEMO device list read from removing your other devices from encryption, and add this device once the list can be read again

### Security

- Accept replies to requests only from the address they were sent to, or from your own server, so another sender cannot answer them in its place

## [0.1.0] - 2026-09-16

### Added

- Save files you accept to the Downloads folder and show them in the sender's conversation, where you can preview them with Quick Look and reveal them in Finder
- List file offers sent as links next to direct transfers in the offer banner and the CLI

### Changed

- Ask before loading an image a contact links to, so opening a chat doesn't reveal your address and reading time to the image's host
- Accept or decline a file offer in the CLI by the id printed with it, taking the current account's newest offer when no id is given
- Show whether you have joined a room in the contact list, and follow the avatar and status indicator settings for room rows

### Removed

- Remove requesting a file from a contact and adding or removing files in a running transfer, which never delivered those files

### Fixed

- Show a readable reason when signing in fails, such as "Incorrect username or password", instead of internal error details
- Show readable messages such as "Connection refused" when connecting, registering an account, transferring or uploading files, searching channels, or setting up OMEMO encryption fails, and when the server closes the connection
- Fix Ducko quitting unexpectedly when the server connection or a file transfer drops while data is being sent
- Fix Ducko crashing when the server closes an encrypted connection while messages are still being sent
- Fix connecting hanging indefinitely when a server stops responding during the encrypted handshake, and keep a slow certificate check from delaying going offline
- Fix connections staying open in the background after the server ends them, and going offline returning before the connection has actually closed
- Fix direct file transfers hanging when the peer rejects the connection method, a file transfer proxy can't be activated, or the peer or proxy stops responding
- Fix completed direct file transfers later showing as failed, and a second click on Accept stalling an incoming transfer
- Fix a rare crash in the update checker
- Fix direct file transfers reporting success when the file arrived incomplete or corrupted, and failed transfers later showing as completed
- Fix accepting a link offer reporting the transfer as complete without downloading anything, and refuse a download that ends early or arrives in a form whose size can't be checked
- Fix direct file transfers to clients such as Conversations stalling once they connect
- Fix your status in the Contacts header, account menu and menu bar not reflecting an account's own status, or showing online while the account is disconnected

### Security

- Prevent a peer from freezing or crashing a direct file transfer with an invalid transfer block size
- Prevent an attacker on the network from slipping unencrypted messages into a connection while it switches to encryption, and refuse to connect when a server does so
- Prevent anyone other than the person you are transferring with from cancelling, redirecting, feeding data into, or completing a direct file transfer
- Prevent a contact from disguising a file's name with invisible characters or saving it outside the Downloads folder
- Prevent a contact from opening a file on your own computer by sending a link to a local path
- Prevent accepting one file offer from acting on another offer that reuses its id

## [0.0.2] - 2026-09-14

### Added

- Show the first import errors in the Adium import summary, not just their count

### Fixed

- Fix signing in to servers that offer SASL2 authentication, which failed with an unexpected stream error
- Import Adium chat history for Facebook, MSN, and ICQ contacts whose IDs contain `@` or spaces
- Show readable connection and server error messages instead of internal error codes

## [0.0.1] - 2026-09-14

Initial release.

[Unreleased]: https://github.com/ducko-im/ducko/compare/0.8.0...HEAD
[0.8.0]: https://github.com/ducko-im/ducko/compare/0.7.0...0.8.0
[0.7.0]: https://github.com/ducko-im/ducko/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/ducko-im/ducko/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/ducko-im/ducko/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/ducko-im/ducko/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/ducko-im/ducko/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/ducko-im/ducko/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/ducko-im/ducko/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ducko-im/ducko/compare/0.0.2...0.1.0
[0.0.2]: https://github.com/ducko-im/ducko/compare/0.0.1...0.0.2
[0.0.1]: https://github.com/ducko-im/ducko/releases/tag/0.0.1
