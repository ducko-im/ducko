"""Captures the website's reference states from the demo app copy, unattended.

Usage: python3 reference.py build-info <work>
       python3 reference.py bootstrap <work>
       python3 reference.py run <work> <manifest> <out> [--ids a,b]

  build-info   records the checkout's version, commit, dirty flag and source digest; run it right after building
               <work>/DuckoDemo.app
  bootstrap    builds <work>/baseline/: the profile's store and defaults with a chat for each contact
               conversation and the room records, from the content snapshot <work>/content.json
  run          captures every manifest state that content.json describes, in each appearance the manifest lists
               for it, into <out>/<id>.<appearance>.png (+ .menu.png), <out>/capture.json and <out>/content.json

The stub must be running on <work>/content.json. The run switches the system appearance, empties the Dock while
capturing it, moves the real pointer, brings the demo windows to the front and replaces the clipboard, so it belongs in
the Lume VM. The appearance, the Dock and the pointer go back to how they were when the run ends.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import time
import uuid

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(SCRIPTS, "..", "..", ".."))
PROFILE = "demo-screenshots"
STORE = os.path.expanduser("~/Library/Application Support/Ducko-Dev-%s" % PROFILE)
DOMAINS = ["im.ducko.dev.%s" % PROFILE, "im.ducko.demo"]
SOURCE_PATHS = ["Sources", "Package.swift", "Package.resolved"]
# An app-level dark appearance tints window backgrounds differently from the system's Dark, so each pass sets the
# system appearance.
APPEARANCE_METHOD = "system"
# Holds the insertion caret on, so a focused field looks the same in every capture.
CARET_ARGUMENTS = ["-NSTextInsertionPointBlinkPeriodOn", "100000000", "-NSTextInsertionPointBlinkPeriodOff", "0"]
STATUS_TITLES = {"available": "Available", "away": "Away", "xa": "Extended Away", "dnd": "Do Not Disturb", "offline": "Offline"}
DEFAULTS = {
    "tabs": ["lena"], "overflow": False, "lastOutgoingStatus": None, "closeAllTabs": False, "rooms": [], "unread": {}, "collapsedGroups": [],
    "selectedContact": None, "ownStatus": "available", "typing": [], "input": None, "editing": None, "hover": None, "menu": None,
    "select": None,
}
MENU_LAYER = 101
DOCK_TILE_SIZE = 128
STATE_ID = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
APPEARANCES = ("light", "dark")


class Skip(Exception):
    """A state that cannot be captured as specified."""


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, check=True).stdout


def source_digest():
    # Content only: a commit that leaves the built sources unchanged keeps the digest.
    listed = git("ls-files", "-co", "--exclude-standard", "-z", "--", *SOURCE_PATHS).split(b"\0")
    digest = hashlib.sha256()
    for path in sorted({p for p in listed if p and os.path.isfile(os.path.join(REPO, p.decode()))}):
        with open(os.path.join(REPO, path.decode()), "rb") as f:
            data = f.read()
        digest.update(path + b"\0" + str(len(data)).encode() + b"\0" + data)
    return digest.hexdigest()


class Work:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.app = os.path.join(self.path, "DuckoDemo.app")
        self.binary = os.path.join(self.app, "Contents", "MacOS", "DuckoApp")
        self.pattern = "^%s" % self.binary
        self.content_path = os.path.join(self.path, "content.json")
        self.baseline = os.path.join(self.path, "baseline")
        self.pristine = os.path.join(self.path, "pristine")
        self.joined = os.path.join(self.path, "joined")
        self.log_path = os.path.join(self.path, "reference.log")
        self.process = None

    def content(self):
        with open(self.content_path, encoding="utf-8") as f:
            return json.load(f)

    def log(self, message):
        line = "%s %s" % (time.strftime("%H:%M:%S"), message)
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        # A closed `vm.sh` connection leaves no reader on stdout, and the run still has to clean up.
        try:
            print(line, flush=True)
        except OSError:
            pass

    def tool(self, name):
        source = os.path.join(SCRIPTS, name + ".swift")
        binary = os.path.join(self.path, "bin", name)
        if not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(source):
            os.makedirs(os.path.dirname(binary), exist_ok=True)
            subprocess.run(["swiftc", "-O", source, "-o", binary], check=True)
        return binary

    def drive(self, *args, timeout=30):
        result = subprocess.run([self.tool("drive"), *map(str, args)], capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            raise Skip("drive %s: %s" % (" ".join(map(str, args)), result.stderr.strip() or "exit %d" % result.returncode))
        return result.stdout.strip()

    def windows(self, pid):
        out = subprocess.run([self.tool("windows"), str(pid)], capture_output=True, text=True, check=True).stdout
        rows = []
        for line in out.splitlines():
            match = re.match(r"(\d+) layer (-?\d+) onscreen (\w+) x (\S+) y (\S+) w (\S+) h (\S+) title: (.*)$", line)
            if match:
                number, layer, onscreen, x, y, w, h, title = match.groups()
                rows.append({
                    "id": int(number), "layer": int(layer), "onscreen": onscreen == "true",
                    "frame": tuple(float(v) for v in (x, y, w, h)), "title": title,
                })
        return rows

    def pid(self):
        out = subprocess.run(["pgrep", "-f", self.pattern], capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None

    def stop(self):
        subprocess.run(["pkill", "-TERM", "-f", self.pattern])
        if not wait_until(lambda: self.pid() is None, 10):
            subprocess.run(["pkill", "-KILL", "-f", self.pattern])
            wait_until(lambda: self.pid() is None, 5)
        if self.process:
            self.process.wait()
            self.process = None
        if self.pid() is not None:
            fail("the demo instance did not stop")

    def launch(self):
        content = self.content()
        environment = {k: v for k, v in os.environ.items() if k != "DUCKO_USE_KEYCHAIN"}
        environment.update({"DUCKO_PROFILE": PROFILE, "TZ": content["presentation"]["timeZone"]})
        arguments = [self.binary, "-AppleLocale", content["presentation"]["locale"], "-AppleShowScrollBars", "WhenScrolling"]
        log = open(os.path.join(self.path, "app.log"), "a")
        self.process = subprocess.Popen(arguments + CARET_ARGUMENTS, env=environment, stdout=log, stderr=log)
        log.close()
        return self.process.pid

    def inject(self, stanza):
        with open(os.path.join(self.path, "inject.txt"), "a", encoding="utf-8") as f:
            f.write(stanza + "\n")

    def snapshot(self, folder):
        shutil.rmtree(folder, ignore_errors=True)
        shutil.copytree(STORE, os.path.join(folder, "store"))
        for domain in DOMAINS:
            exported = subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout
            with open(os.path.join(folder, domain + ".plist"), "wb") as f:
                f.write(exported)

    def restore(self, folder):
        shutil.rmtree(STORE, ignore_errors=True)
        shutil.copytree(os.path.join(folder, "store"), STORE)
        for domain in DOMAINS:
            subprocess.run(["defaults", "delete", domain], capture_output=True)
            path = os.path.join(folder, domain + ".plist")
            if os.path.getsize(path):
                subprocess.run(["defaults", "import", domain, path], check=True)

    def sql(self, statement, *parameters):
        connection = sqlite3.connect(os.path.join(STORE, "default.store"))
        try:
            with connection:
                return connection.execute(statement, parameters).fetchall()
        finally:
            connection.close()


def wait_until(condition, seconds, interval=0.1):
    deadline = time.monotonic() + seconds
    while True:
        if condition():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)


def uuid_string(blob):
    return str(uuid.UUID(bytes=bytes(blob))).upper()


def contact(content, localpart):
    return next(c for c in content["contacts"] if c["localpart"] == localpart)


def contact_jid(content, localpart):
    return "%s@%s" % (localpart, content["account"]["jid"].split("@", 1)[1])


def room_jid(content, key):
    return next(room["jid"] for room in content["rooms"] if room["key"] == key)


def peer_jid(content, conversation):
    if conversation["kind"] == "room":
        return room_jid(content, conversation["peer"])
    return contact_jid(content, conversation["peer"])


def unread_value(count):
    return "1 unread message" if count == 1 else "%d unread messages" % count


def build_info(work):
    version = subprocess.run(["git", "-C", REPO, "describe", "--tags", "--abbrev=0"], capture_output=True, text=True).stdout.strip()
    info = {
        "version": version or None,
        "commit": git("rev-parse", "HEAD").decode().strip(),
        "dirty": bool(git("status", "--porcelain", "--", *SOURCE_PATHS).strip()),
        "sourceDigest": source_digest(),
    }
    with open(os.path.join(work.path, "build.json"), "w") as f:
        json.dump(info, f, indent=2)
    print(json.dumps(info))


def bootstrap(work):
    content = work.content()
    account = {"jid": content["account"]["jid"], "name": content["account"]["name"]}
    work.stop()
    recorded = os.path.join(work.pristine, "account.json")
    if os.path.exists(recorded):
        with open(recorded) as f:
            if json.load(f) != account:
                fail("account.jid or account.name changed: run the reference setup again in a fresh work folder")
        work.restore(work.pristine)
    else:
        work.snapshot(work.pristine)
        with open(recorded, "w") as f:
            json.dump(account, f)

    peers = [c for c in content["conversations"].values() if c["kind"] == "chat"]
    localparts = sorted({c["peer"] for c in peers})
    pid = work.launch()
    try:
        for localpart in localparts:
            work.inject(
                "<message from='%s/%s' to='{ME}' type='chat' id='bootstrap-%s'><body>Hi</body></message>"
                % (contact_jid(content, localpart), contact(content, localpart)["resource"] or "demo", localpart)
            )
        jids = {contact_jid(content, lp) for lp in localparts}

        def missing():
            return jids - {row[0] for row in work.sql("SELECT ZJID FROM ZCONVERSATIONRECORD")}

        if not wait_until(lambda: not missing(), 30):
            fail("bootstrap: no conversation record for %s after 30 s; read stub.log" % ", ".join(sorted(missing())))
        work.log("bootstrap: conversations for %s, pid %d" % (", ".join(localparts), pid))
    finally:
        work.stop()

    template = contact_jid(content, localparts[0])
    for room in content["rooms"]:
        connection = sqlite3.connect(os.path.join(STORE, "default.store"))
        with connection:
            connection.execute("CREATE TEMP TABLE room AS SELECT * FROM ZCONVERSATIONRECORD WHERE ZJID = ?", (template,))
            connection.execute(
                "UPDATE temp.room SET Z_PK = (SELECT Z_MAX + 1 FROM Z_PRIMARYKEY WHERE Z_NAME = 'ConversationRecord'), "
                "ZID = randomblob(16), ZTYPE = 'groupchat', ZJID = ?, ZDISPLAYNAME = ?, ZROOMSUBJECT = ?, ZROOMNICKNAME = ?, "
                "ZREJOINSONCONNECT = 1, ZUNREADCOUNT = 0, ZLASTMESSAGEPREVIEW = NULL",
                (room["jid"], room["name"], room["subject"], room["nickname"]),
            )
            connection.execute("INSERT INTO ZCONVERSATIONRECORD SELECT * FROM temp.room")
            connection.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = Z_MAX + 1 WHERE Z_NAME = 'ConversationRecord'")
        connection.close()

    folders = {}
    for jid, blob in work.sql("SELECT ZJID, ZID FROM ZCONVERSATIONRECORD"):
        key = next((r["key"] for r in content["rooms"] if r["jid"] == jid), jid.split("@", 1)[0])
        folders[key] = uuid_string(blob)
    accounts = work.sql("SELECT ZID FROM ZACCOUNTRECORD")
    if len(accounts) != 1:
        fail("bootstrap: expected one account, found %d" % len(accounts))
    work.snapshot(work.baseline)
    with open(os.path.join(work.baseline, "conversations.json"), "w") as f:
        json.dump({"accountID": uuid_string(accounts[0][0]), "folders": folders, "contentSha256": sha256(work.content_path)}, f, indent=2)
    print("baseline written to %s" % work.baseline)


def defaults_value(domain, key):
    result = subprocess.run(["defaults", "read", domain, key], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return int(value) if re.fullmatch(r"-?\d+", value) else value


def environment():
    values = {key: defaults_value("-g", key) for key in [
        "AppleInterfaceStyle", "AppleInterfaceStyleSwitchesAutomatically", "AppleAccentColor", "AppleHighlightColor", "AppleReduceDesktopTinting",
    ]}
    for key in ["reduceTransparency", "increaseContrast"]:
        values[key] = defaults_value("com.apple.universalaccess", key)
    return values


# Not compared between runs, since each pass sets the system appearance whatever these keys say.
UNCOMPARED_ENVIRONMENT = {"AppleInterfaceStyle", "AppleInterfaceStyleSwitchesAutomatically"}


def provenance(capture):
    return {
        "sourceDigest": capture["ducko"]["sourceDigest"],
        "content.sha256": capture["content"]["sha256"],
        "appearanceMethod": capture["appearanceMethod"],
        "macOS build": capture["macOS"]["buildVersion"],
        "displayScale": capture["displayScale"],
        **{"environment.%s" % k: v for k, v in capture["environment"].items() if k not in UNCOMPARED_ENVIRONMENT},
    }


def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise Skip("%s is not a PNG" % os.path.basename(path))
    return struct.unpack(">II", header[16:24])


class Run:
    def __init__(self, work, manifest, out, ids):
        self.work = work
        self.out = os.path.abspath(out)
        self.content = work.content()
        with open(os.path.join(work.baseline, "conversations.json")) as f:
            self.baseline = json.load(f)
        with open(manifest) as f:
            self.states = json.load(f)["states"]
        # Ids and appearances name the output files.
        for state in self.states:
            if not STATE_ID.fullmatch(state["id"]) or not set(state["appearances"]) <= set(APPEARANCES):
                fail("manifest state %r: ids are lowercase words joined by hyphens, appearances light or dark" % state["id"])
        if ids:
            unknown = set(ids) - {s["id"] for s in self.states}
            if unknown:
                fail("not in the manifest: %s" % ", ".join(sorted(unknown)))
            self.states = [s for s in self.states if s["id"] in ids]
        self.ids = ids
        self.dock_settings = None

    def preflight(self):
        with open(os.path.join(self.work.path, "build.json")) as f:
            build = json.load(f)
        if source_digest() != build["sourceDigest"]:
            fail("the sources differ from the ones the app copy was built from: rebuild the copy, then run build-info")
        content_sha = sha256(self.work.content_path)
        if content_sha != self.baseline["contentSha256"]:
            fail("content.json changed since the baseline was built: run bootstrap again")
        with open(os.path.join(self.work.app, "Contents", "Info.plist"), "rb") as f:
            if "NSRequiresAquaSystemAppearance" in plistlib.load(f):
                fail("the app copy pins light appearance: delete NSRequiresAquaSystemAppearance from its Info.plist and sign it again")
        settings = environment()
        if settings["AppleInterfaceStyleSwitchesAutomatically"]:
            fail("the Mac's appearance is Auto: choose Light or Dark in System Settings > Appearance for the run")
        self.original_appearance = "dark" if settings["AppleInterfaceStyle"] == "Dark" else "light"
        self.scale = float(self.work.drive("scale"))
        versions = {key: subprocess.run(["sw_vers", "--" + key], capture_output=True, text=True).stdout.strip()
                    for key in ["productVersion", "buildVersion"]}
        self.capture = {
            "macOS": versions,
            "ducko": build,
            "displayScale": self.scale,
            "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "appearanceMethod": APPEARANCE_METHOD,
            "environment": settings,
            "content": {"version": self.content["version"], "sha256": content_sha},
            "captures": [],
            "skipped": [],
        }
        existing = os.path.join(self.out, "capture.json")
        files = os.listdir(self.out) if os.path.isdir(self.out) else []
        if self.ids and os.path.exists(existing):
            with open(existing) as f:
                previous = json.load(f)
            ours, theirs = provenance(self.capture), provenance(previous)
            differing = [key for key in ours if ours[key] != theirs.get(key)]
            if differing:
                fail("%s differs from %s: run every state into a new folder" % (", ".join(differing), existing))
            self.capture["captures"] = previous["captures"]
            self.capture["skipped"] = previous["skipped"]
        elif self.ids and files:
            fail("%s holds files but no capture.json: run every state" % self.out)
        os.makedirs(self.out, exist_ok=True)
        if not self.ids:
            for name in files:
                if name.endswith(".png") or name == "capture.json":
                    os.remove(os.path.join(self.out, name))

    def write(self):
        with open(os.path.join(self.out, "capture.json"), "w") as f:
            json.dump(self.capture, f, indent=2, ensure_ascii=False)
        shutil.copyfile(self.work.content_path, os.path.join(self.out, "content.json"))

    def execute(self):
        # Python ends on these without unwinding, which would leave the Dock and the appearance as the run set them.
        for number in [signal.SIGTERM, signal.SIGHUP]:
            signal.signal(number, lambda received, _: sys.exit("stopped by signal %d" % received))
        self.preflight()
        self.pointer = self.work.drive("pointer").split()
        self.parking = self.work.drive("parking").split()
        appearances = []
        for state in self.states:
            appearances += [a for a in state["appearances"] if a not in appearances]
        try:
            for appearance in appearances:
                self.set_appearance(appearance)
                for state in self.states:
                    if appearance in state["appearances"]:
                        self.capture_one(state, appearance)
        finally:
            self.work.stop()
            self.set_appearance(self.original_appearance)
            self.work.drive("pointer-restore", *self.pointer)
            self.write()
        skipped = [s for s in self.capture["skipped"] if not self.ids or s["id"] in self.ids]
        print("%d captures, %d skipped; see %s" % (len(self.capture["captures"]), len(skipped), os.path.join(self.out, "capture.json")))

    def set_appearance(self, appearance):
        script = 'tell application "System Events" to tell appearance preferences to set dark mode to %s' % str(appearance == "dark").lower()
        subprocess.run(["osascript", "-e", script], check=True)
        if not wait_until(lambda: self.work.drive("appearance") == appearance, 10, interval=0.5):
            fail("the Mac did not switch to %s appearance" % appearance)
        self.work.log("appearance: %s" % appearance)

    def capture_one(self, state, appearance):
        key = (state["id"], appearance)
        for list_name in ["captures", "skipped"]:
            self.capture[list_name] = [e for e in self.capture[list_name] if (e["id"], e["appearance"]) != key]
        stem = "%s.%s" % key
        for suffix in [".png", ".menu.png"]:
            path = os.path.join(self.out, stem + suffix)
            if os.path.exists(path):
                os.remove(path)
        if state["id"] not in self.content["states"]:
            self.skip(state, appearance, "no content entry")
            return
        spec = {**DEFAULTS, "key": state["window"], **self.content["states"][state["id"]]}
        self.work.log("%s: start" % stem)
        self.step = "baseline"
        try:
            try:
                entry = self.stage(state, appearance, spec, stem)
            finally:
                self.set_dock(False)
        except Skip as skip:
            reason = "%s: %s" % (self.step, skip)
        except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
            reason = "%s: %s" % (self.step, error)
        else:
            self.capture["captures"].append(entry)
            self.write()
            self.work.log("%s: captured" % stem)
            return
        self.work.stop()
        for suffix in [".png", ".menu.png", ".composite.png"]:
            for folder in [self.out, self.work.path]:
                path = os.path.join(folder, stem + suffix)
                if os.path.exists(path):
                    os.remove(path)
        self.skip(state, appearance, reason)

    def skip(self, state, appearance, reason):
        self.capture["skipped"].append({"id": state["id"], "appearance": appearance, "reason": reason})
        self.write()
        self.work.log("%s.%s: skipped: %s" % (state["id"], appearance, reason))

    def stage(self, state, appearance, spec, stem):
        work, content = self.work, self.content
        conversations = content["conversations"]
        tab_jids = [peer_jid(content, conversations[variant]) for variant in spec["tabs"]]

        work.stop()
        work.restore(work.baseline)
        shutil.rmtree(work.joined, ignore_errors=True)

        self.step = "content"
        for variant in spec["tabs"]:
            folder = self.baseline["folders"][conversations[variant]["peer"]]
            command = [sys.executable, os.path.join(SCRIPTS, "seed_transcript.py"), os.path.join(STORE, "Transcripts", folder), variant,
                       "--content", work.content_path]
            if spec["lastOutgoingStatus"]:
                command += ["--last-outgoing-status", spec["lastOutgoingStatus"]]
            if subprocess.run(command, capture_output=True).returncode != 0:
                raise Skip("seed %s" % variant)
        kept = [room_jid(content, key) for key in spec["rooms"]]
        work.sql("DELETE FROM ZCONVERSATIONRECORD WHERE ZTYPE = 'groupchat' AND ZJID NOT IN (%s)" % ",".join("?" * len(kept)), *kept)
        work.sql("UPDATE ZCONVERSATIONRECORD SET ZUNREADCOUNT = 0")
        for conversation, count in spec["unread"].items():
            work.sql("UPDATE ZCONVERSATIONRECORD SET ZUNREADCOUNT = ? WHERE ZJID = ?", count, peer_jid(content, conversations[conversation]))
        domain = DOMAINS[0]
        tabs = [{"accountID": self.baseline["accountID"], "jid": jid} for jid in tab_jids]
        saved = json.dumps({"orderedTabs": tabs, "selectedKey": tabs[0], "isWindowOpen": True}, separators=(",", ":"))
        subprocess.run(["defaults", "write", domain, "chatSavedTabs", "-data", saved.encode().hex()], check=True)
        subprocess.run(["defaults", "write", domain, "contactListCollapsedGroups", "-string", json.dumps(spec["collapsedGroups"])], check=True)

        self.step = "launch"
        if state["window"] == "dock":
            self.set_dock(True)
        work.drive("hover", *self.parking)
        pid = work.launch()
        launched = time.monotonic()

        def prerequisite(name, condition):
            if not wait_until(condition, max(0, 30 - (time.monotonic() - launched))):
                raise Skip("%s after 30 s" % name)

        prerequisite("no windows", lambda: self.has_windows(pid))
        prerequisite("contact-list not connected", lambda: self.quiet(pid, "value", "contact-list") == "connected")
        for key in spec["rooms"]:
            prerequisite("%s not joined" % key, lambda key=key: os.path.exists(os.path.join(work.joined, room_jid(content, key))))
        work.drive(pid, "dismiss-banners")

        self.step = "live step"
        if spec["ownStatus"] != "available":
            work.drive(pid, "press", "status-picker")
            work.drive(pid, "pick", STATUS_TITLES[spec["ownStatus"]])
        if spec["selectedContact"]:
            row = "contact-row-%s" % contact_jid(content, spec["selectedContact"])
            if spec["key"] == "contacts":
                work.drive(pid, "focus", "contacts")
            work.drive(pid, "select-row", row)
            if spec["key"] == "contacts":
                work.drive(pid, "focus-table", "contact-list")
        if spec["closeAllTabs"]:
            for jid in tab_jids:
                work.drive(pid, "action", "chat-tab-%s" % jid, "Close Tab")
        for localpart in spec["typing"]:
            work.inject(
                "<message from='%s/%s' to='{ME}' type='chat'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"
                % (contact_jid(content, localpart), contact(content, localpart)["resource"])
            )
        if spec["input"]:
            work.drive(pid, "focus", "chat")
            work.drive(pid, "type", spec["input"])
        if spec["editing"]:
            work.drive(pid, "show-menu", "message-bubble-%s" % spec["editing"])
            work.drive(pid, "pick", "Edit")
        if spec["select"]:
            selection = spec["select"]
            conversation = conversations[spec["tabs"][0]]
            message = next((m for m in conversation["messages"] if m["id"] == selection["message"]), None)
            if not message or conversation["kind"] != "chat":
                raise Skip("select: only a message of the first tab's one-to-one chat")
            start, end = selection["range"]
            if not (isinstance(start, int) and isinstance(end, int) and 0 <= start < end):
                raise Skip("select: range %r is not two increasing offsets" % (selection["range"],))
            # The range counts UTF-16 code units, as the website's strings do.
            expected = message["body"].encode("utf-16-le")[2 * start:2 * end].decode("utf-16-le")
            # `drive` strips its output, so a selection with an edge space would never match.
            if expected != expected.strip():
                raise Skip("select: %r starts or ends with a space" % expected)
            work.drive(pid, "focus", "chat")
            side = "outgoing" if message["from"] == "me" else "incoming"
            copied = work.drive(pid, "select-text", "message-bubble-%s" % message["id"], side, message["body"], start, end)
            if copied != expected:
                raise Skip("select copied %r, expected %r" % (copied, expected))
            work.drive("hover", *self.parking)
        work.drive(pid, "focus", spec["key"])
        hover = spec["hover"] or {}
        if hover:
            if hover.get("trafficLights"):
                # Over the minimize button, which changes nothing without a click.
                target = ["window-button", state["window"], "minimize"]
            elif hover.get("statusPicker"):
                target = ["frame", "status-picker"]
            elif "tab" in hover:
                target = ["frame", "chat-tab-%s" % peer_jid(content, conversations[hover["tab"]])]
            else:
                target = ["frame", "message-bubble-%s" % hover["message"]]
            x, y, w, h = map(float, work.drive(pid, *target).split())
            work.drive("hover", x + w / 2, y + h / 2)

        self.step = "assert"
        for name, check, seconds in self.assertions(pid, spec, tab_jids):
            if not wait_until(check, seconds):
                raise Skip(name)
        if state["window"] == "dock":
            return self.capture_dock(state, appearance, spec, stem)
        # Key-window chrome, a resize and the hover fade settle first, and the frame is read after them.
        time.sleep(1)
        window_frame = tuple(map(float, work.drive(pid, "frame", state["window"]).split()))
        work.log("%s: window %s frame %s" % (stem, state["window"], window_frame))
        menu = spec["menu"]
        if menu:
            anchor = "status-picker" if menu == "status" else "message-bubble-%s" % menu["message"]
            work.log("%s: anchor %s frame %s" % (stem, anchor, work.drive(pid, "frame", anchor)))

        self.step = "capture"
        window = next((r for r in work.windows(pid) if r["layer"] == 0 and r["onscreen"] and r["frame"] == window_frame), None)
        if not window:
            raise Skip("no on-screen window at %s" % (window_frame,))
        files = [stem + ".png"]
        window_options = ["-o", "-l", str(window["id"])]
        self.screenshot(window_options, window_frame, files[0])
        x, y, w, h = window_frame
        entry = {
            "id": state["id"], "appearance": appearance, "window": state["window"], "file": files[0],
            "size": {"width": w, "height": h}, "layers": [],
        }

        # An open menu draws into its window's surface, so no capture holds it alone. Its layer is cut from a capture of
        # the window with the menu open.
        if menu:
            self.step = "menu"
            if menu == "status":
                work.drive(pid, "press", "status-picker")
            else:
                work.drive(pid, "show-menu", "message-bubble-%s" % menu["message"])
            if not wait_until(lambda: any(r["layer"] == MENU_LAYER and r["onscreen"] for r in work.windows(pid)), 5):
                raise Skip("no layer-%d window" % MENU_LAYER)
            time.sleep(1)
            menu_row = next((r for r in work.windows(pid) if r["layer"] == MENU_LAYER and r["onscreen"]), None)
            if not menu_row:
                raise Skip("the menu closed")
            mx, my, mw, mh = menu_row["frame"]
            ux, uy = min(x, mx), min(y, my)
            union = (ux, uy, max(x + w, mx + mw) - ux, max(y + h, my + mh) - uy)
            composite = stem + ".composite.png"
            self.screenshot(window_options, union, composite)
            files.append(stem + ".menu.png")
            scale = self.scale
            work.drive("crop", os.path.join(work.path, composite), os.path.join(work.path, files[1]),
                       round((mx - ux) * scale), round((my - uy) * scale), round(mw * scale), round(mh * scale))
            os.remove(os.path.join(work.path, composite))
            entry["layers"].append({
                "kind": "menu", "file": files[1], "offset": {"x": mx - x, "y": my - y}, "size": {"width": mw, "height": mh},
            })

        for name in files:
            shutil.move(os.path.join(work.path, name), os.path.join(self.out, name))
        work.stop()
        return entry

    def set_dock(self, captured):
        """Sets the Dock to DOCK_TILE_SIZE tiles, or back to the operator's own settings.

        The Dock shrinks its tiles to fit the screen, so it holds only the running apps while capturing. `defaults
        import` merges into a domain, so the domain is deleted before the saved copy goes back."""
        if captured == (self.dock_settings is not None):
            return
        if captured:
            self.dock_settings = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True, check=True).stdout
            for key, kind, value in [
                ("tilesize", "-float", str(DOCK_TILE_SIZE)), ("magnification", "-bool", "false"), ("show-recents", "-bool", "false"),
                ("persistent-apps", "-array", None), ("persistent-others", "-array", None),
            ]:
                subprocess.run(["defaults", "write", "com.apple.dock", key, kind] + ([value] if value else []), check=True)
        else:
            subprocess.run(["defaults", "delete", "com.apple.dock"], capture_output=True)
            subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=self.dock_settings, check=True)
            self.dock_settings = None
        subprocess.run(["killall", "Dock"])
        if not wait_until(lambda: self.dock_item("Finder") is not None, 10):
            raise Skip("the Dock did not come back")

    def dock_item(self, title):
        try:
            x, y, w, h, badge = self.work.drive("dock", title).split()
        except (Skip, ValueError):
            return None
        return (float(x), float(y), float(w), float(h)), badge

    def capture_dock(self, state, appearance, spec, stem):
        work = self.work
        # The Dock names an app launched by its executable after the bundle's file name.
        title = os.path.splitext(os.path.basename(work.app))[0]
        expected = str(sum(spec["unread"].values()))
        if not wait_until(lambda: (self.dock_item(title) or (None, None))[1] == expected, 10):
            raise Skip("Dock badge does not read %s" % expected)
        time.sleep(1)
        item = self.dock_item(title)
        if not item:
            raise Skip("no Dock item %s" % title)
        x, y, w, h = item[0]
        work.log("%s: Dock item frame %s" % (stem, item[0]))
        # A region capture takes whole points, so the region is the item's frame rounded outward.
        left, top = math.floor(x), math.floor(y)
        frame = (left, top, math.ceil(x + w) - left, math.ceil(y + h) - top)

        self.step = "capture"
        name = stem + ".png"
        self.screenshot(["-R", "%d,%d,%d,%d" % frame], frame, name)
        shutil.move(os.path.join(work.path, name), os.path.join(self.out, name))
        work.stop()
        # The icon is centered in the item's frame, which also holds the running indicator below it.
        icon = {"x": x - left + (w - DOCK_TILE_SIZE) / 2, "y": y - top + (h - DOCK_TILE_SIZE) / 2, "width": DOCK_TILE_SIZE, "height": DOCK_TILE_SIZE}
        return {
            "id": state["id"], "appearance": appearance, "window": state["window"], "file": name,
            "size": {"width": frame[2], "height": frame[3]}, "layers": [], "tileSize": DOCK_TILE_SIZE, "iconRect": icon,
        }

    def screenshot(self, options, frame, name):
        """Captures with screencapture's `options` and checks that the PNG's pixel size is `frame`'s size, in points, at the display's scale."""
        path = os.path.join(self.work.path, name)
        if subprocess.run(["screencapture", "-x", *options, path]).returncode != 0:
            raise Skip("screencapture failed for %s" % name)
        expected = (round(frame[2] * self.scale), round(frame[3] * self.scale))
        if png_size(path) != expected:
            raise Skip("size check: %s is %s pixels, expected %s" % (name, png_size(path), expected))

    def quiet(self, pid, *args):
        try:
            return self.work.drive(pid, *args, timeout=10)
        except (Skip, subprocess.TimeoutExpired):
            return None

    def has_windows(self, pid):
        return self.quiet(pid, "frame", "contacts") is not None and self.quiet(pid, "frame", "chat") is not None

    def assertions(self, pid, spec, tab_jids):
        content, conversations = self.content, self.content["conversations"]
        checks = [("status-picker reads %s" % STATUS_TITLES[spec["ownStatus"]],
                   lambda: self.quiet(pid, "value", "status-picker") == STATUS_TITLES[spec["ownStatus"]], 5)]
        if not spec["closeAllTabs"]:
            overflow = "true" if spec["overflow"] else "false"
            checks.append(("chat-tab-overflow %s" % ("shown" if spec["overflow"] else "absent"),
                           lambda: self.quiet(pid, "exists", "chat-tab-overflow") == overflow, 5))
            for variant, jid in zip(spec["tabs"], tab_jids):
                count = spec["unread"].get(variant, 0)
                expected = unread_value(count) if count else ("Typing" if conversations[variant]["peer"] in spec["typing"] else "")
                spills = spec["overflow"] and not expected

                # The bar makes chips only for the tabs that fit and lists the rest in the overflow menu. The menu shows no
                # badge or typing bubble, so a tab that must show one has to be a chip.
                def tab(chip="chat-tab-%s" % jid, expected=expected, spills=spills):
                    value = self.quiet(pid, "value", chip)
                    if value is not None:
                        return value == expected
                    return spills and self.quiet(pid, "exists", chip) == "false"
                checks.append(("chat-tab-%s reads %r%s" % (jid, expected, " or has no chip" if spills else ""),
                               tab, 10 if expected == "Typing" else 5))
        # Contact and room rows read the same as a tab, whether or not the conversation has one. A collapsed group
        # shows no rows.
        collapsed = {c["localpart"] for c in content["contacts"] if c["group"] in spec["collapsedGroups"]}
        rows = {}
        for variant, count in spec["unread"].items():
            conversation = conversations[variant]
            if conversation["peer"] not in collapsed:
                kind = "room" if conversation["kind"] == "room" else "contact"
                rows["%s-row-%s" % (kind, peer_jid(content, conversation))] = unread_value(count)
        for localpart in spec["typing"]:
            if localpart not in collapsed:
                rows.setdefault("contact-row-%s" % contact_jid(content, localpart), "Typing")
        for row, expected in rows.items():
            checks.append(("%s reads %r" % (row, expected), lambda row=row, expected=expected: self.quiet(pid, "value", row) == expected,
                           10 if expected == "Typing" else 5))
        messages = conversations[spec["tabs"][0]]["messages"]
        outgoing = [m for m in messages if m["from"] == "me"]
        if not outgoing and not spec["closeAllTabs"]:
            last = "message-bubble-%s" % messages[-1]["id"]
            checks.append(("%s shown" % last, lambda: self.quiet(pid, "exists", last) == "true", 5))
        if outgoing and not spec["closeAllTabs"]:
            # The bubble's value ends in its delivery state: "<body>, <time>, Read".
            status = spec["lastOutgoingStatus"] or outgoing[-1].get("status", "sent")
            mark = {"sent": None, "delivered": "Delivered", "read": "Read"}[status]
            bubble = "message-bubble-%s" % outgoing[-1]["id"]

            def delivery(bubble=bubble, mark=mark):
                value = self.quiet(pid, "value", bubble)
                if value is None:
                    return False
                last = value.rsplit(", ", 1)[-1]
                return last == mark if mark else last not in ("Delivered", "Read")
            checks.append(("%s reads %s" % (bubble, mark or "neither Delivered nor Read"), delivery, 5))
        if spec["input"]:
            checks.append(("message-field holds the input", lambda: self.quiet(pid, "value", "message-field") == spec["input"], 5))
        if spec["editing"]:
            checks.append(("reply-compose-bar shown", lambda: self.quiet(pid, "exists", "reply-compose-bar") == "true", 5))
        if spec["selectedContact"]:
            row = "contact-row-%s" % contact_jid(content, spec["selectedContact"])
            checks.append(("%s selected" % row, lambda: self.quiet(pid, "selected", row) == "true", 5))
        for group in spec["collapsedGroups"]:
            members = ["contact-row-%s" % contact_jid(content, c["localpart"]) for c in content["contacts"] if c["group"] == group]
            checks.append(("%s rows hidden" % group, lambda members=members: all(self.quiet(pid, "exists", m) == "false" for m in members), 5))
        if spec["closeAllTabs"]:
            checks.append(("chat-empty-state shown", lambda: self.quiet(pid, "exists", "chat-empty-state") == "true", 5))
        checks.append(("%s window focused" % spec["key"], lambda: self.quiet(pid, "focus", spec["key"]) is not None, 5))
        return checks


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build-info").add_argument("work")
    commands.add_parser("bootstrap").add_argument("work")
    run = commands.add_parser("run")
    run.add_argument("work")
    run.add_argument("manifest")
    run.add_argument("out")
    run.add_argument("--ids", type=lambda value: [v for v in value.split(",") if v])
    args = parser.parse_args()
    work = Work(args.work)
    if args.command == "build-info":
        build_info(work)
    elif args.command == "bootstrap":
        bootstrap(work)
    else:
        Run(work, args.manifest, args.out, args.ids).execute()


if __name__ == "__main__":
    main()
