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

`--method auto` (the default) and `http` upload the file over XEP-0363. `jingle` sends it peer-to-peer over XEP-0234 and returns only once the contact has accepted and received it, or the transfer has failed. With a full JID, `jingle` sends to that session. With a bare JID it picks one of the contact's online sessions that takes direct transfers. That needs the contact's presence to have arrived, so in this connect-send-disconnect command a full JID is the reliable form. A direct send appears in the chat's history as a sent file, marked `[delivered]` once it arrives or `[error: <reason>]` when it fails.

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
- `/config [submit-default]` — show room configuration fields, or submit the defaults to unlock a new room
- `/rooms [service]` — discover available rooms on MUC service
- `/sendfile [jid] <path>` — send a file (uses current room if jid omitted)
- `/senddirect <jid> <path>` — send a file straight to one of the contact's online devices (XEP-0234) instead of uploading it. The contact's devices are asked first. The command prints an error when the file is missing or is a folder, or when no device takes direct transfers. Otherwise it prints `Sending <file> to <jid> directly. Use /transfers to check progress.` and the prompt returns. A decline, or a transfer that fails once under way, is printed when it happens. A failure before that point, such as the device refusing the offer or the file's contents not being readable, prints nothing and shows only in `/transfers` and the history.
- `/accept [id]` — accept an incoming file offer (Jingle or link) and save it to `~/Downloads`. The id is the one printed in the `[File offer]` line. Without an id, it takes this account's newest offer.
- `/decline [id]` — decline an incoming file offer. Without an id, it takes this account's newest offer.
- `/transfers` — list active file transfers with progress
- `/add <jid> [name]` — add contact to roster
- `/remove <jid>` — remove contact from roster
- `/approve <jid>` — approve subscription request
- `/deny <jid>` — deny subscription request
- `/avatar [jid]` — view avatar info (own if no JID, contact's if given)
- `/profile` — view own vCard profile
- `/connection-info` — show TLS connection info (protocol, cipher, certificate)
- `/encrypt <jid> on|off` — toggle OMEMO encryption for a conversation. `off` also keeps a contact's encrypted message from switching it back on.
- `/pref chatstates on|off` — toggle chat state notifications (typing indicators)
- `/pref markers on|off` — toggle displayed markers (read receipts)
- `/reply <jid> <message>` — reply to last incoming message from JID
- `/retract <jid>` — retract last sent message to JID
- `/edit <jid> <new-body>` — edit last sent message to JID
- `/moderate [reason]` — moderate last message in current room (MUC moderator)
- `/search <jid> <query>` — search the whole message history with JID. Prints the newest 20 matches, oldest first.
- `/searchall <query>` — search all the account's conversations, as `history --search <query>` does. Prints the newest 20 matches.
- `/directed-presence <jid>` — send directed presence to a JID
- `/check-registration [jid]` — show server registration form
- `/submit-registration [jid]` — submit registration to server/component
- `/unregister-account` — unregister account from server
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

Interactive mode also prints async events as they arrive: typing indicators, delivery receipts, read markers, message corrections, Jingle transfer state changes, and MUC lifecycle events (`[new room]`, nickname changes, room destruction). Terminal bell rings on incoming messages and file transfer offers.

```
ducko interactive
```

### `history [<jid>]`

View message history from the local database. With `--server`, connects to fetch from the XMPP server. The JID can be left out only together with `--search`.

| Option | Description |
|---|---|
| `--limit <n>` | Maximum number of messages (default: 20) |
| `--before <date>` | Show messages before this ISO 8601 date (pagination). Needs a JID. |
| `--search <query>` | Show the newest messages that contain the keyword |
| `--server` | Fetch from server when local history is empty (requires connection). Needs a JID. |

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

List all configured accounts. Supports `--output` format.

```
ducko account list
ducko account list --output json
```

### `account add <jid> [--password <password>] [--host <host>] [--port <port>] [--no-connect]`

Add a new XMPP account. By default it connects to verify credentials and saves the password. Password is prompted interactively if `--password` is omitted. `--host`/`--port` override the connection endpoint (a bare `--port` without `--host` is rejected). With `--no-connect` the account is persisted *without* connecting or verifying credentials — offline/manual setup; the password is still saved.

When authentication fails, the command exits 1 and prints `Error: Authentication failed: <reason>`, where the reason is readable text such as "Incorrect username or password". To observe that failure as JSON, add the account with `--no-connect`, then run a connecting subcommand with `--output json` (e.g. `profile`, which uses the first account unless `--account <uuid>` is passed). It emits `{"account":"<uuid>","message":"<reason>","type":"authentication_failed"}`.

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

### `avatar get <jid> [--save <path>]`

Fetch and save a contact's avatar. Tries PEP (XEP-0084) first, falls back to vCard (XEP-0054). By default it saves to `<jid>.<ext>`, with the extension taken from the avatar's MIME type (`png` if the type is unknown).

```
ducko avatar get alice@example.com
ducko avatar get alice@example.com --save alice.jpg
```

### `avatar set <path>`

Publish own avatar from an image file (PNG recommended). Publishes via PEP and updates vCard if server lacks XEP-0398 conversion.

```
ducko avatar set photo.png
```

### `account register --server <domain> --username <user> --password <pw> [--email <email>]`

Register a new account on a server via XEP-0077 In-Band Registration. Creates the account on the remote server, then saves it locally.

```
ducko account register --server example.com --username alice --password secret
ducko account register --server example.com --username alice --password secret --email alice@mail.com
```

### `account check-registration --server <domain> [--host <host>] [--port <port>]`

Fetch and display a server's XEP-0077 registration form without registering. Useful for inspecting required fields or CAPTCHAs before calling `account register`.

```
ducko account check-registration --server example.com
```

### `account unregister <jid> [--include-history]`

Unregister an account from its server via XEP-0077 and remove it locally. With `--include-history`, also deletes stored chat transcripts for the account.

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

Discover available rooms on a MUC service. Auto-discovers the server's MUC service if `--service` is omitted. Use `--search` / `-q` to search via XEP-0433 Extended Channel Search.

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

Display own OMEMO device fingerprint (the local device's identity key).

```
ducko omemo fingerprint
ducko omemo fingerprint --output json
```

### `omemo devices <jid>`

List a contact's OMEMO devices with trust status.

```
ducko omemo devices alice@example.com
ducko omemo devices alice@example.com --output json
```

### `omemo trust <jid> <device-id>`

Trust an OMEMO device. Marks the device as trusted for future encrypted sessions. An unknown device ID exits 1 and prints the error on stderr.

```
ducko omemo trust alice@example.com 12345
```

### `omemo untrust <jid> <device-id>`

Untrust an OMEMO device. Marks the device as untrusted, preventing encrypted sessions with it.

```
ducko omemo untrust alice@example.com 12345
```

### `logs show [--lines <n>]`

Print recent entries from `~/Library/Application Support/<app-dir>/Logs/ducko.log`. Default: 50 lines.

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

`<-` = incoming, `->` = outgoing. Markers: `[delivered]` for delivery receipts, `[read]` instead once the contact has read the message, `[edited]` for corrected messages, `[encrypted]` for OMEMO-encrypted messages, `[error: ...]` for errors. An OMEMO message that could not be decrypted reads `<jid>: error: This message could not be decrypted` in place of its body.

History also prints timeline notes, which are not messages, on lines of their own: `[<timestamp>] -- Encryption enabled because <jid> sent an encrypted message`.

### ANSI

Same as plain with color codes (green incoming, cyan outgoing, red errors, dim timestamps). Delivery shown as one green checkmark and read as two, edited as dim `[edited]`, encrypted as dim green `[encrypted]`, notes dimmed. Default in terminal.

### JSON

```json
{"body":"Hello","direction":"incoming","from":"alice@example.com","timestamp":"2026-02-27T10:00:00Z","type":"message"}
```

Optional keys: `"delivered":"true"`, `"read":"true"` (with `"delivered"` also set), `"edited":"true"`, `"encrypted":"true"`, `"error":"..."`, and `"undecryptable":"true"` for an OMEMO message that could not be decrypted (its `body` is then empty). Keys are sorted alphabetically.

A timeline note in history is a record of its own: `{"kind":"encryption-enabled-by-contact","text":"...","timestamp":"...","type":"note"}`.

Empty lists emit one `<kind>_empty` record instead of text: `accounts_empty`, `roster_empty`, `bookmarks_empty`, `rooms_empty`, `room_participants_empty`, `searched_channels_empty`, `messages_empty`, `omemo_identity_empty` or `omemo_devices_empty`. Account-scoped records carry `"account"`. `omemo_devices_empty` adds `"jid"`, and `room_participants_empty` carries `"room"`. OMEMO commands emit `omemo_fingerprint`, `omemo_device` (`jid`, `deviceID`, `trust`, and `fingerprint` when known) and `omemo_trust` records.

## Throwaway Profiles

Test runs use the debug binary `.build/debug/DuckoCLI` with a `DUCKO_PROFILE=<unique>` prefix on every command; release builds ignore `DUCKO_PROFILE` and write to the production store, and shell state does not carry between Bash tool calls, so an `export` is lost. Run these commands unsandboxed: the profile lives under `~/Library/Application Support/Ducko-Dev-<unique>/`, which the Bash sandbox refuses to create with "You don't have permission to save the file".

Clean up afterwards:

```bash
rm -rf "$HOME/Library/Application Support/Ducko-Dev-<unique>"
defaults delete im.ducko.dev.<unique>
rm -f "$HOME/Library/Preferences/im.ducko.dev.<unique>.plist"
```

`defaults delete` leaves the domain's plist behind empty, hence the final `rm`.

## Live Smoke Testing

Drive the REPL non-interactively against a live account by piping one command per line into `interactive`, ending with `quit`. Pass `--output plain`: the default format keys off stdout being a terminal, so piped stdin alone still yields ANSI. The session exits 0 even when commands fail, so read the transcript for the outcome.

```bash
DUCKO_PROFILE=<unique> .build/debug/DuckoCLI account add --no-connect --password secret alice@example.com
printf '/status\n/roster\n/join chat@conference.example.com alice\n/members\n/leave\nquit\n' \
  | DUCKO_PROFILE=<unique> .build/debug/DuckoCLI interactive --output plain
```

Output sent to a pipe or file is block-buffered and arrives only when the session exits. To read results while the session runs (for example, to wait for an incoming offer before answering it), drive the REPL under a pseudo-terminal instead: a `tmux -L <name>` session (`send-keys` to type a line, `capture-pane` to read) or `script -q <log> …`. A pseudo-terminal counts as a terminal, so still pass `--output plain`.

`/approve <jid>` adds a `subscription=none` roster stub for that JID on the server even when no request was pending. Remove it afterwards with `roster remove <jid>`, or use a syntactically invalid JID when only the error path matters.

To stage a pending subscription request, read the requester's `roster list --output json`, then run `roster add <target>` from that account, which must not be subscribed to the target. For an entry the snapshot already shows, pass its `--name` and `--group`, since `roster add` without them clears both. The target's REPL prints `Subscription request from <jid>`, and its GUI shows `<jid> wants to subscribe` in a banner in the Contacts window. Undo the request with `/deny <requester>` in the target's REPL. When the requester had no entry for the target before, `/deny` leaves the new one at `subscription=none`, so also run `roster remove <target>` from the requester. When the entry existed before, leave it in place: `roster remove` would also cancel a `from` subscription it had.

## Stream-Level Smoke Testing

To exercise STARTTLS negotiation, stream features, injected server data, or a whole session with a made-up roster without a live server, follow [references/stub-server-smoke-testing.md](references/stub-server-smoke-testing.md).

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

To stage a connection that drops and resumes, run the relay and add the account pointing at it. The relay, `ps` and `kill` need to run unsandboxed too:

```
python3 Skills/ducko-cli/scripts/tcp-relay.py <port> <server-host>   # keep running in the background; forwards 127.0.0.1:<port> to <server-host>:5222
DUCKO_PROFILE=smoke-connect ducko account add USER_JID --password PASSWORD_HERE --host 127.0.0.1 --port <port> --no-connect
```

STARTTLS passes through the relay, and the certificate is still checked against the JID's domain. Send `SIGUSR1` to the relay's Python process to close the relayed sockets while it keeps listening: the client reports the connection lost, reconnects through the relay and resumes its stream, which the file log records as `Stream resumed as <jid>`. Take that process's PID from `ps -axo pid,comm,args`: `pgrep -f tcp-relay.py` also matches every wrapper shell whose command line names the script, and a signal sent to the relay's wrapper ends the wrapper and leaves the relay running. A GUI instance started under the same profile uses that account once its status is set to Available, so the relay drops its connection the same way. Afterwards kill that PID to stop the relay, and clean up a profile the GUI ran under as Throwaway Profiles describes.

To check a room across the drop, add a second account in its own throwaway profile, connected directly, and run each REPL under tmux. In the relayed REPL run `/join <new-room>@<muc-service> <nick>` and then `/config submit-default`, since a new room starts locked, and `/join` it from the second REPL. Send `SIGUSR1` and have the second account send to the room right away. The relayed account resumes a few seconds later and prints that message, which the server replays, just before its `stream resumed as <jid>` line. `/members` and `/history <room>` in the relayed REPL then show both occupants and the message, a message it sends reaches the second REPL, and the second REPL shows no leave or join of the relayed account across the drop. `/leave` in both REPLs so the server removes the room, and clean up the second profile as Throwaway Profiles describes.

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
