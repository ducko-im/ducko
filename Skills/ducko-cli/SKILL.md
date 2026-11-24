---
name: ducko-cli
description: "Operate the Ducko XMPP CLI tool. Use when asked to send XMPP messages, start an interactive XMPP session, list accounts, check roster, view history, manage presence, or test the CLI, including scripted REPL sessions against a live account and smoke-testing stream-level behavior (STARTTLS, stream features) against a local stub server. Covers running commands, authentication, output formats, and all subcommands."
---

# Ducko CLI

## Quick Start

```
ducko <subcommand> [options]
ducko --help
```

Default subcommand is `interactive` (REPL mode).

## Authentication

Password lookup order: macOS Keychain first, then prompt on `/dev/tty` if stdin is a TTY. Accounts can be created with `ducko account add <jid>` or in DuckoApp — the CLI and GUI share the same SwiftData database and Keychain.

## Global Options

| Option | Description |
|---|---|
| `--output plain\|ansi\|json` | Output format. Defaults to ANSI in terminal, plain when piped. |
| `--account <uuid>` | Select account by UUID. Uses first account if omitted. |

Each subcommand declares these options itself. Some reject them with "Unknown option", including `account add` and `account delete`. Pass them after the full subcommand path (e.g. `roster list --output json`).

## Subcommands

Unless noted otherwise, each subcommand connects, performs its action, and disconnects.

### `send [--file <path>] [--method auto|http|jingle] <jid> [body]`

Send a message or file, then disconnect. At least one of `--file` or `body` is required. When both are provided, the file is uploaded first, then the body is sent as a separate caption message.

`--method auto` (the default) and `http` upload the file over XEP-0363. `jingle` sends it peer-to-peer over XEP-0234 and returns only once the contact has accepted and received it, or the transfer has failed. With a full JID, `jingle` sends to that session. With a bare JID it picks one of the contact's online sessions that takes direct transfers. That needs the contact's presence to have arrived, so in this connect-send-disconnect command a full JID is the reliable form. A direct send appears in the chat's history as a sent file. It is marked `[delivered]` once the contact confirms it arrived, or `[error: <reason>]` when it fails. The contact has 30 seconds to confirm after the last bytes go out. For an in-band transfer, the 30 seconds start once the contact answers the stream's close, or once the close fails. A send left unconfirmed fails as `[error: The contact did not confirm the transfer]`.

```
ducko send alice@example.com "Hello"
ducko send --file photo.jpg alice@example.com
ducko send --file photo.jpg alice@example.com "Check this out"
ducko send --file photo.jpg --method jingle alice@example.com/resource
```

### `interactive` (default)

REPL mode. Connects once, then accepts commands on stdin:

- `send <jid> <message>` — send a message (auto-detects rooms)
- `/roster` — show contacts grouped with presence indicators
- `/status [status] [message]` — get or set presence status
- `/who` — show online contacts only
- `/history <jid> [limit]` — show message history (default 20 messages)
- `/join <room> [nickname]` — join a MUC room (sets as current room)
- `/leave [room]` — leave a MUC room (uses current room if omitted)
- `/members [room]` — show room occupants
- `/pm <nickname> <message>` — send private message to a room occupant (current room)
- `/topic [room] [text]` — view or set room topic
- `/nick <nickname>` — change nickname in current room
- `/destroy [reason]` — destroy current room (owner only)
- `/voice grant|revoke <nickname>` — grant or revoke voice (moderator only)
- `/affiliations [member|admin|owner|outcast]` — list affiliations (default: member)
- `/config [submit-default]` — show the room configuration form, or submit the defaults to unlock a new room. The form shows its title, instructions and fixed text, and each field with its description and a `(required)` marker, with text-private values as `********`. In JSON it is one `data_form` record with `title`, `instructions` and a `fields` array, which `/check-registration` nests under `form`
- `/rooms [service]` — discover available rooms on MUC service
- `/sendfile [jid] <path>` — send a file (uses current room if jid omitted)
- `/senddirect <jid> <path>` — send a file straight to one of the contact's online devices (XEP-0234) instead of uploading it. The contact's devices are asked first. The command prints an error when the file is missing or is a folder, or when no device takes direct transfers. Otherwise it prints `Sending <file> to <jid> directly. Use /transfers to check progress.` and the prompt returns. A decline, or a transfer that fails once under way, is printed when it happens. A failure before that point, such as the device refusing the offer or the file's contents not being readable, prints nothing and shows only in `/transfers` and the history.
- `/accept [id]` — accept an incoming file offer (Jingle or link) and save it to `~/Downloads`. The id is the one printed in the `[File offer]` line. Without an id, it takes this account's newest offer.
- `/decline [id]` — decline an incoming file offer. Without an id, it takes this account's newest offer.
- `/cancel [sid]` — cancel a direct file transfer still under way, sent or received, and tell the contact. The sid is the one `/transfers` prints. Without a sid, it takes this account's newest one. Prints `Canceled file transfer: <file>` once it stopped the transfer. When there is none to stop, it prints the error `Transfer not found: <sid>`, or `No direct file transfers under way.` without a sid. A transfer that ended just as it was canceled gets the same error.
- `/transfers` — list active file transfers with progress. A direct transfer moving bytes also shows its rate and time left once it has run for a second, e.g. `report.pdf (5 MB) [outgoing/jingle] transferring 50% · 250 kB/s · 10 sec left (sid: <sid>)`
- `/add <jid> [name]` — add contact to roster
- `/remove <jid>` — remove contact from roster
- `/approve <jid>` — approve subscription request
- `/deny <jid>` — deny subscription request
- `/block <jid>` — block an address, as `blocklist add` does
- `/unblock <jid>` — unblock exactly that entry, as `blocklist remove` does
- `/blocklist` — fetch and show the block list, as `blocklist list` does
- `/avatar [jid]` — view avatar info (own if no JID, contact's if given)
- `/profile` — view own vCard profile
- `/connection-info` — show TLS connection info (protocol, cipher, certificate)
- `/encrypt <jid> on|off` — toggle OMEMO encryption for a conversation. `off` also keeps a contact's encrypted message from switching it back on.
- `/omemo-verify <jid> <device-id> <fingerprint>` — mark a device verified after comparing its fingerprint, as `omemo verify` does
- `/omemo-reset <jid> [device-id]` — reset the OMEMO sessions with the contact's devices, or with your other devices for your own JID, as `omemo reset` does
- `/pref chatstates on|off` — toggle chat state notifications (typing indicators)
- `/pref markers on|off` — toggle displayed markers (read receipts)
- `/reply <jid> <message>` — reply to the last incoming message from JID, or in the room JID, skipping a room message without an id from the room. Ducko accepts a room's ids only when its disco#info lists `urn:xmpp:sid:0`. The reply starts with a quote of that message, unless the message was encrypted and the reply is not.
- `/retract <jid>` — retract last sent message to JID (a room message only once the room has echoed it, in a room whose disco#info lists `urn:xmpp:sid:0`)
- `/edit <jid> <new-body>` — edit last sent message to JID
- In `/reply`, `/retract` and `/edit`, `room@service/nick` names the private chat with that occupant. An address that names none of the account's chats, such as a contact's full JID, is reported as an error.
- `/moderate [reason]` — moderate last message in current room (MUC moderator)
- `/search <jid> <query>` — search the whole message history with JID. Prints the newest 20 matches, oldest first.
- `/searchall <query>` — search all the account's conversations, as `history --search <query>` does. Prints the newest 20 matches.
- `/directed-presence <jid>` — send directed presence to a JID
- `/check-registration [jid]` — show server registration form
- `/submit-registration [jid]` — submit registration to server/component. It prompts for every field the form asks for: a legacy form's elements, such as username, password, nick, name and email, all of them required, or a data form's fields. Enter keeps the current value. A required field asks again until it has one. Input that ends at a field's prompt submits nothing. A form that only names a web page is printed and not submitted. The legacy password and a text-private field read hidden input of at most 4094 bytes from the terminal. Without a terminal, a text-private field keeps its value, and a required one that has none ends with `No <field> provided…`. A boolean field takes yes or no (also y/n, on/off, true/false, 1/0) and asks again on any other answer. A list field takes only a listed option's value or label, comma-separated for list-multi. Text-multi and jid-multi read lines up to an empty one, and jid-multi also splits on commas.
- `/change-password` — change the account's password on the server, as `account change-password` does, then print `Password changed.`
- `/unregister-account` — unregister account from server
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

Interactive mode also prints async events as they arrive: typing indicators, delivery receipts, read markers, message corrections, Jingle transfer state changes, and MUC lifecycle events (`[new room]`, nickname changes, room destruction). Terminal bell rings on incoming messages and file transfer offers. A direct transfer's progress line names its sid. Once the transfer has run for a second, the line also shows the rate and the time left, as in plain output: `<sid> (<size>): transferring 50% · 250 kB/s · 20 sec left`.

```
ducko interactive
```

### `history [<jid>]`

View message history from the local database. With `--server`, connects to fetch from the XMPP server. The JID can be left out only together with `--search`.

| Option | Description |
|---|---|
| `--limit <n>` | Maximum number of messages (default: 20) |
| `--before <date>` | Show messages before this ISO 8601 date (pagination). Does not work with `--search`. |
| `--search <query>` | Show the newest messages that contain the keyword |
| `--server` | Fetch from server when local history is empty (requires connection). Does not work with `--search`. |

```
ducko history alice@example.com
ducko history alice@example.com --limit 5
ducko history alice@example.com --before 2026-03-01T00:00:00Z
ducko history alice@example.com --output json --limit 10
ducko history alice@example.com --server
ducko history alice@example.com --search invoice
ducko history --search invoice --limit 50
```

`--search` reads the whole stored history, not only its newest messages. A message matches when its text or the name of a file attached to it contains the keyword, ignoring case and diacritics. A retracted message never matches. Timeline notes are not printed.

With a JID it prints the newest matches of that conversation, up to `--limit`, oldest first.

Without a JID it covers every conversation of the selected account and prints the newest matches, up to `--limit`. They are grouped by conversation and UTC day, newest day first. Each group starts with a line naming the conversation, the day and the number of matches printed for it. Its matches follow, oldest first:

```
--- alice@example.com, 2026-03-12 (2 matches) ---
[2026-03-12T09:14:00.000Z] <- alice@example.com: The invoice is attached
[2026-03-12T09:20:00.000Z] -> alice@example.com: Got the invoice, thanks
--- bob@example.com, 2026-03-10 (1 match) ---
[2026-03-10T16:02:00.000Z] <- bob@example.com: Which invoice do you mean?
```

In JSON that line is a record of its own: `{"count":"2","day":"2026-03-12","jid":"alice@example.com","type":"search_day"}`.

A private chat with a room's occupant is named by the occupant's address, `room@conference.example.com/nick`, in the line and in the record's `jid`. The room itself keeps its bare address.

Without `--server`, `history` reads only the local database, but it still exits with "No accounts configured" until an account exists. Imported Adium conversations stay unlinked until their Adium source account itself is added: run `account add --no-connect` with the exact JID the import stored (the plain JID for Jabber/GTalk, `<escaped UID>@<service>.adium-import` otherwise). That account must also be the one `history` selects, the first account or `--account <uuid>`. Any other account passes the check but prints "No messages found."

A JID starting with `-` (an escaped Facebook import such as `-123\40chat.example.com@facebook.adium-import`) parses as an option: put the options first, then `--`, then the JID.

```
ducko account add --no-connect --password x -- '-456\40chat.example.com@facebook.adium-import'
ducko history --limit 5 -- '-123\40chat.example.com@facebook.adium-import'
```

### `account list`

List all configured accounts. Supports `--output` format. Plain and ANSI lines end with the sign-in settings, such as `PLAIN: refused, TLS: required`. With `--output json` it prints one JSON object per line rather than an array, and `is_enabled`, `allows_plain` and `require_tls` are the strings `"true"` or `"false"`.

```
ducko account list
ducko account list --output json
```

### `account add <jid> [--password <password>] [--host <host>] [--port <port>] [--no-connect] [--allow-plain]`

Add a new XMPP account. By default it connects to verify credentials and saves the password. Password is prompted interactively if `--password` is omitted. `--host`/`--port` override the connection endpoint (a bare `--port` without `--host` is rejected). With `--no-connect` the account is persisted *without* connecting or verifying credentials — offline/manual setup; the password is still saved. `--allow-plain` lets the account send its password to a server that offers only PLAIN (see `account set`). Without it, Ducko refuses to sign in to such a server and rolls the new account back. Stderr then names the command that tries again, `ducko account add <jid> --host <host> --port <port> --allow-plain`, with only the `--host`/`--port` that were given.

When authentication fails, the command exits 1 and prints `Error: Authentication failed: <reason>`, where the reason is readable text such as "Incorrect username or password".

`account add` has no `--output` option, so to observe that failure as JSON, add the account with `--no-connect` and run a connecting subcommand with `--output json`, such as `profile`. It uses the first account unless `--account <uuid>` is passed. It emits `{"account":"<uuid>","condition":"not-authorized","kind":"credentials_rejected","message":"<reason>","type":"authentication_failed"}`. `kind` is `credentials_rejected` for a rejected password, `temporary` for a server failure that can clear by itself, and `other` for anything else. `condition` is the server's raw failure condition, either a SASL `<failure>` condition such as `not-authorized` or a SCRAM `e=` value such as `invalid-proof`. It is absent when the server sent neither.

```
ducko account add alice@example.com
ducko account add alice@example.com --password secret
ducko account add alice@example.com --password secret --host 127.0.0.1 --port 5222 --no-connect
```

### `account delete <jid>`

Delete an XMPP account by JID. Disconnects if connected, removes the account from the local database, and deletes stored credentials.

```
ducko account delete alice@example.com
```

### `account set <jid> [--allow-plain|--no-allow-plain] [--require-tls|--no-require-tls]`

Changes an account's sign-in settings without connecting, then prints the account as `account list` does (`--output` is supported). An omitted setting stays as it is. Passing neither, or both forms of one flag, fails with a usage error.

By default an account refuses to sign in to a server that offers only PLAIN, the mechanism that sends the password itself. The app and the CLI share this setting. A sign-in that verifies a SCRAM server signature turns PLAIN off again.

A refused connect exits 1 with `Error: Sign-in refused: …`. Its event line is the refusal text, and stderr follows it with `Run 'ducko account set <jid> --allow-plain' to send the password to this server.` in every output mode. In JSON the event is `{"account":"<uuid>","message":"<text>","reason":"plain_not_allowed","type":"sign_in_refused"}`. It is not an authentication failure, so the password is not to blame.

```
ducko account set alice@example.com --allow-plain
ducko account set alice@example.com --no-require-tls --allow-plain
```

To stage a refusal against the stub server, which offers only PLAIN, add its account as [references/stub-server-smoke-testing.md](references/stub-server-smoke-testing.md) shows, but leave PLAIN off with `ducko account set <jid> --no-require-tls --no-allow-plain`.

To check which SCRAM mechanism a sign-in verified, for example that a server-requested credential upgrade moved the account to a stronger hash on its next sign-in, read `DUCKO_PROFILE=<unique> .build/debug/DuckoCLI logs show --lines 300` for `Signed in with <mechanism>, so a sign-in offering only PLAIN is refused from now on`. A sign-in that verifies a SCRAM server signature logs that info line once it has turned PLAIN off, or `Could not record that the account no longer sends its password to a server offering only PLAIN` when saving that fails. A PLAIN sign-in logs neither.

### `roster list`

List an authoritative, locally saved snapshot for the selected account, grouped with current presence indicators. Waits up to 15 seconds for the identified full roster response to be saved. An empty snapshot completes successfully; JSON emits a `roster_empty` record.

```
ducko roster list
ducko roster list --output json
ducko roster list --account <uuid>
```

Plain output shows `[+]` available, `[~]` away/xa, `[-]` dnd, `[ ]` offline. ANSI uses colored dots. JSON outputs one line per contact/group header.

### `roster add <jid> [--name <name>] [--group <group>]`

Add a contact to the roster and send a presence subscription request. Full completion requires server acknowledgement and a saved full roster readback. A sent presence request does not mean the peer approved it.

Add/remove follow-up is bounded to five seconds from acknowledgement. Exit 0 means full completion. Exit 3 means the server confirmed the change but local synchronization or subscription transmission is incomplete, or the current roster differs from the request.

Inspect or synchronize the roster before another mutation. Do not automatically retry a confirmed change. Rejection and unconfirmed remote outcomes remain distinct errors.

JSON includes operation, account, JID, remote/local status, and subscription status. The REPL prints the same result and stays open.

```
ducko roster add alice@example.com
ducko roster add alice@example.com --name "Alice" --group "Friends"
```

### `roster remove <jid>`

Remove a contact from the roster (roster remove).

```
ducko roster remove alice@example.com
```

### `profile`

View own vCard profile.

```
ducko profile
ducko profile --output json
```

### `presence [status] [message]`

Get or set presence status. Without arguments, shows current presence. With a status argument, sets presence.

Valid statuses: `available`, `away`, `xa`, `dnd`, `offline`.

```
ducko presence                    # show current
ducko presence away "brb"         # set away with message
ducko presence available          # set available
ducko presence --output json      # JSON output
```

### `bookmarks list`

List server-side PEP bookmarks.

```
ducko bookmarks list
ducko bookmarks list --output json
```

### `bookmarks add <jid> [--name <name>] [--nickname <nick>] [--autojoin] [--password <pw>]`

Add a bookmark for a room. Publishes to PEP with XEP-0223 persistent storage options.

```
ducko bookmarks add chat@conference.example.com --name "Main Chat" --autojoin
ducko bookmarks add chat@conference.example.com --nickname alice --autojoin
```

### `bookmarks remove <jid>`

Remove a bookmark. Retracts the PEP item.

```
ducko bookmarks remove chat@conference.example.com
```

### `blocklist list`

List the account's block list (XEP-0191) as the server holds it, one address per line, sorted. An entry is a bare JID or a full JID, which blocks only that device of the contact. JSON emits one `block_list_entry` record (`jid`) per entry, or `block_list_empty` (with `account`). Against a server that does not advertise blocking, every `blocklist` subcommand exits 1 and prints `Error: The server does not support blocking`.

```
ducko blocklist list
ducko blocklist list --output json
```

### `blocklist add <jid>`

Block an address, which need not be in the roster. A full JID blocks only that device. Prints `Blocked <jid>.` once the server confirms.

```
ducko blocklist add spam@example.com
ducko blocklist add alice@example.com/laptop
```

### `blocklist remove <jid>`

Unblock exactly the entry the address names, as `blocklist list` prints it: removing a contact's bare JID leaves the entries for their devices in place. Prints `Unblocked <jid>.` once the server confirms.

```
ducko blocklist remove alice@example.com/laptop
```

### `avatar get <jid> [--save <path>]`

Fetch and save a contact's avatar. Tries PEP (XEP-0084) first, falls back to vCard (XEP-0054). By default it saves to `<jid>.<ext>`, with the extension taken from the avatar's MIME type (`png` if the type is unknown).

```
ducko avatar get alice@example.com
ducko avatar get alice@example.com --save alice.jpg
```

### `avatar set <path>`

Publish own avatar from an image file, converted to PNG and scaled down to at most 512 pixels on its longer side. Checks the account's server for PEP first, and without it exits 1 with `Error: The server cannot share avatars, so the picture was not published`. It publishes via PEP and updates vCard if server lacks XEP-0398 conversion. Prints the PNG's hash and size.

```
ducko avatar set photo.png
```

### `account register --server <domain> --username <user> --password <pw> [--email <email>] [--host <host>] [--port <port>]`

Register a new account on a server via XEP-0077 In-Band Registration. Fetches the server's form first and registers on the same connection, then saves the account locally and signs in. With `--host`, and `--port` when given, every connection goes through that endpoint. When the form asks for more than username, password and email, or for an email `--email` did not give, the command prints it. It does the same with a fresh form when the server refuses the registration. It then prompts for the form's fields as `/submit-registration` does, with the given values filled in. A form that only names a web page is printed, and the command exits 1. The new account starts with PLAIN allowed, since the registration already gave the server the password over TLS. A sign-in that verifies a SCRAM server signature turns it off (see `account set`).

```
ducko account register --server example.com --username alice --password secret
ducko account register --server example.com --username alice --password secret --email alice@mail.com
```

### `account check-registration --server <domain> [--host <host>] [--port <port>]`

Fetch and display a server's XEP-0077 registration form without registering: its instructions (a data form's own, not the reply's), the web page it names for registering (`Register at:`), and every field it asks for, with the password obscured. Useful for inspecting required fields or CAPTCHAs before calling `account register`. In JSON, the `registration_form` record carries `redirect_url`, a legacy form's `fields` as `{name, value}` objects (every one required), and a data form under `form`.

```
ducko account check-registration --server example.com
```

### `account change-password <jid>`

Change an account's password on its server via XEP-0077 and save the new one, then print `Password changed: <jid>`. It prompts twice for the new password, reading hidden input from the terminal.

It exits 1 without asking the server when:

- the first entry is empty: `The new password is empty.`
- the second entry differs: `The new passwords do not match.`
- there is no terminal: `No new password provided…`
- the connection is unencrypted: the error names `Sending a password needs an encrypted connection`

```
ducko account change-password alice@example.com
```

### `account unregister <jid> [--include-history]`

Unregister an account from its server via XEP-0077 and remove it locally. With `--include-history`, also deletes stored chat transcripts for the account.

It asks for confirmation and accepts only the full word: pipe `yes`, since `y` prints "Cancelled." and keeps the account.

```
ducko account unregister alice@example.com
ducko account unregister alice@example.com --include-history
```

### `server-info`

Show server contact information (XEP-0157) via disco#info.

```
ducko server-info
ducko server-info --output json
```

### `room list [--service <jid>] [--search <keyword>]`

Discover available rooms on a MUC service. Auto-discovers the server's MUC service if `--service` is omitted. Use `--search` / `-q` to search via XEP-0433 Extended Channel Search. When the search service rate-limits the search, the command exits 1 with `Error: The server is limiting channel searches, try again in <n> s`. The wait is the service's `retry-after`, else 10 seconds, doubling with each further limit in a row. It is stored with the account per search service, so later `room list --search` runs, the REPL and the app wait it out too, across relaunches.

```
ducko room list
ducko room list --service conference.example.com
ducko room list --search "test"
ducko room list -q "general"
```

### `room join <jid> [--nickname <nick>]`

Join a room and monitor incoming messages. Stays connected until `quit` or stdin EOF. Supports `send <message>` to send to the room.

```
ducko room join chat@conference.example.com
ducko room join chat@conference.example.com --nickname alice
```

### `room members <jid> [--nickname <nick>]`

Show room occupants grouped by affiliation. Joins the room temporarily to retrieve the occupant list.

```
ducko room members chat@conference.example.com
```

### `room send <jid> <body> [--nickname <nick>]`

Send a single message to a room. Joins the room, sends the message, then leaves and disconnects.

```
ducko room send chat@conference.example.com "Hello everyone"
```

### `omemo fingerprint`

Display own OMEMO device fingerprint (the local device's identity key). Fingerprints show in the form XEP-0384 recommends: the key's Curve25519 form as eight groups of eight lowercase hex digits, matching what other OMEMO 2 clients display. The stored, raw form is the Ed25519 key in hex.

```
ducko omemo fingerprint
ducko omemo fingerprint --output json
```

### `omemo devices <jid>`

List a contact's OMEMO devices with trust status. Only devices on the contact's current device list are shown; while that list cannot be read, every stored device is.

```
ducko omemo devices alice@example.com
ducko omemo devices alice@example.com --output json
```

### `omemo trust <jid> <device-id>`

Trust an OMEMO device. Marks the device as trusted for future encrypted sessions. An unknown device ID, or one no longer on the contact's device list, exits 1 and prints the error on stderr.

```
ducko omemo trust alice@example.com 12345
```

### `omemo untrust <jid> <device-id>`

Untrust an OMEMO device. Marks the device as untrusted, preventing encrypted sessions with it.

```
ducko omemo untrust alice@example.com 12345
```

### `omemo verify <jid> <device-id> <fingerprint>...`

Mark an OMEMO device verified, after comparing its fingerprint with the one the contact's device shows. The command joins its remaining arguments, so the fingerprint can be pasted unquoted as `omemo devices` prints it. Case and spacing don't matter, and the raw form that `--output json` shows as `fingerprint` is accepted too. It prints `Verified device <id> for <jid>.`, and JSON emits an `omemo_trust` record with `trust` `verified`.

It exits 1 for a fingerprint that names another key (`The fingerprint does not match the key of device <id> for <jid>.`), and for a device that is unknown or no longer on the contact's device list (`Device <id> not found for <jid>.`). A device whose key is not known yet cannot be verified either.

```
ducko omemo verify alice@example.com 12345 d9f71a68 33945da8 bda259e2 9a179ad2 e5092fe1 4d7372af 800da323 3b16ce4f
```

### `omemo reset <jid> [--device <id>]`

Reset the OMEMO sessions with every device on the contact's current list, or with one device. With the account's own JID it resets the account's other devices, and naming this device with `--device` is refused. A trusted or undecided device gets a new session and an empty key-exchange message. It is reported as still needing trusting when it is not trusted for encryption, as an undecided device is with trust on first use off. A device marked untrusted only has its session discarded, as do a device that publishes no keys and a `--device` that is not on the current list. A device whose bundle now carries another identity key is marked untrusted under the new key. The command prints each device's outcome, with both fingerprints of a changed key, and leaves a note in the chat with the contact (none for the account's own JID).

JSON emits one `omemo_session_reset` record with `jid` and a `devices` list. Each entry has `device_id` (a string) and `outcome`: `rebuilt` (with `needs_trusting`, `"true"` or `"false"`), `discarded`, `key_changed` (raw `previous_fingerprint`/`new_fingerprint`, displayed `previous_display_fingerprint`/`new_display_fingerprint`), `no_bundle`, `not_listed`, or `failed` (with `error`).

```
ducko omemo reset alice@example.com
ducko omemo reset alice@example.com --device 12345 --output json
```

### `logs show [--lines <n>]`

Print recent entries from `~/Library/Application Support/<app-dir>/Logs/ducko.log`. Default: 50 lines.

Every Ducko process on one `DUCKO_PROFILE` (the app, an `interactive` session, a one-shot command) appends to the same `ducko.log`, so their lines interleave. A line does not name its process. To attribute an event to one process, such as the app's own `Connected via` line, take it from a moment when only that process was running.

```
ducko logs show
ducko logs show --lines 200
```

### `logs export <destination>`

Copy all log files (current + rotated archives) to a directory.

```
ducko logs export ~/Desktop/ducko-logs
```

### `logs path`

Print the absolute path to the log directory.

### `import adium [--path <dir>] [--dry-run]`

Import chat history from Adium logs. Auto-discovers Adium's default logs directory if `--path` is omitted. With `--dry-run`, scans and reports discovered accounts/contacts/files without writing transcripts.

```
ducko import adium
ducko import adium --path ~/Library/Application\ Support/Adium\ 2.0/Users/Default/Logs --dry-run
```

## Output Formats

### Plain

```
[2026-02-27T10:00:00.000Z] <- alice@example.com: Hello
[2026-02-27T10:00:05.000Z] -> alice@example.com: Hi there [delivered]
[2026-02-27T10:00:10.000Z] <- alice@example.com: corrected text [edited]
[2026-02-27T10:00:15.000Z] <- alice@example.com: Secret message [encrypted]
```

`<-` = incoming, `->` = outgoing. Markers: `[delivered]` for delivery receipts, `[read]` instead once the contact has read the message, `[edited]` for corrected messages, `[encrypted]` for OMEMO-encrypted messages, `[untrusted device]` after `[encrypted]` for one decrypted from a device that is not trusted for encryption, `[error: ...]` for errors. An encrypted message that could not be decrypted reads `<jid>: error: <notice>` in place of its body, and is also marked `[encrypted]`. The notice says why:

- `This message could not be decrypted`
- `This message was not encrypted for this device`
- `This message could not be trusted, because its encryption names another sender, recipient or time`
- `This message could not be trusted, because it claims to come from a device marked as untrusted`
- `This message could not be trusted, because its device key does not match the stored fingerprint`
- `This message could not be decrypted, because the room does not reveal who sent it`
- `This message is encrypted with <method>, which Ducko cannot decrypt`, for a message encrypted with something other than OMEMO, such as OpenPGP

`interactive` prints an encrypted room message as it prints a plaintext one, `<room>/<nick>: <body>`, followed by `[encrypted]`. One in a room's private chat gets the `[PM]` prefix as well.

History also prints timeline notes, which are not messages, on lines of their own, such as `[<timestamp>] -- Encryption enabled because <jid> sent an encrypted message`. Other notes say that a contact asked for unencrypted messages (with any reason they gave), that they sent an encrypted message again after you switched encryption off, or that the encryption sessions with them were reset (listing the devices that need attention). A file a contact was sending directly that did not arrive leaves the note `<file> from <contact> did not arrive: <reason>`. The reason reads, for example, `You canceled the transfer`, `The transfer was canceled`, `The contact went offline` or `The transfer stopped when you went offline`.

### ANSI

Same as plain with color codes (green incoming, cyan outgoing, red errors, dim timestamps). Delivery shown as one green checkmark and read as two, edited as dim `[edited]`, encrypted as dim green `[encrypted]`, an untrusted sending device as yellow `[untrusted device]`, notes dimmed. Default in terminal.

### JSON

Every line on stdout is one JSON record. Prompts go to stderr in every format: registration and data form fields, CAPTCHA image paths, and the confirmations of `account unregister` and `/unregister-account`. So do guidance lines: the `interactive` banner, the hints of `room join`, the unjoined-room hint of `send`, and "Room created and locked".

```json
{"body":"Hello","direction":"incoming","from":"alice@example.com","timestamp":"2026-02-27T10:00:00Z","type":"message"}
```

Optional keys: `"action":"true"` for a `/me` message (an outgoing one in history also carries `"actor"`, the account's address), `"attachments":"..."` (comma-separated attachment URLs, leaving out one whose URL is the whole body), `"delivered":"true"`, `"read":"true"` (with `"delivered"` also set), `"edited":"true"`, `"encrypted":"true"`, `"untrusted_device":"true"` for one decrypted from a device that is not trusted for encryption, `"error":"..."`, and `"undecryptable":"true"` for an encrypted message that could not be decrypted (its `body` is then empty, and `"notice"` says why). An encrypted room message `interactive` prints is a `room_message` record, and one in a room's private chat a `muc_private_message` record, each with `room` and `nickname` in place of `from`. Keys are sorted alphabetically.

A timeline note in history is a record of its own: `{"kind":"encryption_enabled_by_contact","text":"...","timestamp":"...","type":"note"}`. `kind` is also `plaintext_requested` (with `detail` holding the reason when one was given, and in a room `subject` holding the requesting occupant's nickname), `encryption_resumed_by_contact`, `sessions_reset` (with `detail` listing the devices that need attention, if any) or `incoming_file_failed` (with `file_name`, and `detail` holding the reason).

A `jingle_transfer_progress` event carries `sid`, `offer_id`, `progress`, `bytes_transferred` and `total_bytes`, and adds `bytes_per_second` and `seconds_remaining` (whole numbers, as strings) only when they are known. `jingle_transfer_completed` and `jingle_transfer_failed` also carry `offer_id`. For an incoming transfer it matches the `offer_id` of its `file_offer` record. Every event of one transfer carries the same `offer_id`, and a later transfer that reuses the `sid` gets a different one, so `offer_id` rather than `sid` tells two transfers apart.

Every key is snake_case. Values Ducko defines are snake_case too, such as `not_started` in `local_status` or a note's `kind`. A Jingle `reason` is the exception: it keeps the Jingle spelling, such as `transport-reject` or `checksum-mismatch`. Values XMPP defines keep their spelling: message types, presence values, data form field types, stanza and SASL error conditions, and MUC roles and affiliations. An occupant with no affiliation reads `none`, in `room_participant_group` too.

Empty lists emit one `<kind>_empty` record instead of text: `accounts_empty`, `roster_empty`, `bookmarks_empty`, `block_list_empty`, `rooms_empty`, `room_participants_empty`, `searched_channels_empty`, `messages_empty`, `omemo_identity_empty` or `omemo_devices_empty`. `interactive` adds `online_contacts_empty` (`/who`), `transfers_empty`, `affiliations_empty` (with `affiliation` and `room`), `room_config_empty` (with `room`), `tls_info_empty` (`/connection-info`), `own_avatar_empty`, `avatar_empty` (with `jid`, also from `avatar get`), `recent_message_empty` (with `purpose`: `retract`, `edit` or `reply`) and `moderatable_message_empty`. Account-scoped records carry `"account"`. `omemo_devices_empty` adds `"jid"`, and `room_participants_empty` carries `"room"`.

OMEMO commands emit `omemo_fingerprint` (`fingerprint` and `display_fingerprint`), `omemo_device` (`jid`, `device_id`, `trust`, and `fingerprint` and `display_fingerprint` when known), `omemo_trust` and `omemo_session_reset` records. `fingerprint` is the raw Ed25519 hex Ducko stores, and `display_fingerprint` is the grouped Curve25519 form the text output shows.

A confirmation or single answer is a `command_result` record: an `action`, its fields and the human `message`. For example `{"action":"block","jid":"carol@example.com","message":"Blocked carol@example.com.","type":"command_result"}`. The actions are `block`, `unblock`, `add_bookmark`, `remove_bookmark`, `save_avatar` and `publish_avatar` (with `hash` and `size`, and `save_avatar` adding `path` and `mime_type`), and `register_account`.

`interactive` adds `unregister_account` (with `result`: `cancelled`, or `unregistered` with `history_deleted`), `submit_registration`, `change_password`, `send_file_directly`, `accept_transfer`, `decline_transfer`, `cancel_transfer`, `retract`, `edit`, `get_preference` and `set_preference` (with `key` and `enabled`), `set_encryption`, `send_presence`, `approve_subscription`, `deny_subscription`, `leave_room`, `destroy_room`, `current_room`, `grant_voice`, `revoke_voice`, `kick`, `submit_room_config`, `moderate`, `send_private_message`, `own_avatar` and `avatar`. There, `help` prints one `{"text":"...","type":"help"}` record, and `/affiliations` prints an `affiliation_group` record (`affiliation`, `count`) before one `affiliation` record (`jid`, `affiliation`, `nickname`) per entry. `/transfers` prints one `transfer` record per transfer, with `file_name`, `file_size`, `file_size_bytes`, `direction`, `method`, `state` and `account`, and `sid` and `offer_id` once set. `state` is a token such as `transferring`, and `progress`, `bytes_per_second`, `seconds_remaining`, `url`, `reason` or `path` come in fields of their own.

Errors are `error` records with a `message`. In `interactive`, a usage mistake prints one carrying the usage line, and an unknown command one naming it. A mistake in the arguments themselves, caught before the command runs, prints only on stderr. A command that throws an error once it runs prints one on stdout, while stderr gets `Error: …` and the exit status is the same as in the other formats.

Two failures get no such added record. A roster change prints its own record instead: an `error` record when it fails, or a `roster_command` record with `result: partial` and exit status 3 when it only partly succeeds. An interrupted `presence --for`/`--keep-alive` hold ends with exit status 130, 143 or 129 alone.

Event records, such as `connected` or `omemo_device_list`, print from background tasks, so one can land between a command's own records or after its `error` record. Pick a command's records by `type` rather than by line position. `message` is the exception: `/history` rows and live messages share that type, and a live one carries a `timestamp` from after the command ran. Tell a one-shot command's failure by its exit status. `interactive` exits 0 once connected, so there a command's failure shows only as its `error` record; a failed connect exits 1. `account register` and `/submit-registration` can print an `error` record for a refused attempt and still succeed. The exit status marks success, or for `/submit-registration` a `command_result` with `submit_registration`.

## Throwaway Profiles

Test runs use the debug binary `.build/debug/DuckoCLI` with a `DUCKO_PROFILE=<unique>` prefix on every command; release builds ignore `DUCKO_PROFILE` and write to the production store, and shell state does not carry between Bash tool calls, so an `export` is lost. Run these commands unsandboxed: the profile lives under `~/Library/Application Support/Ducko-Dev-<unique>/`, which the Bash sandbox refuses to create with "You don't have permission to save the file".

Clean up afterwards:

```bash
rm -rf "$HOME/Library/Application Support/Ducko-Dev-<unique>"
defaults delete im.ducko.dev.<unique>
rm -f "$HOME/Library/Preferences/im.ducko.dev.<unique>.plist"
```

`defaults delete` leaves the domain's plist behind empty, hence the final `rm`.

Any command except `logs` creates the directory of a profile that has none yet, read-only `account list` included. To find a profile with an account, list `~/Library/Application Support/Ducko-Dev-*` and run `account list` only against the names it shows, rather than against guessed names.

The first sign-in on a fresh profile publishes a new OMEMO device to the account's device list, which the cleanup above does not remove. For a check that only needs a sign-in, copy a persisted profile that already signed in (`rsync -a --exclude Logs "$HOME/Library/Application Support/Ducko-Dev-<persisted>/" "$HOME/Library/Application Support/Ducko-Dev-<unique>/"`), run against the copy while the original is not signed in, and clean it up as above. The copy reuses the device the original already published, and leaving out `Logs` keeps `logs show` to this run's lines.

A copy also keeps the original's remembered rooms, and `interactive` rejoins them on connect, which on the live server creates a room again as new when it no longer exists. Before running `interactive` on a copy, list what it will rejoin with `sqlite3 "$HOME/Library/Application Support/Ducko-Dev-<unique>/default.store" "SELECT ZJID, ZREJOINSONCONNECT FROM ZCONVERSATIONRECORD;"` (`1` rejoins). Afterwards, `/leave` each room it rejoined before `quit`, so the server removes a room the rejoin created, which also clears the flag in the copy. One-shot commands rejoin none.

## Live Smoke Testing

Drive the REPL non-interactively against a live account by piping one command per line into `interactive`, ending with `quit`. Pass `--output plain`: the default format keys off stdout being a terminal, so piped stdin alone still yields ANSI. The session exits 0 even when commands fail, so read the transcript for the outcome. Piped commands run only once the connect has completed. When the connect fails, the REPL exits 1 before reading them: stderr shows `Error: …` and no "Connected." line, and nothing runs.

```bash
DUCKO_PROFILE=<unique> .build/debug/DuckoCLI account add --no-connect --password secret alice@example.com
printf '/status\n/roster\n/join chat@conference.example.com alice\n/members\n/leave\nquit\n' \
  | DUCKO_PROFILE=<unique> .build/debug/DuckoCLI interactive --output plain
```

Each line of output reaches a pipe or file as soon as it is printed. A script can therefore read results while the session runs, for example to wait for an incoming offer before answering it. Keep the REPL's standard input open and read its standard output line by line. A line reader sees the ANSI upload progress bar only once the upload ends, since the bar redraws its line without ending it.

To verify a command that changes an account on the server, such as `account change-password` or `account unregister`, register a throwaway account in a throwaway profile and leave the shared test accounts alone: their stored passwords can't be read, so a change to one can't be undone.

Run `account register` and `account change-password` under a pseudo-terminal, a `tmux -L <name>` session (`send-keys` to type a line, `capture-pane` to read), since their hidden prompts read from a terminal. A pseudo-terminal counts as a terminal, so pass `--output plain` to `account register`. `account change-password` takes no `--output` and always prints plain text. When the server asks for a CAPTCHA, `account register` prints `CAPTCHA image for <field>: <path>` on stderr and deletes the image once the prompt ends, so read it while the prompt waits and `send-keys` the answer.

Confirm the change by signing in from a fresh throwaway profile (`account add <jid> --password <new>`). Afterwards `account unregister` the account, and check that a fresh sign-in now fails. Keep failed sign-ins few, since a server can ban an address after repeated failures.

`/approve <jid>` adds a `subscription=none` roster stub for that JID on the server even when no request was pending. Remove it afterwards with `roster remove <jid>`, or use a syntactically invalid JID when only the error path matters.

To stage a pending subscription request, read the requester's `roster list --output json`, then run `roster add <target>` from that account, which must not be subscribed to the target. For an entry the snapshot already shows, pass its `--name` and `--group`, since `roster add` without them clears both. The target's REPL prints `Subscription request from <jid>`, and its GUI shows `<jid> wants to subscribe` in a banner in the Contacts window. Undo the request with `/deny <requester>` in the target's REPL. When the requester had no entry for the target before, `/deny` leaves the new one at `subscription=none`, so also run `roster remove <target>` from the requester. When the entry existed before, leave it in place: `roster remove` would also cancel a `from` subscription it had.

To check server discovery without writing to the server:

- **HTTP upload**: discovery runs before the slot request. `send --file <path> --method http <jid>` with a sparse file larger than the server's limit (`mkfile -n 100g <path>`) exits 1 with `Error: The file is too large: the server accepts up to <size>`, and uploads nothing.
- **Proxy65**: discovery runs before a Jingle offer goes out. `send --file <small file> --method jingle <contact>/<resource that does not exist>` logs `Discovered a Proxy65 streamhost` in the file log, then exits 1 with `Error: File transfer negotiation failed: The service is unavailable`, delivering nothing. Use a small file: a Jingle send copies and hashes the whole file before discovery. A profile logs at info level, so the streamhost's host and port appear only after `defaults write im.ducko.dev.<unique> advancedLogLevel debug` before the run. The profile cleanup removes the setting.
- **Rooms and channel search**: the test server lists no public rooms and has no channel search service, so `room list` prints an empty result and `room list --search` exits 1 with `Error: The server does not offer channel search`, whether or not discovery works.

The info-level file log names the transport once it is chosen (`Jingle transfer is using a direct connection`, `… the server's proxy` or `… in-band bytestreams`). It also says why each SOCKS5 candidate failed (`A <direct|proxy> SOCKS5 candidate failed: <reason>`). Both appear only in a transfer the contact accepts, since candidates are dialed after `session-accept`. The debug setting above adds each failed candidate's cid.

Two profiles on one Mac reach each other directly, so to send such a transfer through the server's proxy, prefix the sender's command with `DUCKO_JINGLE_PROXY_ONLY=1`. A debug build then offers no direct candidates. The receiver offers none of its own, so only the sender needs the variable. A release build ignores it.

## Stream-Level Smoke Testing

To exercise STARTTLS negotiation, stream features, sign-in failures, a rejected server certificate, injected server data, a failure in the setup after sign-in, or a whole session with a made-up roster without a live server, follow [references/stub-server-smoke-testing.md](references/stub-server-smoke-testing.md).

## Connection Smoke Testing

To verify a change to connection or disconnection handling against the live test server, run the debug binary `.build/debug/DuckoCLI` in a throwaway profile, which keeps the run isolated from existing dev data (release builds ignore `DUCKO_PROFILE`). Prefix every command with the profile, since shell state does not carry between separate invocations. These steps write under `~/Library/Application Support/`, outside the repository, so run them unsandboxed.

```
DUCKO_PROFILE=smoke-connect ducko account add USER_JID --password PASSWORD_HERE --no-connect
DUCKO_PROFILE=smoke-connect ducko presence available --output json   # one full connect and disconnect handshake
DUCKO_PROFILE=smoke-connect ducko profile --output json              # a clean reconnect proves the close left no pending session
DUCKO_PROFILE=smoke-connect ducko logs show                          # handshake lines for this profile
DUCKO_PROFILE=smoke-connect ducko account delete USER_JID
/bin/rm -rf "$HOME/Library/Application Support/Ducko-Dev-smoke-connect"
```

The `account add` here signs in a fresh profile, which publishes a new OMEMO device. When the check needs no custom host or port, run it on a copy of a persisted profile instead, as Throwaway Profiles describes.

To stage a connection that drops and resumes, run the relay and add the account pointing at it, since the account needs the relay's host and port. The relay, `ps` and `kill` need to run unsandboxed too:

```
python3 Skills/ducko-cli/scripts/tcp-relay.py <port> <server-host>   # keep running in the background; forwards 127.0.0.1:<port> to <server-host>:5222
DUCKO_PROFILE=smoke-connect ducko account add USER_JID --password PASSWORD_HERE --host 127.0.0.1 --port <port> --no-connect
```

STARTTLS passes through the relay, and the certificate is still checked against the JID's domain. Send `SIGUSR1` to the relay's Python process to close the relayed sockets while it keeps listening. The client reports the connection lost, reconnects through the relay and resumes its stream, and the file log records `Stream resumed`. Take that process's PID from `ps -axo pid,comm,args`: `pgrep -f tcp-relay.py` also matches every wrapper shell whose command line names the script, and a signal sent to the relay's wrapper ends the wrapper and leaves the relay running. A GUI instance started under the same profile uses that account once its status is set to Available, so the relay drops its connection the same way. Afterwards kill that PID to stop the relay, and clean up a profile the GUI ran under as Throwaway Profiles describes.

To check a room across the drop, add a second account in its own throwaway profile, connected directly, and run each REPL under tmux. In the relayed REPL run `/join <new-room>@<muc-service> <nick>` and then `/config submit-default`, since a new room starts locked, and `/join` it from the second REPL. Send `SIGUSR1` and have the second account send to the room right away. The relayed account resumes a few seconds later and prints that message, which the server replays, just before its `stream resumed as <jid>` line. `/members` and `/history <room>` in the relayed REPL then show both occupants and the message, a message it sends reaches the second REPL, and the second REPL shows no leave or join of the relayed account across the drop. `/leave` in both REPLs so the server removes the room, and clean up the second profile as Throwaway Profiles describes.

## Encryption Smoke Testing

To verify OMEMO between two accounts on the live test server, give a receiver and a sender each a throwaway profile. Put the receiver behind the relay when the check includes a stream resume, and drop its connection with `SIGUSR1` as Connection Smoke Testing describes. Run each REPL with `--output plain` under its own `tmux -L <name>`. Start the session as a shell and type the `DuckoCLI` command into it with `send-keys`, so the pane stays open and shows the reason when the REPL exits early. Run these steps unsandboxed, since they read and write under `~/Library`.

The test accounts' device lists hold dozens of stale devices. A sender that trusts devices on first use encrypts to every one of them, so the check no longer shows whether the receiver's new device got a key. Start the receiver's REPL first, then, before the sender's REPL starts:

```
defaults write im.ducko.dev.<sender-profile> omemoTrustOnFirstUse -bool NO
grep "OMEMO setup complete, device ID" "$HOME/Library/Application Support/Ducko-Dev-<receiver-profile>/Logs/ducko.log"   # the receiver's new device
DUCKO_PROFILE=<sender-profile> .build/debug/DuckoCLI omemo devices RECEIVER_JID                                         # repeat until the device ID is listed
DUCKO_PROFILE=<sender-profile> .build/debug/DuckoCLI omemo trust RECEIVER_JID <device-id>
```

Then run `/encrypt RECEIVER_JID on` and `send RECEIVER_JID <text>` in the sender's REPL.

The receiver's REPL prints an incoming encrypted message as it arrives, and `/history SENDER_JID` shows it again. A decrypted message ends in `[encrypted]`. A failed one is also marked `[encrypted]` and reads `error:` and a notice in place of its text. `This message was not encrypted for this device` means it carried no key for the receiver's device, because the sender did not trust the receiver's new device, so check the trusted device ID. Otherwise it reads `This message could not be decrypted`, and the failure logs a warning in the receiver's file log. The warning is `OMEMO key exchange rejected: …` when the sender used a pre-key the receiver no longer has, and `OMEMO decryption failed: <error>` otherwise. A repeated key exchange prints no message line and logs `OMEMO key exchange ignored: …`.

On the test server, a message sent while the receiver is offline reaches it through the archive sync on its next sign-in rather than as a live delivery. The sync decrypts it, so this setup checks archive decryption rather than how a live delivery from offline storage decrypts.

Each throwaway profile adds a device to its account's device list on the shared server. Afterwards, with the user's approval, run `DUCKO_RESET_FIXTURES=1 swift test --package-path IntegrationTests --filter ResetTestServerState` to retract the lists, and clean up both profiles as Throwaway Profiles describes.

## Examples

```bash
# Send a message (password from Keychain)
ducko send alice@example.com "Hello"

# Send with JSON output
ducko send --output json alice@example.com "Hello" | jq .

# View recent history
ducko history alice@example.com --limit 10

# Start interactive session
ducko interactive

# Use a specific account
ducko send --account 12345678-1234-1234-1234-123456789abc bob@example.com "Hey"
```
