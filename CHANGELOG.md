# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fix the first-run import counting its log folders as accounts

## [0.15.0] - 2026-11-26

### Added

- Sign in through the browser on servers that offer it (XEP-0493) ([#6](https://github.com/ducko-im/ducko/issues/6))
- Sign in through the browser from the CLI with `ducko account add --sso` and `ducko account browser-sign-in` ([#6](https://github.com/ducko-im/ducko/issues/6))

### Fixed

- Fix a crash when connecting an account whose port is outside 1–65535
- Fix the same address ending up as two accounts when added twice at once

## [0.14.1] - 2026-11-24

### Changed

- Keep an account's contacts listed as offline while the account is offline or signing in ([#5](https://github.com/ducko-im/ducko/issues/5))

### Fixed

- Fix an account disconnecting when this Mac's encryption setup fails or the server is slow ([#5](https://github.com/ducko-im/ducko/issues/5))
- Fix the onboarding import leaving accounts without a saved password unticked ([#5](https://github.com/ducko-im/ducko/issues/5))

## [0.14.0] - 2026-11-24

### Added

- Mark a contact's OMEMO device verified from the CLI with `ducko omemo verify` or `/omemo-verify`
- Change an account's password from the CLI with `ducko account change-password` or `/change-password`

### Changed

- Style messages as XEP-0393 defines it, including nested quotes and code blocks that name a language
- Check a directly received file with the strongest checksum the sender lists, including SHA-512
- Stop connecting to a domain whose DNS says it offers no XMPP service
- Rename the CLI's JSON keys and values to snake_case, which breaks scripts that read the old names
- Print only JSON records on the CLI's standard output under `--output json`

### Fixed

- Fix log lines going missing or cut short when the app and the CLI share a profile
- Fix the HTTP upload size limit being taken from an unrelated form the upload service lists
- Fix a sign-in refusal being misread as an unknown error when the server adds its own detail
- Stop presenting Ducko to other clients as a file upload, pubsub or block list service
- Fix a chat's offline notice promising that messages will send when you reconnect
- Fix the Join Room sheet keeping an earlier error after a new channel search starts

## [0.13.0] - 2026-11-18

### Added

- Let a server upgrade a stored SCRAM-SHA-1 password to a stronger hash during sign-in (XEP-0480) ([#3](https://github.com/ducko-im/ducko/issues/3))
- Show a server's registration CAPTCHA in the app and the CLI (XEP-0158, XEP-0221, XEP-0231)
- Show a fresh form after a refused registration, keeping its error and what you typed
- Stop a direct file transfer from its row or with `/cancel` in `ducko interactive`
- Show a direct file transfer's speed and time left, in the app and the CLI
- Type anywhere in a chat window to write a message, and keep keyboard focus where you left it

### Changed

- Show the server's registration form in a sheet over the Welcome window
- End `ducko presence --for` and `--keep-alive` cleanly when the terminal closes
- Explain why a server refused a sign-in partway through
- Tell the contact when you go offline or quit during a direct file transfer
- End a direct file transfer you are receiving when the contact goes offline or data stops arriving
- Mark a direct send delivered only once the contact confirms it arrived
- Send in-band direct transfers about four times as fast, without holding large files in memory

### Fixed

- Fix direct file transfers through a server's file transfer proxy stalling just before the end
- Fix the app freezing when VoiceOver reads a chat while a file transfer shows its progress

### Security

- Refuse a sign-in when the server asks for excessive password hashing, so it can't stall Ducko
- Never send a password over an unencrypted connection when changing it or registering while signed in

## [0.12.0] - 2026-11-15

### Added

- Sign in with SCRAM-SHA-512 and SCRAM-SHA3-512 when the server offers them ([#1](https://github.com/ducko-im/ducko/issues/1))
- Add `ducko account set` and `--allow-plain` to choose how an account may sign in
- Reset the encryption sessions with a contact or device when their messages can't be decrypted
- Mark messages decrypted from a device you haven't trusted, in the app and the CLI
- Honour a contact's request to receive unencrypted messages
- Read encrypted messages that arrived while you were offline once the archive is caught up

### Changed

- Distribute Ducko under the GNU GPL v3 alone, without the BoringSSL linking exception
- Never send an account's password to a server offering only plain sign-in, unless you allow it
- Report that refusal in the CLI's JSON `sign_in_refused` record as `plain_not_allowed`
- Wait up to two seconds for a group chat to describe itself before joining it
- Catch up on a group chat's archive once you have rejoined it
- Read message archives only from servers and group chats that announce one
- Explain in plain words why a sign-in failed instead of showing internal names
- Show encryption fingerprints in the standard OMEMO form, keeping the trust you already gave
- Encrypt only to the devices on each recipient's current device list
- Encrypt to your own other devices only when they are trusted, as for contacts
- Send encrypted group messages only in group chats that reveal their members' addresses
- Replace your encryption device's signed key every week
- Keep bookmarks working when another app set up the server's bookmark storage differently

### Fixed

- Stop duplicate messages appearing when the same archive range is read twice
- Skip archive pages the server reports as still changing and load them on a later try
- Restore your encryption device when another app removes it, and never reuse another device's id
- Fetch a contact's device list again when a message comes from a device not on it

### Removed

- Remove `ducko account reset-security`, which `ducko account set --allow-plain` replaces

### Security

- Stop someone who takes a group chat member's nickname from editing or retracting their messages
- Show a group chat message someone else posted under your nickname as theirs
- Trust a message's server-assigned id only from a server or group chat that announces such ids
- Stop a sign-in whose options or encryption version were tampered with on the way ([#2](https://github.com/ducko-im/ducko/issues/2), [#4](https://github.com/ducko-im/ducko/issues/4))
- Tie sign-ins to the encrypted connection on servers that support only the TLS 1.3 form
- Refuse a sign-in instead of dropping protection the server offers but Ducko can't use
- Ignore a request for unencrypted messages from a device you haven't trusted
- Drop elements meant for the server, such as delivery hints, found inside an encrypted message

## [0.11.0] - 2026-10-23

### Added

- Add a `nickname` field to the CLI's JSON typing and room subject records
- Add `kind` and `condition` to the CLI's JSON `authentication_failed` record, and a `setup_failed` disconnect reason

### Changed

- Offer Verify in Device Fingerprints only once a device's fingerprint is known

### Fixed

- Keep reconnecting after a lost connection until the server is reachable again
- Keep retrying an account that can't connect at launch, and wait while there is no network
- Notice a lost network or a server that stopped answering within seconds instead of minutes
- Say why a server's certificate is not trusted, and stop retrying a rejected certificate
- Ask for an imported account's password again only when the server rejects it
- Show a warning instead of "Import Complete" when no imported account could connect
- Start a fresh session when setup fails after connecting, instead of staying half connected
- Retry a sign-in the server stops answering after a minute, instead of waiting indefinitely
- Keep a server's wait between channel searches when the app and the CLI search at once
- Keep other apps' data in a bookmark when Ducko saves the bookmark again
- Stop assuming a contact still supports what its earlier client advertised
- Accept incoming file transfers from clients that need the receiver to name the sender
- Name the occupant in the REPL's room typing and topic lines
- Report a room topic set from the REPL only once the room accepts it
- Find a contact's OMEMO devices in the CLI whatever case the address is typed in

### Security

- Refuse an encrypted message that starts a new session from an untrusted device or unknown key
- Refuse a message from a session whose identity key doesn't match the device's fingerprint
- Keep refusing a used one-time pre-key, so a recorded message can't be replayed
- Refuse to trust a device whose stored fingerprints disagree

## [0.10.0] - 2026-10-21

### Added

- Add a `self` field to the CLI's JSON output for your own room departures and nickname changes
- Add Blocked Contacts to each account's Actions menu in Preferences ▸ Accounts
- Add `ducko blocklist list`, `add` and `remove`, and the REPL commands `/block`, `/unblock` and `/blocklist`
- Send replies that other XMPP apps show with their context, including in rooms
- Allow correcting, retracting and replying to messages in a private chat within a room
- Create accounts on servers that ask for more than a username and password
- Show a form's title, instructions, descriptions and required fields in registration and room settings
- Count down in Join Room until a server that limits channel searches allows the next one
- Follow avatar changes made on your account's other devices
- Show why an encrypted message can't be read instead of dropping it
- Add a `message_type` field to the CLI's JSON correction and retraction records

### Changed

- Send your Mac's name to the server when signing in with the newer sign-in method
- Encrypt with the current OMEMO format, which earlier versions of Ducko can't read
- Stop adding a plain-text hint to encrypted messages
- Publish avatars as PNG pictures of at most 512 pixels, accepting pictures of up to 50 MB
- Change the CLI's JSON `registration_form` record to list fields as objects and nest data forms

### Removed

- Remove the service outage warning, which never appeared

### Fixed

- Fix an encrypted message gaining an undecryptable twin after the next archive sync
- Keep contacts able to start encrypted chats with you by replacing used one-time keys
- Ignore a repeated key exchange instead of showing an old encrypted message again
- Keep your encryption device when its stored keys can't be read at sign-in
- Save encryption sessions and fingerprints learned from messages replayed after a resumed connection
- Show a conversation's newest message as its preview, even when an older one arrives later
- Stop counting your own messages sent from another device as unread
- Keep unblocking everyone, background-state updates and roster pre-approval working after a resumed connection
- Use the nickname a room assigns you when you join it
- Change your nickname when joining a room you're already in under another one, instead of timing out
- Stop an occupant who takes your earlier nickname from being treated as you
- Show your role controls in an open room window right after you rejoin under another nickname
- Color room nicknames the way other XMPP clients do
- Find channel search services that follow the published standard
- Show a room message that also carries a topic as a message instead of a topic change
- Tell the contact when a file link they offered can't be downloaded
- Keep your block list when another client unblocks an address that names a device
- Resume your session after a lost connection on servers that use the newer sign-in method
- Show messages from your other devices even when the server can't enable their copies at sign-in
- Show private messages within a room from your other devices in the right private chat
- Apply corrections and retractions made on other devices instead of ignoring them
- Apply corrections and retractions fetched from the server's archive instead of showing them as messages
- Fix other apps ignoring your retraction of a room message
- Keep the reply, attachment and receipt request of a message when you correct it
- Stop a correction, retraction or reply from reaching another message that shares its id
- Show messages delivered while you were offline, and a room's earlier messages, at the time they were sent
- Fetch every archived message since you were last online when you reconnect
- Send typing notifications only when your typing changes and only to contacts who use them
- Send your app's capabilities with every presence, including in rooms
- Keep other apps' bookmark data when saving, and sync bookmark removal and auto-join across devices
- Make direct file transfers work with more apps
- Decrypt encrypted messages you send or receive on another device instead of dropping them
- Decrypt encrypted room messages and private messages within a room
- Sign in to an account `ducko account register` created through the `--host` and `--port` it was given
- Hide what you type into a form's password fields, and keep every value of a multi-value field
- Accept passwords longer than 128 characters at the CLI's password prompt
- Remove your avatar on servers that can't share avatars
- Stop announcing a new avatar to contacts when it couldn't be saved to your profile
- Save your first avatar on servers that report a never-saved profile as missing
- Name the file `ducko avatar get` saves after the picture's actual format

### Security

- Refuse to save bookmarks on a server that can't keep them private
- Send only the headers an upload server is allowed to ask for, with line breaks removed
- Ignore bookmarks, avatars and device lists published by a single device instead of the account
- Tie sign-in to the encrypted connection when the server supports it
- Never use the newer sign-in method over an unencrypted connection
- Refuse a sign-in that would send the password once an account has signed in without sending it
- Show an encrypted message as untrusted when its sealed sender, recipient or time don't match
- Keep corrections and retractions of an encrypted message encrypted, even after turning encryption off
- Stop offering encryption in a private chat within a room, which Ducko can't encrypt
- Show only the encrypted content of an encrypted message, ignoring unencrypted parts sent alongside it

## [0.9.0] - 2026-10-18

### Added

- Show unread messages and typing on contacts in the Contacts window

### Changed

- Show a room's unread count in the Contacts window where its status dot sits
- Keep a contact with unread messages listed while Hide Offline Contacts is on

### Fixed

- Fix a contact's typing indicator staying on after they go offline
- Fix interactive mode and `ducko room join` printing room messages and the "Joined" line twice
- Fix a room that refused your join counting as joined
- Fix Ducko rejoining a room you had just left
- Fix your own `/me` messages reading "* You waves" instead of naming you
- Fix chats and the Contacts window losing names and photos when you go offline
- Fix room nicknames all showing in gray
- Fix Chat History naming contacts by their address instead of their contact list name
- Fix a reply to a contact's message showing their address instead of their name
- Fix room invitations and file offers naming the sender by their address
- Fix Chat History listing a message that arrived late out of time order
- Fix a private chat within a room showing "Couldn't load older messages: Invalid JID" at its start
- Fix messages from your other devices going missing when the server omits their sender address
- Fix archived encrypted messages showing the sender's OMEMO fallback text as if they wrote it
- Fix one-off CLI commands such as `ducko send` joining your bookmarked and remembered rooms
- Fix `ducko history --search` accepting `--before` and `--server` and then ignoring them
- Stop asking the server's archive about private chats within a room when you sign in
- Fix the name and size of a file you sent being hard to read on your message
- Fix the chat you were looking at counting as read after opening another chat in a new tab
- Fix encrypted messages failing to decrypt after a resumed connection or right after sign-in
- Fix a message that failed to send vanishing without an error
- Fix My Profile and `ducko avatar set` publishing files that aren't readable pictures
- Fix `ducko interactive` printing nothing for an incoming encrypted message
- Fix a delivery mark in a room sometimes landing on an older message of yours

### Security

- Ignore copies of your messages that claim to come from another of your devices instead of your server
- Keep addresses and nicknames out of the log file at the default log level

## [0.8.0] - 2026-10-08

### Added

- Add a search over all conversations to the Chat History window
- Add a find bar to the Chat History window (⌘F) that steps through matches across days
- Highlight the searched word inside matching messages, in Chat History and in a chat's find
- Allow selecting and copying part of a message's text, in chats and in Chat History
- Search every conversation of an account with `ducko history --search` or `/searchall`

### Changed

- Rename the Chat Transcripts window to Chat History
- Show every day of an account or an imported history when you select it in Chat History
- Show contact photos next to conversations and days in Chat History
- Open Chat History on your first account from the File menu
- Search a conversation's whole history with `ducko history --search`
- Find messages by attached file name in a chat's find, and never find retracted messages

### Removed

- Remove the conversation type filter from the Chat History toolbar
- Remove message counts and last-message dates from Chat History

### Fixed

- Fix the arrow keys not moving the selection after clicking a row in Chat History or Settings

### Security

- Prevent a message that stacks thousands of accents on one letter from freezing search

## [0.7.0] - 2026-10-06

### Added

- Add a Compact rows option in Settings ▸ Appearance that shows each contact and room on one line
- Add tooltips that show the full text of a cut-off name, status message, room topic or file name

### Changed

- Show the date above the first message of each day in a chat
- Show a multi-line status message, room topic or reply preview in full on one line

### Removed

- Remove themes, so Ducko always uses the former Default theme's look

### Fixed

- Fix a long status pushing your status and avatar against the Contacts window's edges
- Fix a long file name overflowing the placeholder for a missing image
- Fix the chat window briefly showing its header and tabs cut off while a chat opens
- Fix rooms no longer showing new messages or participants after a brief connection drop
- Fix room bookmarks staying empty after your connection briefly drops
- Fix rooms not being joined when your connection drops while Ducko is signing in
- Fix still appearing in a room to others after leaving it while your connection was down
- Fix a room staying disconnected without notice after an unexpected error from its server

## [0.6.0] - 2026-10-04

### Added

- Bring back the chat window and its tabs after relaunching Ducko
- Rejoin the rooms you are in whenever Ducko connects, until you leave them
- Add a button that jumps to the newest message while you are scrolled up
- Keep each chat's reading position when switching tabs

### Changed

- Mark a failed direct transfer with `error:` in `ducko interactive` and `/transfers`
- Use clearer wording in file transfer and encryption errors, Device Fingerprints and menu items
- Keep what you are reading in place when messages load or arrive, or the window resizes
- Count messages that arrive while you are scrolled up in a chat as unread
- Show that a contact is typing on the chat's tab only
- Leave a little space between the newest message and the message field
- Open chats, show incoming messages and resize the chat window faster in chats with a long history

### Fixed

- Fix link preview cards missing after relaunching Ducko or loading older messages
- Fix a contact's subscription request disappearing when your connection briefly drops
- Fix a folder being accepted for sending and failing only once the transfer started
- Fix messages changing height, and the chat shifting, when images, delivery marks or transfer updates arrive
- Fix scrolling back in a chat skipping or repeating messages, or loading the wrong part of history
- Fix a read receipt being sent for a chat you had already switched away from

### Security

- Prevent someone else from slipping messages into a chat's history while Ducko loads it from the server

## [0.5.0] - 2026-10-03

### Added

- Send a file straight to one of a contact's devices with Send Directly or `/senddirect`
- Switch a chat's encryption on when the contact sends an encrypted message
- Open a contact's chat in the background when they write or offer a file
- Show delivered and read as separate checkmarks on your messages, in the app and the CLI
- Show a typing bubble in a chat's tab while the contact types

### Changed

- Show a photo sent as a file as the photo itself instead of its link
- Load photos from contacts right away in one-to-one chats, and anyone else's only when clicked
- Trust a contact's new devices on first use by default
- Show an undecryptable encrypted message as a muted notice instead of text from the sender
- Offer Copy Link for a shared file in the message context menu, and no longer offer Edit for it
- Show code blocks in their own box with a copy button, and inline code in a monospaced font
- Insert a line break with Shift or Option plus Return, and send with the keypad's Enter key
- Show the typing indicator and a file being received as rows at the end of the chat
- Show a chat's unread count at the start of its tab, in place of the status dot
- Count a chat as read only while its window is focused
- Keep typing and presence updates coming while any Ducko window is on screen
- Title notifications with the contact's name from your contact list
- Upload a file with `ducko send --file` by default, and send directly with `--method jingle`

### Fixed

- Fix your profile picture disappearing for your contacts after you sign in or reconnect
- Fix line breaks being lost in messages that use styling or mention you
- Fix the status dot in a chat tab sitting further from the tab's edge than the name does
- Fix link previews being unreadable inside your own message bubbles
- Fix contacts showing as offline while online after one of their devices disconnects or you reconnect
- Fix "Last seen" jumping to the moment you connect for contacts who were already offline
- Fix unreadable text in history for imported messages that carry their own background color
- Fix encrypted messages that carry no text showing up as undecryptable
- Fix a failed file upload going unreported
- Fix uploaded files losing their original name
- Fix messages sent within the same second showing in the wrong order
- Fix a delivery checkmark or send error landing on the wrong message
- Fix a destroyed room reappearing when one of its messages arrives late

## [0.4.0] - 2026-09-24

### Added

- Take a single account offline or back online from its own submenu in the status menus

### Changed

- Group the status menus into All Accounts and Each Account sections when you have several accounts
- Show the header account's own status in the Contacts header, with a count of accounts showing another
- Connect every enabled account when you pick an online status for all accounts
- Keep the account you picked in the Contacts header while it is offline
- Turn on Connect on Launch for imported accounts unless their original settings turned it off

### Fixed

- Show "Not connected to the server" instead of an internal account ID while an account is offline

## [0.3.0] - 2026-09-23

### Added

- Add Get Info (⇧⌘I), History (⌘L) and Send File… (⇧⌘F) to the Contact menu, and ⌘⌫ for Remove Contact…
- Add a Status menu to the menu bar with Available (⇧⌘Y), a ⌘Y away toggle, and Custom…
- Add Close All Chats (⌥⌘W) to the File menu
- Add Select Next Tab (⌃⇥ or ⇧⌘]) and Select Previous Tab (⌃⇧⇥ or ⇧⌘[) to cycle through chat tabs
- Add Show/Hide Contact List (⌘/) to the Window menu
- Add a ⇧⌘H shortcut for Hide Offline Contacts

### Changed

- Fit the Settings window to the pane you are viewing
- Gather the account actions in Settings ▸ Accounts into an Actions menu
- Show the account and saved-status lists as bordered lists with add and remove buttons beneath them
- Ask for confirmation before removing a contact from the Contacts window
- Show the same account's status in the menu bar icon as in the Contacts header

### Removed

- Remove the Notifications settings pane, whose switches had no effect

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
- Remove incoming file offers once their account disconnects
- Fail a direct file transfer after two minutes when the recipient accepts but never connects
- Fail a direct file transfer that stalls for 30 seconds, instead of leaving it stuck

### Security

- Accept block list updates only from your own server

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
- Prevent a failed OMEMO device list read from removing your other devices from encryption

### Security

- Accept replies to requests only from the address they were sent to or your own server

## [0.1.0] - 2026-09-16

### Added

- Save files you accept to the Downloads folder and show them in the sender's conversation
- List file offers sent as links next to direct transfers in the offer banner and the CLI

### Changed

- Ask before loading an image a contact links to
- Accept or decline a file offer in the CLI by the id printed with it
- Show whether you have joined a room in the contact list

### Removed

- Remove requesting a file from a contact and changing files in a running transfer, which never worked

### Fixed

- Show a readable reason when signing in fails instead of internal error details
- Show readable error messages for connection, registration, file transfer, upload and encryption failures
- Fix Ducko quitting unexpectedly when the server connection or a file transfer drops while sending
- Fix Ducko crashing when the server closes an encrypted connection while messages are still being sent
- Fix connecting hanging indefinitely when a server stops responding during the encrypted handshake
- Fix connections staying open in the background after the server ends them
- Fix direct file transfers hanging when the contact or a proxy refuses or stops responding
- Fix completed direct file transfers later showing as failed, and a second Accept click stalling one
- Fix a rare crash in the update checker
- Fix direct file transfers reporting success when the file arrived incomplete or corrupted
- Fix accepting a link offer reporting the transfer complete without downloading anything
- Fix direct file transfers to clients such as Conversations stalling once they connect
- Fix your status in the Contacts header, account menu and menu bar not reflecting an account's own status

### Security

- Prevent a peer from freezing or crashing a direct file transfer with an invalid block size
- Prevent an attacker from slipping unencrypted messages into a connection while it switches to encryption
- Prevent anyone but the person you are transferring with from interfering with a direct file transfer
- Prevent a contact from disguising a file's name or saving it outside the Downloads folder
- Prevent a contact from opening a file on your own computer by sending a link to a local path
- Prevent accepting one file offer from acting on another offer that reuses its id

## [0.0.2] - 2026-09-14

### Added

- Show the first import errors in the Adium import summary, not just their count

### Fixed

- Fix signing in to servers that offer SASL2 authentication
- Import Adium chat history for Facebook, MSN, and ICQ contacts whose IDs contain `@` or spaces
- Show readable connection and server error messages instead of internal error codes

## [0.0.1] - 2026-09-14

Initial release.

[Unreleased]: https://github.com/ducko-im/ducko/compare/0.15.0...HEAD
[0.15.0]: https://github.com/ducko-im/ducko/compare/0.14.1...0.15.0
[0.14.1]: https://github.com/ducko-im/ducko/compare/0.14.0...0.14.1
[0.14.0]: https://github.com/ducko-im/ducko/compare/0.13.0...0.14.0
[0.13.0]: https://github.com/ducko-im/ducko/compare/0.12.0...0.13.0
[0.12.0]: https://github.com/ducko-im/ducko/compare/0.11.0...0.12.0
[0.11.0]: https://github.com/ducko-im/ducko/compare/0.10.0...0.11.0
[0.10.0]: https://github.com/ducko-im/ducko/compare/0.9.0...0.10.0
[0.9.0]: https://github.com/ducko-im/ducko/compare/0.8.0...0.9.0
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
