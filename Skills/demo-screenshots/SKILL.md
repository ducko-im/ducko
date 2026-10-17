---
name: demo-screenshots
description: "Produce screenshots of the Ducko contacts list and chat window filled with made-up contacts and messages, using a local stub server and an isolated copy of the debug app, so no real account, contact, or conversation appears. Also captures the website's reference set: every state in its manifest, in light and dark, unattended in the Lume VM. Use when the user asks for \"demo screenshots\", \"screenshots with demo content\", \"a screenshot for the README\", \"screenshots for the website\", \"screenshots for slides\", \"marketing screenshots\", \"a screenshot without my real contacts\", \"website reference captures\", or \"capture the reference states\"."
---

# Demo Screenshots

Steps 1–7 capture the Contacts window and the chat window at its default size, in light appearance, with made-up content from `content.json` served by a stub on `127.0.0.1`. [Reference Mode for the Website](#reference-mode-for-the-website) captures every state the website's manifest lists, in light and dark.

## Prerequisites

- Screen Recording and Accessibility permission for the terminal that runs these commands
- An unlocked GUI session

Run every Bash call in this workflow unsandboxed: the steps bind a local port, launch the app, read the window list, and write under `~/Library/Application Support`.

Shell variables do not carry between Bash calls, so start every snippet below with these lines:

```bash
WORK=<absolute path of this run's work folder, outside the repo, free of + * ? ^ \ $ | ( ) [ ] { }>
PROFILE=demo-screenshots
PORT=5299
APP="${WORK:?}/DuckoDemo.app"
SCRIPTS=Skills/demo-screenshots/scripts
STORE="$HOME/Library/Application Support/Ducko-Dev-${PROFILE:?}"
```

The `pgrep -fl` and `pkill` patterns are written out in full on purpose, so a snippet run without these lines can never match the installed app. Keep the `^${APP:?}` anchor in every `PID=` lookup: a launch command with the path spelled out leaves a shell that has the same path in its command line, and an unanchored lookup returns that shell's PID as well. The anchor matches only a launch by the absolute path, so never launch the copy by a relative one. With `APP` unset, the lookup stops with an error and `PID` stays empty.

Drive the demo instance only by its PID. Skip every tool that targets the app by name (System Events `process "DuckoApp"`, Peekaboo `--app`), because an installed Ducko that is running has the same process name. The scripts in `Skills/ducko-ui/scripts` drive only their own `DuckoUITest` copy, so they cannot reach the demo instance either. The installed app may keep running throughout.

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

   It serves the account, contacts and rooms of `content.json`. It logs every byte sent and received to `$WORK/stub.log`.
3. Add the account, then allow plaintext to the stub and turn on Connect on Launch. The CLI has no option for either, so set them in the profile's store. The JID, password and display name are `account.jid`, `account.password` and `account.name` of the content file in use. The last line must print `1`:

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

   It must print `connected as tobias@pond.example/…` (the `account.jid` in use) and the contacts in their groups. On any other result, read `$WORK/stub.log` for the last exchange and fix the stub before continuing.

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

With the instance stopped, replace the conversation from Step 4 with the `lena` conversation of `content.json` and clear the unread count. The seeder writes a day file per UTC date, as the app names them, and removes the folder's other day files. The last line must print `1`:

```bash
python3 $SCRIPTS/seed_transcript.py "$(ls -d "$STORE"/Transcripts/*/)" lena
sqlite3 "$STORE/default.store" "UPDATE ZCONVERSATIONRECORD SET ZUNREADCOUNT=0; SELECT changes();"
```

Launch the instance again as in Step 4.1, then wait as in Step 4.2 with `TITLE="Lena Fischer"`. The chat window comes back with its tab.

## Step 6: Capture

Compile `scripts/drive.swift`, which drives the windows by PID, once per work folder:

```bash
mkdir -p "$WORK/bin" && swiftc -O $SCRIPTS/drive.swift -o "$WORK/bin/drive"
```

A restored chat can ask for older messages a moment before the connection is up, which leaves a "Couldn't load older messages" banner in it. Close it first. The command prints `dismissed` and the number of banners it closed:

```bash
PID=$(pgrep -f "^${APP:?}/Contents/MacOS/DuckoApp")
"$WORK/bin/drive" "$PID" dismiss-banners
```

A window that is not the key window shows gray traffic lights, so bring each one to the front before capturing it. Run this once with `SCENE=contacts`, `TITLE="Contacts"` and `OUT=ducko-contacts.png`, and once with `SCENE=chat`, `TITLE="Lena Fischer"` and `OUT=ducko-chat.png`:

```bash
PID=$(pgrep -f "^${APP:?}/Contents/MacOS/DuckoApp")
"$WORK/bin/drive" "$PID" focus "$SCENE"
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

The account, contacts, rooms and conversations live in `content.json`, read by `stub.py` and `seed_transcript.py`. The avatars live in `scripts/avatars.swift`, keyed by the same local parts. For other content, copy `content.json` into the work folder, edit the copy, and pass its path: as the third argument of `stub.py` and as `--content` to `seed_transcript.py`.

The same names also appear in the snippets of Steps 3–6 and R2, so change them together:

- The account JID and display name in Step 3.3 and R2.2
- The peer's JID in Step 4.3
- The conversation key, `lena`, in Step 5
- The peer's display name, which is the chat window's title in Steps 4.4, 5 and 6

Rules for the content:

- Use the reserved `.example` domain for every address.
- A contact without an avatar file shows its initials.
- Keep status messages short enough for the contact list's width.
- Four single-line messages fill the default chat window. A fifth one, or a message that wraps, makes it scroll.
- Message times are on `presentation.date` in `presentation.timeZone`, and Steps 4–6 show them in local time. Keep the date in the past.
- An incoming stanza appended to `$WORK/inject.txt` reaches the running instance. `{ME}` stands for the account's full JID.
- A room invitation shows its banner in Contacts. Append one `<message from='…' to='{ME}'>` line carrying `<x xmlns='jabber:x:conference' jid='<room address>'/>` after the last relaunch, since a pending invitation is not kept across one.
- A message takes `replyTo`, naming another message's `id`, for a reply quote, and `retracted: true` for the retraction notice. For file cards it takes `attachments`, a list of objects with `id` (a UUID string), `url`, and optionally `fileName`, `fileSize` and `mimeType`. The seeder writes them into the transcript, where a line that fails to decode is dropped without an error.
- An attachment object with `"savedOrigin":"locallySaved"` and a `file:` address as its `url` is shown as a file saved on this Mac. When its `mimeType` starts with `image/` and no file exists at that address, the chat shows the missing-image placeholder with the file's name.
- A contact's `status` may hold `\n` for a status message with line breaks.
- A second account added after Step 3.3's `UPDATE`, with that step's `DUCKO_PROFILE=$PROFILE "$BIN/DuckoCLI" account add` line and `<jid> --password demo --host 127.0.0.1 --port <unused port> --no-connect`, keeps Connect on Launch off and stays offline. The Contacts header then shows the identity switcher and a status such as `Available · 1 Offline`.
- The Contacts window fits its width to the widest contact name, between 200 points and a cap of 280. To change the cap, run `defaults write im.ducko.dev.$PROFILE contactListMaxWidth -float <points>` before launching, with a value from 150 to 400. A cap below 200 sets the width outright. A cap above the fitted width changes nothing, and the stock names fit in 200.
- The stub joins the client to the rooms of `content.json`, with their occupants and subject, and then writes `$WORK/joined/<room address>`. For a room row, add a row to `ZCONVERSATIONRECORD` in `$STORE/default.store` while the instance is stopped, after Step 5's unread update. Copy the chat's row through a temporary table (`CREATE TEMP TABLE t AS SELECT * FROM ZCONVERSATIONRECORD WHERE Z_PK = <chat's>`, then `INSERT INTO ZCONVERSATIONRECORD SELECT * FROM t`), since inserting a copy straight from the table collides on `Z_PK`. Before the insert, update `t` with `ZTYPE` set to `groupchat`, `ZJID` to the room's address, a new `Z_PK` and a `ZID` from `randomblob(16)`, along with the columns below. Then raise `Z_MAX` for that entity in `Z_PRIMARYKEY`. The client joins the room only with `ZREJOINSONCONNECT` set to 1 and the room's `nickname` in `ZROOMNICKNAME`. `ZDISPLAYNAME` names the row, `ZROOMSUBJECT` gives it a caption and `ZUNREADCOUNT` a badge. Seed the room's transcript with `python3 $SCRIPTS/seed_transcript.py "$STORE/Transcripts/<the new ZID as an uppercase hyphenated UUID>" <the room's conversation variant>`.

## Reference Mode for the Website

The ducko.im website recreates the Contacts window, the chat window and the Dock badge, and overlays reference PNGs of the real app on them until they match. The website owns which states exist (`reference/states.json` in `ducko-im/ducko-im.github.io`). This skill owns how to reach each one and capture it, and `content.json` owns what each state shows. The website builds its fixtures from the `content.json` states, so a change of content belongs here.

`scripts/reference.py` runs the whole manifest unattended. It switches the system appearance, empties the Dock while capturing it, brings windows to the front, moves the pointer and replaces the clipboard, so run it in the Lume VM (the `/lume-vm` skill), never on a Mac someone is using. Run every `vm.sh` call below outside the sandbox. The snippets assume a checkout folder named `ducko`; in another checkout, replace `ducko` in `/Volumes/My Shared Files/ducko` with that folder's name.

### R1: Tell the User

Tell the user that the run needs the VM to itself for about three and a half minutes, measured with 35 states in two appearances.

### R2: Set Up the Work Folder

In a work folder kept from an earlier round, run `zsh Skills/lume-vm/scripts/vm.sh gui '/bin/rm -rf /Users/lume/work/DuckoDemo.app'` between item 1's `start` and `push`, since `push` merges into an existing bundle. Of item 2, only copy `content.json` and start the stub: the account carries over, since `bootstrap` restores the folder's first snapshot. Skip item 3, whose setting lasts until the VM is reset. Then repeat item 4.

1. On the host, build the copy as in Step 2, leaving out the `Add :NSRequiresAquaSystemAppearance bool true` line. The run sets each appearance through the system, and `reference.py` refuses a copy pinned to light. Then start the VM and push the copy:

   ```bash
   zsh Skills/lume-vm/scripts/vm.sh start
   zsh Skills/lume-vm/scripts/vm.sh push "$WORK/DuckoDemo.app" /Users/lume/work/DuckoDemo.app
   ```

2. In the VM, copy the content snapshot, render the avatars, start the stub detached, add the account through the copy's own CLI, and prove the stub. The last line must print `connected as …`:

   ```bash
   zsh Skills/lume-vm/scripts/vm.sh gui 'cd /Users/lume/work; S="/Volumes/My Shared Files/ducko/Skills/demo-screenshots"
   cp "$S/content.json" content.json && mkdir -p avatars && swift "$S/scripts/avatars.swift" avatars >/dev/null
   nohup python3 "$S/scripts/stub.py" 5299 /Users/lume/work /Users/lume/work/content.json >stub.out 2>&1 &
   sleep 1; STORE="$HOME/Library/Application Support/Ducko-Dev-demo-screenshots"; CLI=DuckoDemo.app/Contents/Resources/ducko
   DUCKO_PROFILE=demo-screenshots $CLI account add tobias@pond.example --password demo --host 127.0.0.1 --port 5299 --no-connect
   sqlite3 "$STORE/default.store" "UPDATE ZACCOUNTRECORD SET ZREQUIRETLS=0, ZCONNECTONLAUNCH=1, ZDISPLAYNAME='"'"'Tobias'"'"';"
   DUCKO_PROFILE=demo-screenshots $CLI roster list | head -1'
   ```

   The scripts run straight from the read-only repository share, and everything they write goes to `/Users/lume/work`.
3. Allow the copy's notifications once, since macOS draws no Dock badge for an app whose notifications are off. Launch the copy by its absolute path, so `reference.py` can stop it later:

   ```bash
   zsh Skills/lume-vm/scripts/vm.sh gui 'DUCKO_PROFILE=demo-screenshots nohup /Users/lume/work/DuckoDemo.app/Contents/MacOS/DuckoApp >/dev/null 2>&1 &'
   ```

   Then turn on Allow notifications with Badge application icon in System Settings > Notifications > Ducko, with Peekaboo in the VM, and quit the copy: `zsh Skills/lume-vm/scripts/vm.sh gui 'pkill -f "DuckoDemo.app/Contents/MacOS/DuckoApp"'`. The setting lasts until the VM is reset.
4. Record what the copy was built from: `zsh Skills/lume-vm/scripts/vm.sh gui 'python3 "/Volumes/My Shared Files/ducko/Skills/demo-screenshots/scripts/reference.py" build-info /Users/lume/work'`. Repeat it after every rebuild of the copy.

### R3: Bootstrap and Run

Copy the website's `reference/states.json` into the host's `.build/vm-exchange/` (the VM's `/Volumes/My Shared Files/vm-exchange/`). When the website has no `reference/states.json`, write a manifest listing every `content.json` state with `"appearances": ["light", "dark"]` and the `window` its id's prefix names (`contacts`, `chat` or `dock`). Then:

```bash
zsh Skills/lume-vm/scripts/vm.sh gui 'cd /Users/lume/work; R="/Volumes/My Shared Files/ducko/Skills/demo-screenshots/scripts/reference.py"
python3 "$R" bootstrap /Users/lume/work && python3 "$R" run /Users/lume/work "/Volumes/My Shared Files/vm-exchange/states.json" out'
```

`bootstrap` builds `baseline/`, the store and defaults every state starts from. Run it again after any change of `/Users/lume/work/content.json`. The stub picks up the new content at its next session. A changed `account.jid` or `account.name` needs a new work folder.

`run` checks the build, the baseline and the Mac's appearance before it touches `out`, and each refusal names its fix. `--ids a,b` reruns those states into an existing folder captured from the same sources, content, macOS build and settings, and replaces only their files and entries. Each state restores the baseline, seeds its content, launches the copy and performs its live steps. It then checks through Accessibility that the state holds, and captures. A state that fails any of these lands in `skipped` with the step named, and leaves no PNG. Progress goes to `/Users/lume/work/reference.log`.

To check a change to `reference.py` or to some states, run with `--ids` for those states into a new folder, which keeps `out` from the last full run. For changed states, copy the new `content.json` into `/Users/lume/work` and run `bootstrap` first, or the run uses the old states.

After a rebuild of the copy from changed sources, or a change of `content.json`, hand over a full run into a new folder, since `--ids` refuses to merge into a folder captured from other sources or content.

### R4: Check the Captures

Copy `out` to the host (`zsh Skills/lume-vm/scripts/vm.sh pull /Users/lume/work/out <host folder>`) and read every PNG. Accessibility asserts your own status, the badges and typing on tabs and on contact and room rows, the tab overflow control, the input text, the editing bar, the selected row, collapsed groups, the empty chat, the key window, the first tab's last message, the last outgoing message's delivery mark and the Dock badge. Only the PNGs show the rest:

- hover effects: the status picker's fill, the traffic lights' glyphs, Marco's tab close button, the first grouped bubble's metadata
- the accent selection in `contacts-selected-key`, `chat-text-selected-key` and `chat-text-selected-outgoing`, and the unemphasized one in `contacts-selected-inactive` and `chat-text-selected-inactive`
- the "(edited 2 minutes ago)" label
- no hover effect in any state that names none

Rerun anything in `skipped` with `--ids`.

When a PNG shows something that looks off, find out from the code whether it is an app bug or how the app really looks before reporting it. The website recreates what the captures show, so recommend fixing an app bug before the hand-over. Fix a capture problem in `reference.py`, `drive.swift` or `content.json` instead.

### R5: Hand Over and Clean Up

Move `out` into the website's `reference/captures/`. Then stop the stub (`pkill -f stub.py` in the VM) and either `zsh Skills/lume-vm/scripts/vm.sh stop` and `reset`, or keep the work folder for the next round.

### content.json

| Key | Holds |
|---|---|
| `version` | The contract version the website checks |
| `presentation` | `timeZone` and `locale` the run launches the copy with, and the `date` every message falls on |
| `account` | `jid`, `name`, `password` |
| `contacts` | `localpart`, `name`, `group`, `resource`, `show` (null for available, `away`, `xa`, `dnd`, `offline`), `status` |
| `rooms` | `key`, `jid`, `name`, `subject`, own `nickname`, `occupants` with `nick`, `affiliation`, `role` |
| `conversations` | Variants keyed by name: `peer` (a contact's local part or a room's key), `kind` (`chat` or `room`), `messages` with a fixed uppercase `id`, `stanzaID`, `from` (`me`, `peer` or a nickname), `time`, `body`, outgoing `status` (`sent`, `delivered`, `read`), and optional `editedSecondsAgo`, `replyTo`, `retracted` and `attachments` |
| `states` | One entry per manifest id; unset fields take their defaults |

A state's fields: `key` (the window that is key, by default the manifest's window), `tabs` (conversation variants, the first selected; default `["lena"]`), `overflow` (true when the tabs don't all fit the bar), `lastOutgoingStatus`, `closeAllTabs`, `rooms` (room keys to keep), `unread` (unread counts by conversation variant, such as `{"marco": 3}`), `collapsedGroups`, `selectedContact`, `ownStatus` (`available`, `away`, `xa`, `dnd`, `offline`), `typing` (contacts), `input` (draft text), `editing` (a message id), `hover` (`{"statusPicker": true}`, `{"trafficLights": true}` for the minimize button of the manifest's window, `{"tab": <variant>}` or `{"message": <id>}`), `menu` (`"status"` or `{"message": <id>}`) and `select` (`{"message": <id>, "range": [start, end]}`, UTF-16 offsets with `end` exclusive into a plain message (no `/me` line or reply quote) of the first tab's one-to-one chat, within the first line of an incoming body or an outgoing body that fits on one line without wrapping, starting and ending on a non-space character, dragged with the pointer and checked by copying it). A manifest id without an entry is skipped as "no content entry".

Tabs past the bar's width go into its overflow menu, which shows no badge or typing, so give no `unread` or `typing` to a conversation whose tab overflows. Contact and room rows show them too, with or without a tab, and are checked as well unless the contact's group is collapsed.

### capture.json

`macOS` (`productVersion`, `buildVersion`), `ducko` (the copy's `version`, `commit`, `dirty` and `sourceDigest`), `displayScale`, `capturedAt`, `appearanceMethod` (`system`), `environment` (interface style and its automatic switching, accent and highlight color, wallpaper tinting, reduce transparency and increase contrast, each null when unset), `content` (`version`, `sha256` of the `content.json` beside it), `captures[]` and `skipped[]` (`id`, `appearance`, `reason`). A capture has `id`, `appearance`, `window`, `file` and `size` in points. Its `layers[]` holds an open menu: `kind: "menu"`, `file`, `offset` from the window's top-left and `size`, in points. A Dock capture adds `tileSize` and `iconRect`, the 128-point icon's rect within the crop.

Window PNGs hold the window alone, with transparent corners and no shadow, at the display's scale, tagged with the display's color profile. An open menu is drawn into its window's surface, so no capture holds it alone. The window PNG is taken just before the menu opens. The menu PNG is cut, at the menu's bounds, from a capture of the window with the menu open. Where a menu overhangs its window, its glass shows the VM's plain wallpaper. The Dock PNG is the Dock item's frame rounded outward to whole points, with the Dock set to 128-point tiles and emptied of everything but running apps while capturing. The run restores the Dock's settings afterwards.

### Appearance, Caret and Reproducibility

The run sets the system appearance for each pass through System Events and confirms it from a fresh AppKit process, then sets the original back. On macOS 27.0.1, `scripts/compare.swift` compared an app-level `NSApp.appearance = .darkAqua` against the system's Dark. Two app-level runs matched pixel for pixel. App-level against system Dark differed on 72–93 % of each PNG's pixels, by up to 7 levels per channel, a tint across the window background. The Dock follows only the system appearance anyway. After a macOS update, rerun that comparison before switching to the app-level method.

The copy launches with `-NSTextInsertionPointBlinkPeriodOn 100000000 -NSTextInsertionPointBlinkPeriodOff 0`, which holds a focused field's caret on: five captures 0.3 s apart matched exactly with them, and differed by the caret without them.

Run `swift scripts/compare.swift <a.png> <b.png> [diff.png]` to compare two runs. It prints the pixels differing by more than 2 in any channel and the largest difference. Given `diff.png`, it draws those pixels in red. Two runs of the same build, content and settings differ only in text anti-aliasing, and in the "(edited …)" label when its minute rolls over.

### Adding a State

Add the id to the website's manifest and an entry to `content.json`'s `states`, built from the fields above. When the state needs a mechanism the run lacks, add a `drive.swift` command for it, a live step and a check in `reference.py` (through Accessibility, or a readback such as `select`'s copy where Accessibility can't see the result), and the PNG-only signal to R4. The website's fixtures read only a message's `id`, `from`, `time`, `body`, `status` and `editedSecondsAgo`, so a state that uses `replyTo`, `retracted` or `attachments` also needs the website to draw them.

### Driving a State by Hand

To try something no state covers, such as a smoke test, stage a state from a Python script run in the VM and drive the app from there:

```python
import sys
sys.path.insert(0, "/Volumes/My Shared Files/ducko/Skills/demo-screenshots/scripts")
import reference as R

work = R.Work("/Users/lume/work")
run = R.Run(work, "/Volumes/My Shared Files/vm-exchange/states.json", "/Users/lume/work/manual", None)
run.preflight()
run.parking = work.drive("parking").split()
stop, launch = work.stop, work.launch
launched = []
work.stop = lambda: None if launched else stop()  # `stage` stops the app once it has captured
work.launch = lambda: launched.append(True) or launch()
spec = {**R.DEFAULTS, "key": "chat", **run.content["states"]["chat-room"]}
try:
    run.stage({"id": "chat-room", "window": "chat", "appearances": ["light"]}, "light", spec, "manual-chat-room")
except R.Skip as skip:
    print("stage stopped at %s: %s" % (run.step, skip))
pid = work.process.pid
```

Then use `work.drive(pid, …)` and capture a window by the id `work.windows(pid)` lists with `screencapture -x -o -l <id>`, and call `stop()` at the end. The app shows the VM's current appearance; the appearance argument only names the files. Overrides in `spec` change the state, and a spec its assertions no longer match raises `Skip` after launch. To change the store or defaults beyond the state's fields, do it in the `work.launch` wrapper, which runs after the state's setup: a `room@conference/nick` tab written to `chatSavedTabs` there opens a private chat within a room.
