"""Writes one made-up conversation from content.json into a transcript folder.

Usage: python3 seed_transcript.py <conversation dir> <variant> [--last-outgoing-status S] [--content content.json]
  <conversation dir>         Transcripts/<conversation id>, created when missing
  <variant>                  a key under "conversations" in the content file
  --last-outgoing-status S   sent, delivered or read, replacing the last outgoing message's status
  --content                  defaults to the skill's own content.json

Times are on presentation.date in presentation.timeZone. Writes a day file per UTC date, as the app names them, and
removes the folder's other day files. An edit's time is relative to now, so its "(edited …)" label reads the same on
every run unless a minute rolls over before the capture.
"""
import argparse
import datetime
import json
import os
import zoneinfo

STATUS_AMENDMENT = {"sent": None, "delivered": "delivery", "read": "displayed"}

parser = argparse.ArgumentParser()
parser.add_argument("directory")
parser.add_argument("variant")
parser.add_argument("--last-outgoing-status", choices=sorted(STATUS_AMENDMENT))
parser.add_argument("--content", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content.json"))
args = parser.parse_args()

with open(args.content, encoding="utf-8") as f:
    content = json.load(f)
presentation = content["presentation"]
conversation = content["conversations"][args.variant]
domain = content["account"]["jid"].split("@", 1)[1]
if conversation["kind"] == "room":
    peer = next(room["jid"] for room in content["rooms"] if room["key"] == conversation["peer"])
else:
    peer = "%s@%s" % (conversation["peer"], domain)

messages = [dict(message) for message in conversation["messages"]]
outgoing = [message for message in messages if message["from"] == "me"]
if args.last_outgoing_status and outgoing:
    outgoing[-1]["status"] = args.last_outgoing_status

zone = zoneinfo.ZoneInfo(presentation["timeZone"])
now = datetime.datetime.now(datetime.timezone.utc)


def iso(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sender(message):
    # The app stores an outgoing message under the conversation's address, and a room message under the nickname.
    if message["from"] == "me" or message["from"] == "peer":
        return peer
    return message["from"]


def moment_of(message):
    return datetime.datetime.fromisoformat("%sT%s" % (presentation["date"], message["time"])).replace(tzinfo=zone)


# A reply names the quoted message by its stanza id, as the app looks it up.
stanza_of = {message["id"]: message["stanzaID"] for message in messages}

# An amendment goes into its target message's day file, as the app files it.
days = {}
day_of = {}
for message in messages:
    moment = moment_of(message)
    body = message["body"]
    if "editedSecondsAgo" in message:
        body = body.rsplit(" ", 1)[0] if " " in body else body[:-1]
    day_of[message["id"]] = iso(moment)[:10]
    line = {
        "attachments": message.get("attachments", []),
        "body": body,
        "fromJID": sender(message),
        "id": message["id"],
        "isEncrypted": False,
        "isOutgoing": message["from"] == "me",
        "isUndecryptable": False,
        "messageType": "groupchat" if conversation["kind"] == "room" else "chat",
        "stanzaID": message["stanzaID"],
        "timestamp": iso(moment),
        "type": "msg",
    }
    if "replyTo" in message:
        line["replyToID"] = stanza_of[message["replyTo"]]
    days.setdefault(day_of[message["id"]], []).append(line)
for message in messages:
    lines = days[day_of[message["id"]]]
    action = STATUS_AMENDMENT[message["status"]] if "status" in message else None
    if action:
        lines.append({"action": action, "targetMessageID": message["id"], "timestamp": iso(now), "type": "amend"})
    if "editedSecondsAgo" in message:
        edited = now - datetime.timedelta(seconds=message["editedSecondsAgo"])
        lines.append({
            "action": "edit", "body": message["body"], "targetMessageID": message["id"], "timestamp": iso(edited), "type": "amend",
        })
    # Retracted at the message's own time, so its "(retracted …)" label changes monthly rather than by the minute.
    if message.get("retracted"):
        lines.append({"action": "retract", "targetMessageID": message["id"], "timestamp": iso(moment_of(message)), "type": "amend"})

os.makedirs(args.directory, exist_ok=True)
for name in os.listdir(args.directory):
    if name.endswith(".jsonl"):
        os.remove(os.path.join(args.directory, name))
for day, lines in sorted(days.items()):
    path = os.path.join(args.directory, day + ".jsonl")
    with open(path, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(json.dumps(line, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")
print("%d messages written to %s" % (len(messages), ", ".join(os.path.join(args.directory, day + ".jsonl") for day in sorted(days))))
