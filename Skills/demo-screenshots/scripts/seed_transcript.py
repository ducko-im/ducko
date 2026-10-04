"""Overwrites a transcript day file with the made-up demo conversation.

Usage: python3 seed_transcript.py <path to Transcripts/<conversation-id>/<YYYY-MM-DD>.jsonl>

The day comes from the file name. Times are UTC and show in local time.
"""
import json
import os
import sys
import uuid

ME, PEER = "tobias@pond.example", "lena@pond.example"

# (outgoing, UTC time, body). Four single-line messages fill the default chat window without scrolling.
MESSAGES = [
    (False, "14:03:40", "Meeting at the pond at six. Are you in? 🦆"),
    (True, "14:05:12", "Sounds good! I'll bring coffee ☕️"),
    (False, "14:05:48", "Perfect. Jonas is bringing snacks."),
    (True, "14:07:05", "See you there!"),
]

path = sys.argv[1]
day = os.path.basename(path).removesuffix(".jsonl")
with open(path, "w") as f:
    for index, (outgoing, clock, body) in enumerate(MESSAGES, 1):
        record = {
            "attachments": [],
            "body": body,
            "fromJID": ME if outgoing else PEER,
            "id": str(uuid.uuid4()).upper(),
            "isEncrypted": False,
            "isOutgoing": outgoing,
            "isUndecryptable": False,
            "messageType": "chat",
            "stanzaID": "demo-%d" % index,
            "timestamp": "%sT%sZ" % (day, clock),
            "type": "msg",
        }
        f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
print("%d messages written to %s" % (len(MESSAGES), path))
