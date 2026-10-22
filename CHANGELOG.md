# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add a `nickname` field to the CLI's JSON typing and room subject records when a room occupant is typing or set the subject
- Add `kind` and `condition` fields to the CLI's JSON `authentication_failed` record, telling a rejected password apart from a temporary server failure, and a `setup_failed` disconnect reason

### Fixed

- Keep reconnecting after a lost connection until the server is reachable again, instead of staying offline after one failed attempt, and stop reconnecting when the server ends the session for a reason that won't clear by itself, such as another session taking it over
- Keep retrying an account that cannot connect at launch or after its server redirects it, and wait while there is no network instead of retrying, showing "No network connection" until it returns
- Notice a lost network within seconds, and a server that stopped answering within 30 seconds of a keepalive ping, instead of only at the next five-minute ping
- Say why a server's certificate is not trusted, such as that it was issued for a different server or has expired, and stop retrying a connection whose certificate was rejected
- Ask for an imported account's password again only when the server rejects it, and list the account as failed with its own reason for any other sign-in failure
- End a session whose setup fails after connecting and start a fresh one when the failure can clear by itself, instead of leaving the account half connected
- Give up on a sign-in the server stops answering after a minute and try again, instead of waiting indefinitely
- Keep the wait a server asks for between channel searches when the app and the CLI search at the same time, and honor a wait given in fractions of a second
- Keep other apps' data in a bookmark as they wrote it when Ducko saves the bookmark again
- Name the occupant in the REPL's room typing and topic lines, and print no topic line when joining a room that has none

## [0.10.0] - 2026-10-21

### Added

- Add a `self` field to the CLI's JSON output when a room departure or nickname change is your own
- Add Blocked Contacts to each account's Actions menu in Preferences ▸ Accounts, listing every blocked address, including one that blocks a single device of a contact, with a field to block any address and a button to unblock each one
- Add `ducko blocklist list`, `add` and `remove`, and the REPL commands `/block`, `/unblock` and `/blocklist`
- Send replies that other XMPP apps show with their context: a reply starts with a quote of the message it answers, which apps that understand replies hide, and replies now work in rooms
- Allow correcting, retracting and replying to messages in a private chat within a room, in the chat window and with `/edit`, `/retract` and `/reply` in the REPL
- Create accounts on servers that ask for more than a username and password: Ducko fetches the server's form first and shows its further fields and instructions with what you typed filled in, or the web page the server sends you to, and registers only once every field the server asks for has a value. `ducko account register` and the REPL's `/submit-registration` prompt for those fields until each has a value, and name the web page instead of submitting an empty form
- Show a form's title, instructions, fixed text, field descriptions and required fields in registration and room settings forms, in the app and the CLI, and keep Register, Submit and Save unavailable until every required field has a value
- Count down in Join Room until a server that limits channel searches allows the next one, and report the wait from `ducko room list --search`. The wait survives quitting Ducko and applies to the app and the CLI alike
- Follow avatar changes made on your account's other devices
- Show why an encrypted message can't be read instead of dropping it: it was not encrypted for this device, it uses another method such as OpenPGP, it carries nothing to decrypt, or its room does not reveal who sent it. This includes room messages with no text of their own, announcement messages, corrections, which no longer replace a message's text with their fallback text, and messages you sent from another device under your room nickname
- Add a `message_type` field to the CLI's JSON correction and retraction records

### Changed

- Send your Mac's name to the server when signing in with the newer sign-in method, so the server can name the device a session belongs to
- Encrypt with the current OMEMO format, so encrypted chats work with other apps that use it. Encrypted chats with earlier versions of Ducko stop working until both sides update, and each encrypted chat starts a new session
- Stop adding a plain-text hint to encrypted messages: apps that can't decrypt them show their own notice instead
- Publish avatars as PNG pictures of at most 512 pixels on each side, scaling down a larger picture so you can choose one of up to 50 MB instead of 8 MB, and don't publish one on a server that cannot share it
- Change the CLI's JSON `registration_form` record: a form's fields are listed as objects, and a data form is nested under `form`, replacing the `has_*` and `field_*` keys. In JSON, `/config` prints the room settings form as one `data_form` record

### Removed

- Remove the service outage warning, which never appeared because it relied on an announcement servers don't send

### Fixed

- Fix an encrypted message that decrypted on arrival gaining an undecryptable twin after the next archive sync, and show the text of a message stored as undecryptable once another copy of it decrypts
- Keep contacts able to start encrypted chats with you: replace used one-time keys and publish the change during the session, including after a resumed connection, and erase a used key from storage
- Ignore a repeated key exchange instead of showing an old encrypted message again, and reject one that names a key Ducko does not have
- Keep your encryption device when its stored keys cannot be read at sign-in, instead of quietly creating a new one
- Save the encryption sessions and contact fingerprints learned from messages the server replays after a resumed connection
- Show a conversation's newest message as its preview, even when an older one arrives later
- Stop counting your own messages sent from another device as unread
- Keep unblocking everyone, background-state updates and roster pre-approval working after a resumed connection
- Use the nickname a room assigns you when you join it
- Change your nickname when you join a room you are already in under another one, instead of timing out, and finish at once when the nickname is the same
- Stop another occupant who holds your earlier nickname from changing which room messages count as yours, or from turning off rejoining when they are kicked or renamed
- Show your role controls in an open room window right after you rejoin under another nickname
- Color room nicknames the way other XMPP clients do
- Find channel search services that follow the published standard, and show rooms they mark as open as open
- Show a room message that also carries a topic as a message instead of a topic change, and clear the room's topic when someone clears it
- Tell the contact when a file link they offered cannot be downloaded, which ends the offer instead of leaving it open for another try
- Keep your block list when another of your clients unblocks an address that names a device
- Resume your session after a lost connection on servers that use the newer sign-in method, instead of starting a new one
- Show messages you send or receive on another device even when the server can't turn on their copies during sign-in
- Show private messages within a room that you send or receive on another device in that private chat, instead of a chat with the room's address, and stop saving invitations and error replies copied from your other devices as messages
- Apply corrections and retractions made on your other devices, or by a contact on theirs, instead of ignoring them, and stop the CLI from printing the fallback text of a retraction made on another device
- Apply corrections and retractions fetched from the server's archive instead of showing them as new messages or showing a retraction's fallback text
- Fix other apps ignoring your retraction of a room message: it now names the id the room gave the message, and others' room retractions are matched the same way
- Keep the reply, attachment and receipt request of a message when you correct it
- Stop a correction, retraction or reply from reaching another message that happens to share its id, by giving every message an id that's never reused and matching only messages from the same sender
- Show messages delivered while you were offline, and the earlier messages a room shows when you join it, at the time they were sent, and stop the room's earlier messages from counting as unread or alerting you
- Fetch every message the server's archive holds since you were last online when you reconnect, not only the newest 50 of each chat you already had, and open the chats that exist only on the server
- Send typing notifications only when your typing changes, stop sending them to a contact whose messages carry none, even after reconnecting, and send them to rooms as room messages instead of one-to-one messages
- Send your app's capabilities with every presence, including when you join a room or change your nickname there, and check the capabilities contacts announce before relying on them
- Keep other apps' data in a bookmark when Ducko saves it, failing the save when that data can't be fetched first, tell your other clients when you remove one, and join or leave a room when another device turns its bookmark's auto-join on or off
- Make direct file transfers work with more apps: accept one offered over the in-band fallback first, send in the smaller blocks the receiver asks for, try the receiver's connection offers too, settle on one fallback when both sides switch to it at once, refuse data sent after a transfer was closed, and answer every transfer request, including ones Ducko does not support
- Decrypt encrypted messages you send or receive on another device and show them in the chat with the other person, instead of dropping them
- Decrypt encrypted room messages and private messages within a room, and show them under the sender's nickname
- Sign in to an account `ducko account register` created through the `--host` and `--port` it was given
- Hide what you type into a form's password fields, and keep every value of a field that takes several
- Accept passwords longer than 128 characters at the CLI's password prompt, and refuse one too long to read whole instead of cutting it short
- Remove your avatar on a server that cannot share avatars, by clearing it from your profile
- Stop announcing a new avatar to contacts when it could not be saved to your profile, and stop a profile save from bringing back an avatar you changed elsewhere
- Save your first avatar to your profile, and tell contacts when you have none, on servers that report a profile never saved before as missing
- Name the file `ducko avatar get` saves, and the type it reports, after the picture's actual format instead of the type the profile claims

### Security

- Refuse to save a bookmark, which can hold a room password, on a server that cannot keep it private
- Send only the authorization, cookie and expiry headers an upload server asks for, with line breaks removed
- Ignore published bookmarks, avatars and encryption device lists that come from a single device or room occupant instead of the account they belong to
- Tie sign-in to the encrypted connection when the server lists a way of doing so that Ducko supports, though someone holding a certificate your Mac trusts for the server can still make Ducko sign in without it
- Never use the newer sign-in method over an unencrypted connection
- Once an account has signed in without sending its password, refuse a later sign-in that would send it, which can mean someone is intercepting the connection. The Sign-In Refused alert lets you keep refusing or reset this, as does `ducko account reset-security`
- Show an encrypted message as untrusted when the sender, recipient or time sealed inside it don't match how it arrived
- Keep corrections and retractions of an encrypted message encrypted even after you turn encryption off, and refuse to send one that can't be encrypted instead of sending it in the clear
- Stop showing a lock in a private chat within a room, which Ducko cannot encrypt: the chat offers no Encryption menu, and one whose encryption an earlier version turned on refuses to send until you turn it off
- Show only the encrypted content of an encrypted message, ignoring unencrypted text, file links, reply references, corrections, retractions, room topics and invitations sent alongside it, including in private messages within a room, in messages fetched from the server's archive, and in the CLI's output for messages from your other devices

## [0.9.0] - 2026-10-18

### Added

- Show unread messages and typing on contacts in the Contacts window, where their status dot sits and as on chat tabs, so you can see who wrote or is writing without opening the chat window

### Changed

- Show a room's unread count in the Contacts window where its status dot sits, matching contacts and chat tabs
- Keep a contact with unread messages in the Contacts window while Hide Offline Contacts is on, until you read them

### Fixed

- Fix a contact's typing indicator staying on after they go offline
- Fix interactive mode and `ducko room join` printing each room message, each private message from a room and the "Joined" line twice
- Fix a room that refused your join (wrong password, banned, nickname taken) counting as joined, with you listed as its only occupant
- Fix Ducko rejoining a room you had just left when a check of your presence in the room was answered at the same moment
- Fix your own `/me` messages reading "* You waves" in a chat and showing the other person's address in Chat History: they now name you, by your nickname in a room and in a private chat within one
- Fix an open chat losing the contact's name and photo, and the Contacts window losing your own photo, when you go offline
- Fix room nicknames all showing in gray: each occupant's name and picture now has its own color, and the participant list colors names to match
- Fix Chat History naming contacts by their address: conversations, days and `/me` lines now use the names your contact list shows
- Fix a reply to a contact's message showing their address instead of their name, in its quote and in the bar above the message field, which now also says when you reply to yourself
- Fix room invitations and offers of a file naming the sender by their address: they now use the name your contact list shows, and keep the address for someone not in it
- Fix Chat History listing a message that arrived late out of time order
- Fix a private chat within a room showing "Couldn't load older messages: Invalid JID" when scrolled to its start
- Fix messages you sent or received on another device going missing when the server sends their copies without a sender address
- Fix messages in an encrypted chat that were fetched from the server's archive showing the sender's "This message is OMEMO encrypted" fallback as if they had written it: they now read "This message could not be decrypted"
- Fix one-off CLI commands such as `ducko send` joining your bookmarked and remembered rooms, so everyone there saw you join and leave. Only `ducko interactive` joins them
- Fix `ducko history <address> --search` accepting `--before` and `--server` and then ignoring them: both are now refused with `--search`
- Stop Ducko asking the server's archive about a private chat within a room when you sign in, which could fill it with messages from the room's other private chats
- Fix the name and size of a file you sent being hard to read on your message: they now sit on a darker card, and a file that is not on this Mac no longer looks grayed out
- Fix the chat you were looking at counting as read after you opened another chat in a new tab, while that tab was still loading or for good when it failed to load
- Fix encrypted messages reading "This message could not be decrypted" when they arrive after a dropped connection picks up where it left off, or right after you sign in
- Fix a message that failed to send because the connection dropped or encryption failed vanishing without a word: the error now shows, your text comes back, and a reply or correction that fails stays one for another try
- Fix My Profile and `ducko avatar set` publishing any chosen file as your picture: a file that is not a readable picture, or one over 8 MB, is now refused with a message saying so
- Fix `ducko interactive` printing nothing for an incoming encrypted message: it now shows it as it arrives, like any other message
- Fix a delivery mark in a room, or in a private chat within one, sometimes landing on an older message of yours instead of the one you just sent

### Security

- Ignore copies of your messages that claim to come from another of your devices instead of from your server, so nothing but your server can add them to your chats
- Keep the addresses of rooms, contacts, your account and the services you use, room nicknames and the senders of room invitations out of the log file at the default log level

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

[Unreleased]: https://github.com/ducko-im/ducko/compare/0.10.0...HEAD
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
