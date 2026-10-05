---
name: demo-screenshots
description: "Produce screenshots of the Ducko contacts list and chat window filled with made-up contacts and messages, using a local stub server and an isolated copy of the debug app, so no real account, contact, or conversation appears. Use when the user asks for \"demo screenshots\", \"screenshots with demo content\", \"a screenshot for the README\", \"screenshots for the website\", \"screenshots for slides\", \"marketing screenshots\", or \"a screenshot without my real contacts\"."
---

# Demo Screenshots

Capture the Contacts window and the chat window at its default size, in light appearance, with made-up content served by a stub on `127.0.0.1`.

## Prerequisites

- Screen Recording and Accessibility permission for the terminal that runs these commands
- An unlocked GUI session

Run every Bash call in this workflow unsandboxed: the steps bind a local port, launch the app, read the window list, and write under `~/Library/Application Support`.

Shell variables do not carry between Bash calls, so start every snippet below with these lines:

```bash
WORK=<absolute path of this run's work folder, outside the repo, free of + * $ | ( ) [ ] { }>
PROFILE=demo-screenshots
PORT=5299
APP="${WORK:?}/DuckoDemo.app"
SCRIPTS=Skills/demo-screenshots/scripts
STORE="$HOME/Library/Application Support/Ducko-Dev-${PROFILE:?}"
```

The `pgrep -fl` and `pkill` patterns are written out in full on purpose, so a snippet run without these lines can never match the installed app. Keep the `^${APP:?}` anchor in every `PID=` lookup: a launch command with the path spelled out leaves a shell that has the same path in its command line, and an unanchored lookup returns that shell's PID as well. With `APP` unset, the lookup stops with an error and `PID` stays empty.

Drive the demo instance only by its PID. Skip every tool that targets the app by name (System Events `process "DuckoApp"`, Peekaboo `--app`, the scripts in `Skills/ducko-ui/scripts`), because an installed Ducko that is running has the same process name. The installed app may keep running throughout.

## Step 1: Prepare

1. Tell the user that a second Ducko with demo content runs from Step 4 on: it adds a menu-bar icon, may ask for notification permission, may play a message sound, and its windows come to the front while capturing.
2. Confirm nothing is left from an earlier run. Each of these must print nothing or report that its target does not exist:

   ```bash
   ls -d "$STORE"; defaults read im.ducko.dev.$PROFILE; defaults read im.ducko.demo
   pgrep -fl "DuckoDemo.app/Contents/MacOS/DuckoApp"; lsof -iTCP:$PORT -sTCP:LISTEN
   ```

   Otherwise run Step 7 first, since saved window frames and saved tabs would carry into this run. When the port is held by something other than `stub.py`, pick another port.
3. Create the work folder: `mkdir -p "$WORK/avatars" "$WORK/shots"`.

## Step 2: Build the App Copy

A copy with its own bundle ID has no saved window frames, so the chat window opens at its default size and nothing is written to the `im.ducko` preferences. `NSRequiresAquaSystemAppearance` forces light appearance on a system set to Dark. The freshly built debug binary is what makes `DUCKO_PROFILE` take effect: a release binary ignores it and opens the real store, so the snippet stops at the first failing line.

When no `Ducko.app` exists at the repo root, run `SIGNING_MODE=adhoc ./Scripts/package_app.sh debug` first and remove that bundle again in Step 7. Then:

```bash
set -e
swift build
BIN=$(swift build --show-bin-path)
cp -R Ducko.app "$APP"
cp "$BIN/DuckoApp" "$APP/Contents/MacOS/DuckoApp"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DuckoApp"
cp "$BIN/DuckoCLI" "$APP/Contents/Resources/ducko"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier im.ducko.demo" \
  -c "Add :NSRequiresAquaSystemAppearance bool true" \
  -c "Add :SUEnableAutomaticChecks bool false" \
  "$APP/Contents/Info.plist"
chmod -R u+w "$APP"; xattr -cr "$APP"
find "$APP/Contents/Frameworks" -type f -perm -111 -print0 | xargs -0 -n1 codesign --force --sign -
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/Resources/ducko"
codesign --force --sign - --entitlements Resources/Entitlements.plist "$APP"
codesign --verify --deep "$APP" && echo signed-ok
```

Continue once it prints `signed-ok`.

## Step 3: Start the Stub and Add the Account

1. Render the avatars: `swift $SCRIPTS/avatars.swift "$WORK/avatars"`.
2. Start the stub as a background command, without a trailing `&`:

   ```bash
   python3 $SCRIPTS/stub.py $PORT "$WORK"
   ```

   It logs every byte sent and received to `$WORK/stub.log`.
3. Add the account, then allow plaintext to the stub and turn on Connect on Launch. The CLI has no option for either, so set them in the profile's store. The last line must print `1`:

   ```bash
   BIN=$(swift build --show-bin-path)
   DUCKO_PROFILE=$PROFILE "$BIN/DuckoCLI" account add tobias@pond.example --password demo --host 127.0.0.1 --port $PORT --no-connect
   sqlite3 "$STORE/default.store" "UPDATE ZACCOUNTRECORD SET ZREQUIRETLS=0, ZCONNECTONLAUNCH=1, ZDISPLAYNAME='Tobias'; SELECT changes();"
   ```

4. Prove the stub before any window appears:

   ```bash
   BIN=$(swift build --show-bin-path)
   DUCKO_PROFILE=$PROFILE "$BIN/DuckoCLI" roster list
   ```

   It must print `connected as tobias@pond.example/…` and the contacts in their groups. On any other result, read `$WORK/stub.log` for the last exchange and fix the stub before continuing.

## Step 4: Create the Conversation

1. Launch the copy's inner binary as a background command, without a trailing `&`. The launch argument switches this instance to overlay scroll bars, which removes the empty scroll track from the chat window:

   ```bash
   DUCKO_PROFILE=$PROFILE "$APP/Contents/MacOS/DuckoApp" -AppleShowScrollBars WhenScrolling
   ```

2. Wait for the Contacts window with `TITLE="Contacts"`:

   ```bash
   for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
     PID=$(pgrep -f "^${APP:?}/Contents/MacOS/DuckoApp")
     [ -n "$PID" ] && swift $SCRIPTS/windows.swift "$PID" | grep "onscreen true.*title: $TITLE\$" && break
     perl -e 'select(undef,undef,undef,1)'
   done
   ```

   Continue once it prints the window's line. When it prints nothing, read `$WORK/stub.log` for the last exchange.
3. Push one incoming message through the stub. The stub holds it until the instance has its roster and presence. The chat window then opens by itself at its default size, and the conversation's transcript folder is created:

   ```bash
   echo "<message from='lena@pond.example/laptop' to='{ME}' type='chat' id='seed-1'><body>Hi</body></message>" >> "$WORK/inject.txt"
   ```

4. Wait as in item 2 with `TITLE="Lena Fischer"`. The printed line must show `w 500 h 450`, and `"$STORE/Transcripts"` must hold one folder with one `.jsonl` file.
5. Quit the instance and confirm it is gone. The background launch then reports a failed exit, which is the kill:

   ```bash
   pkill -TERM -f "DuckoDemo.app/Contents/MacOS/DuckoApp"; perl -e 'select(undef,undef,undef,3)'
   pgrep -fl "DuckoDemo.app/Contents/MacOS/DuckoApp" || echo stopped
   ```

## Step 5: Seed the Conversation

With the instance stopped, overwrite the day file from Step 4 and clear the unread count. The last line must print `1`:

```bash
DAYFILE=$(ls "$STORE"/Transcripts/*/*.jsonl)
python3 $SCRIPTS/seed_transcript.py "$DAYFILE"
sqlite3 "$STORE/default.store" "UPDATE ZCONVERSATIONRECORD SET ZUNREADCOUNT=0; SELECT changes();"
```

Launch the instance again as in Step 4.1, then wait as in Step 4.2 with `TITLE="Lena Fischer"`. The chat window comes back with its tab.

## Step 6: Capture

A restored chat can ask for older messages a moment before the connection is up, which leaves a "Couldn't load older messages" banner in it. Close it first. The command prints `dismissed` and the number of banners it closed:

```bash
PID=$(pgrep -f "^${APP:?}/Contents/MacOS/DuckoApp")
swift $SCRIPTS/dismiss_banner.swift "$PID"
```

A window that is not the key window shows gray traffic lights, so bring each one to the front before capturing it. Run this once with `TITLE="Contacts"` and `OUT=ducko-contacts.png`, and once with `TITLE="Lena Fischer"` and `OUT=ducko-chat.png`:

```bash
PID=$(pgrep -f "^${APP:?}/Contents/MacOS/DuckoApp")
swift $SCRIPTS/focus.swift "$PID" "$TITLE"
perl -e 'select(undef,undef,undef,2)'
WID=$(swift $SCRIPTS/windows.swift "$PID" | grep -m1 "onscreen true.*title: $TITLE\$" | cut -d' ' -f1)
screencapture -x -o -l "${WID:?no on-screen window with that title}" "$WORK/shots/$OUT"
```

Each PNG holds the window alone, with transparent corners and no shadow, at the display's scale. On a 2x display the chat window is 1000 by 900 pixels.

Read both PNGs and check each one:

- The traffic lights are colored.
- Every row is whole: no message or contact is cut off at an edge, and no status line is truncated.
- The chat shows no scroll track and no warning banner.
- Presence dots, status messages, and avatars appear for the contacts that have them.
- The account's own status reads Available. Idle auto-away switches it after about five minutes without input, so set it back before capturing.

When a check fails, fix the cause and capture again. For changed messages, quit the instance as in Step 4.5 and repeat Step 5. For changed contacts, restart the stub and relaunch the instance.

## Step 7: Clean Up

Move the PNGs to where the user wants them. Then stop the instance and the stub, and confirm both are gone before removing files. The last line must print nothing:

```bash
pkill -TERM -f "DuckoDemo.app/Contents/MacOS/DuckoApp"
STUB=$(lsof -tiTCP:${PORT:?} -sTCP:LISTEN)
[ -n "$STUB" ] && ps -o command= -p "$STUB" | grep -q "stub.py" && kill "$STUB"
perl -e 'select(undef,undef,undef,3)'
pgrep -fl "DuckoDemo.app/Contents/MacOS/DuckoApp"; lsof -iTCP:${PORT:?} -sTCP:LISTEN
```

Remove what the run created:

```bash
/bin/rm -rf "${STORE:?}"
defaults delete im.ducko.dev.$PROFILE; /bin/rm -f "$HOME/Library/Preferences/im.ducko.dev.$PROFILE.plist"
defaults delete im.ducko.demo; /bin/rm -f "$HOME/Library/Preferences/im.ducko.demo.plist"
/bin/rm -rf "${WORK:?}"
```

When Step 2 packaged `Ducko.app` at the repo root, remove it as well. A leftover from an earlier run has its own work folder: the `pgrep -fl` line shows its path while that instance runs.

When the user may want another round with different content, leave the profile and the work folder in place and tell them so. Stop the instance and the stub either way.

## Changing the Content

The contacts, their presence, and the account live in the constants at the top of `scripts/stub.py`. The avatars live in `scripts/avatars.swift`, keyed by the same local parts, and the messages in `scripts/seed_transcript.py`. For other content, copy the script into the work folder, edit the constants there, and run the copy.

The same names also appear in the snippets above and in `seed_transcript.py`, so change them together:

- The account JID and display name in Step 3.3, and `ME` in `seed_transcript.py`
- The peer's JID in Step 4.3, and `PEER` in `seed_transcript.py`
- The peer's display name, which is the chat window's title in Steps 4.4, 5 and 6

Rules for the content:

- Use the reserved `.example` domain for every address.
- A contact without an avatar file shows its initials.
- Keep status messages short enough for the contact list's width.
- Four single-line messages fill the default chat window. A fifth one, or a message that wraps, makes it scroll.
- Message times in `seed_transcript.py` are UTC on the day file's date and show in local time. Keep them earlier than the current time.
- An incoming stanza appended to `$WORK/inject.txt` reaches the running instance. `{ME}` stands for the account's full JID.
- A room invitation shows its banner in Contacts. Append one `<message from='…' to='{ME}'>` line carrying `<x xmlns='jabber:x:conference' jid='<room address>'/>` after the last relaunch, since a pending invitation is not kept across one.
- A transcript line takes `replyToID`, naming another line's `stanzaID`, for a reply quote. For file cards it takes `attachments`, a list of objects with `id` (a UUID string), `url`, and optionally `fileName`, `fileSize` and `mimeType`. A line that fails to decode is dropped without an error.
- The stub has no group chat service. For a room row, add a row to `ZCONVERSATIONRECORD` in `$STORE/default.store` while the instance is stopped, after Step 5's unread update. Copy the chat's row, set `ZTYPE` to `groupchat` and `ZJID` to the room's address, give it a new `Z_PK` and a `ZID` from `randomblob(16)`, and raise `Z_MAX` for that entity in `Z_PRIMARYKEY`. `ZDISPLAYNAME` names the row, `ZROOMSUBJECT` gives it a caption and `ZUNREADCOUNT` a badge.
