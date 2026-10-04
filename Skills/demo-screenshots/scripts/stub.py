"""Local XMPP stub for Ducko demo screenshots.

Plays the server for one made-up account on 127.0.0.1: plaintext stream, SASL PLAIN
(any password), resource bind, a fixed roster, and presence for the made-up contacts.
Every other IQ gets a harmless canned answer. Nothing leaves this machine.

Usage: python3 stub.py <port> <workdir>
  <workdir>/stub.log     every byte string sent and received
  <workdir>/inject.txt   append one stanza per line to push it to the client; a line is
                         held until a client has received its roster and the presences
  <workdir>/avatars/<localpart>.png   optional avatars served via vcard-temp
"""
import base64
import hashlib
import os
import socket
import sys
import threading
import time
from xml.etree.ElementTree import XMLPullParser
from xml.sax.saxutils import escape, quoteattr

DOMAIN = "pond.example"
ME = "tobias@" + DOMAIN
MY_NAME = "Tobias"

# (localpart, name, group, resource, show, status); show None = available, "offline" = no presence
CONTACTS = [
    ("lena", "Lena Fischer", "Friends", "laptop", None, "Feeding the ducks"),
    ("jonas", "Jonas Weber", "Friends", "phone", "away", "At the gym"),
    ("mia", "Mia Schneider", "Friends", "laptop", None, None),
    ("noah", "Noah Becker", "Friends", None, "offline", None),
    ("priya", "Priya Nair", "Work", "desk", "dnd", "Deep work until 3"),
    ("marco", "Marco Rossi", "Work", "desk", None, "In code review"),
    ("sofia", "Sofia Lindqvist", "Work", "phone", "xa", "Back on Monday"),
    ("daniel", "Daniel Okafor", "Work", "laptop", None, None),
    ("emma", "Emma Dubois", "Work", None, "offline", None),
]

PORT = int(sys.argv[1])
WORKDIR = sys.argv[2]
LOG = open(os.path.join(WORKDIR, "stub.log"), "a", buffering=1)
INJECT = os.path.join(WORKDIR, "inject.txt")
AVATARS = os.path.join(WORKDIR, "avatars")

current = None  # the live client socket
current_lock = threading.Lock()


def log(direction, data):
    LOG.write("%s %s %s\n" % (time.strftime("%H:%M:%S"), direction, data))


def avatar(localpart):
    path = os.path.join(AVATARS, localpart + ".png")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def local(tag):
    return tag.rsplit("}", 1)[-1]


def ns(tag):
    return tag[1:].split("}", 1)[0] if tag.startswith("{") else ""


class Session:
    def __init__(self, sock):
        self.sock = sock
        self.authenticated = False
        self.full_jid = ME + "/ducko"
        self.presence_sent = False
        self.ready = False  # roster and presences are out, so injected stanzas may follow

    def send(self, data):
        log("TX", data)
        self.sock.sendall(data.encode())

    def stream_header(self):
        self.send(
            "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
            "xmlns:stream='http://etherx.jabber.org/streams' from='%s' version='1.0' id='demo%d'>"
            % (DOMAIN, int(time.time()))
        )
        if not self.authenticated:
            self.send(
                "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                "<mechanism>PLAIN</mechanism></mechanisms></stream:features>"
            )
        else:
            self.send("<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>")

    def result(self, iq, payload=""):
        self.send(
            "<iq type='result' id=%s to=%s%s>%s</iq>"
            % (quoteattr(iq.get("id", "")), quoteattr(self.full_jid), self.from_attr(iq), payload)
        )

    def error(self, iq, condition="service-unavailable"):
        self.send(
            "<iq type='error' id=%s to=%s%s><error type='cancel'>"
            "<%s xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            % (quoteattr(iq.get("id", "")), quoteattr(self.full_jid), self.from_attr(iq), condition)
        )

    @staticmethod
    def from_attr(iq):
        to = iq.get("to")
        return " from=%s" % quoteattr(to) if to else ""

    def roster(self):
        items = "".join(
            "<item jid='%s@%s' name=%s subscription='both'><group>%s</group></item>"
            % (lp, DOMAIN, quoteattr(name), escape(group))
            for lp, name, group, _, _, _ in CONTACTS
        )
        return "<query xmlns='jabber:iq:roster'>%s</query>" % items

    def send_presences(self):
        for lp, _, _, resource, show, status in CONTACTS:
            if show == "offline":
                continue
            body = ""
            if show:
                body += "<show>%s</show>" % show
            if status:
                body += "<status>%s</status>" % escape(status)
            photo = avatar(lp)
            if photo:
                body += "<x xmlns='vcard-temp:x:update'><photo>%s</photo></x>" % hashlib.sha1(photo).hexdigest()
            self.send(
                "<presence from='%s@%s/%s' to=%s>%s</presence>"
                % (lp, DOMAIN, resource, quoteattr(self.full_jid), body)
            )

    def vcard(self, bare):
        lp = bare.split("@", 1)[0]
        name = MY_NAME if bare == ME else next((n for l, n, *_ in CONTACTS if l == lp), lp)
        photo = avatar(lp)
        photo_xml = ""
        if photo:
            photo_xml = "<PHOTO><TYPE>image/png</TYPE><BINVAL>%s</BINVAL></PHOTO>" % base64.b64encode(photo).decode()
        return "<vCard xmlns='vcard-temp'><FN>%s</FN>%s</vCard>" % (escape(name), photo_xml)

    def handle_iq(self, iq):
        kind = iq.get("type")
        if kind not in ("get", "set"):
            return
        child = next(iter(iq), None)
        if child is None:
            return self.error(iq, "bad-request")
        name, space = local(child.tag), ns(child.tag)
        to = iq.get("to")
        to_bare = to.split("/", 1)[0] if to else None

        if space == "urn:ietf:params:xml:ns:xmpp-bind":
            res = child.find("{urn:ietf:params:xml:ns:xmpp-bind}resource")
            if res is not None and res.text:
                self.full_jid = "%s/%s" % (ME, res.text)
            return self.send(
                "<iq type='result' id=%s><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>%s</jid></bind></iq>"
                % (quoteattr(iq.get("id", "")), escape(self.full_jid))
            )
        if space == "urn:ietf:params:xml:ns:xmpp-session":
            return self.result(iq)
        if space == "jabber:iq:roster":
            return self.result(iq, self.roster() if kind == "get" else "")
        if space == "urn:xmpp:ping":
            return self.result(iq)
        if space == "vcard-temp":
            if kind == "set":
                return self.result(iq)
            return self.result(iq, self.vcard(to_bare or ME))
        if space == "http://jabber.org/protocol/disco#info":
            if to_bare in (None, DOMAIN):
                return self.result(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    "<identity category='server' type='im' name='Pond'/>"
                    "<feature var='http://jabber.org/protocol/disco#info'/>"
                    "<feature var='vcard-temp'/><feature var='urn:xmpp:ping'/></query>",
                )
            if to_bare == ME:
                return self.result(
                    iq,
                    "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    "<identity category='account' type='registered'/></query>",
                )
            return self.error(iq)
        if space == "http://jabber.org/protocol/disco#items":
            return self.result(iq, "<query xmlns='http://jabber.org/protocol/disco#items'/>")
        if space == "urn:xmpp:carbons:2":
            return self.result(iq)
        if space == "urn:xmpp:blocking" and kind == "get":
            return self.result(iq, "<blocklist xmlns='urn:xmpp:blocking'/>")
        if space == "urn:xmpp:mam:2" and name == "query":
            return self.result(
                iq,
                "<fin xmlns='urn:xmpp:mam:2' complete='true'>"
                "<set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin>",
            )
        if space == "http://jabber.org/protocol/pubsub":
            return self.error(iq, "item-not-found") if kind == "get" else self.result(iq)
        return self.error(iq)

    def handle(self, el):
        name, space = local(el.tag), ns(el.tag)
        if space == "urn:ietf:params:xml:ns:xmpp-sasl" and name == "auth":
            self.authenticated = True
            self.send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            return "restart"
        if name == "iq":
            self.handle_iq(el)
        elif name == "presence":
            if not el.get("type") and not el.get("to") and not self.presence_sent:
                self.presence_sent = True
                self.send_presences()
                self.ready = True
        return None

    def run(self):
        parser = XMLPullParser(events=("start", "end"))
        depth = 0
        while True:
            data = self.sock.recv(65536)
            if not data:
                return
            log("RX", data.decode(errors="replace"))
            parser.feed(data)
            restart = False
            for event, el in parser.read_events():
                if event == "start":
                    depth += 1
                    if depth == 1:
                        self.stream_header()
                else:
                    depth -= 1
                    if depth == 0:
                        self.send("</stream:stream>")
                        return
                    if depth == 1 and self.handle(el) == "restart":
                        restart = True
            if restart:
                parser = XMLPullParser(events=("start", "end"))
                depth = 0


def serve(sock):
    global current
    session = Session(sock)
    with current_lock:
        current = session
    try:
        session.run()
    except Exception as exc:  # keep the stub alive across client reconnects
        log("ERR", repr(exc))
    finally:
        with current_lock:
            if current is session:
                current = None
        sock.close()
        log("--", "connection closed")


def inject_loop():
    open(INJECT, "a").close()
    with open(INJECT) as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.2)
                continue
            line = line.strip()
            if not line:
                continue
            # Hold the line until a client is ready: one sent earlier would be lost or land mid-negotiation.
            while True:
                with current_lock:
                    session = current
                if session and session.ready:
                    break
                time.sleep(0.2)
            try:
                session.send(line.replace("{ME}", session.full_jid))
            except OSError as exc:
                log("ERR", repr(exc))


def main():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", PORT))
    listener.listen(4)
    log("--", "listening on 127.0.0.1:%d" % PORT)
    threading.Thread(target=inject_loop, daemon=True).start()
    while True:
        sock, _ = listener.accept()
        log("--", "connection accepted")
        threading.Thread(target=serve, args=(sock,), daemon=True).start()


if __name__ == "__main__":
    main()
