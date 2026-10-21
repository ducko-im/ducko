"""Golden OMEMO 2 (XEP-0384 urn:xmpp:omemo:2) fixtures from the reference Python implementation.

`generate [directory]` writes alice.json, bob.json and conversation.json (default: OMEMO2/ next to this
script). Each device file holds the device's key material in the form Ducko loads (the identity key as its
32-byte Ed25519 seed, the X25519 signed pre-key and pre-key private keys), its device list and its bundle.
conversation.json holds the X3DH associated data and every message alice and bob send (the <encrypted>
element, the decoded protobufs and the SCE envelope plaintext). It also records the order in which they
are sent and received. Each step lists the KDF inputs and outputs the reference stack computed and the
ratchet state it left behind. Bytes are base64; protobuf messages are the exact bytes on the wire.

`verify <directory>` checks Ducko's encryption against the reference stack. It reads device.json (the
sender's jid, deviceID and bundle, in the device format) and conversation.json (messages with plaintext,
null for an empty OMEMO message, and encrypted), all addressed to the fixture device bob. It validates
the bundle and every <encrypted> element against the schemas, checks the signed pre-key signature, and
decrypts each message in order as bob, building or keeping the session as the reference session manager
does. It prints the first failure and exits non-zero.

Every random draw (keys, nonces, ratchet keys) comes from a SHA-512 stream seeded with a fixed label, and
the pre-key choice takes the lowest candidate, so `generate` reproduces the checked-in files byte for byte.

Setup, outside the repository (XEdDSA ships wheels up to CPython 3.14):

    /opt/homebrew/bin/python3.14 -m venv "$TMPDIR/omemo2-venv"
    "$TMPDIR/omemo2-venv/bin/pip" install 'twomemo[xml]==2.1.0' omemo==2.1.0 doubleratchet==1.3.0 x3dh==1.3.0

Regenerate the fixtures:

    "$TMPDIR/omemo2-venv/bin/python" -I Tests/DuckoXMPPTests/Fixtures/omemo2_fixtures.py generate

Check Ducko's output:

    DUCKO_OMEMO2_VERIFY_DIR=<dir> swift test --filter OMEMO2Verify
    "$TMPDIR/omemo2-venv/bin/python" -I Tests/DuckoXMPPTests/Fixtures/omemo2_fixtures.py verify <dir>
"""

import asyncio
import base64
import hashlib
import importlib.metadata
import inspect
import json
import pathlib
import secrets
import sys
import xml.etree.ElementTree as ET

PINNED_VERSIONS = {"twomemo": "2.1.0", "omemo": "2.1.0", "doubleratchet": "1.3.0", "x3dh": "1.3.0"}

for package, version in PINNED_VERSIONS.items():
    installed = importlib.metadata.version(package)
    if installed != version:
        sys.exit(f"{package} {installed} is installed; the fixtures are pinned to {version}")

import doubleratchet.recommended.crypto_provider_cryptography
import doubleratchet.recommended.diffie_hellman_ratchet_curve25519
import omemo
import x3dh
import x3dh.crypto_provider_cryptography
import x3dh.identity_key_pair
import xeddsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from omemo.session import Initiation
from twomemo.etree import parse_bundle, parse_message, serialize_bundle, serialize_device_list, serialize_message
from twomemo.twomemo import NAMESPACE, StateImpl, Twomemo
from twomemo.twomemo_pb2 import OMEMOAuthenticatedMessage, OMEMOKeyExchange, OMEMOMessage

ET.register_namespace("", NAMESPACE)

SIGNED_PRE_KEY_ID = 1
PRE_KEY_COUNT = 3
DEVICES = {
    "alice": ("alice@example.org", 31415926),
    "bob": ("bob@example.org", 27182818),
}


class FixtureRandomness:
    def reseed(self, label):
        self.label = label.encode()
        self.counter = 0

    def token_bytes(self, count):
        output = b""
        while len(output) < count:
            output += hashlib.sha512(b"ducko omemo2 fixtures\0" + self.label + b"\0"
                                     + self.counter.to_bytes(8, "big")).digest()
            self.counter += 1
        return output[:count]


RANDOMNESS = FixtureRandomness()
secrets.token_bytes = RANDOMNESS.token_bytes
secrets.choice = min
doubleratchet.recommended.diffie_hellman_ratchet_curve25519.DiffieHellmanRatchet._generate_priv = \
    staticmethod(lambda: secrets.token_bytes(32))


class Trace:
    """Collects the KDF steps the reference stack runs during one send or receive."""

    current = None

    def __init__(self):
        self.record = {
            "x3dh": None, "rootChainSteps": [], "messageChainSteps": [],
            "messageKeyMaterial": None, "payloadKeyMaterial": None,
        }
        self.pending_chain_key = None

    def hkdf(self, info, salt, key_material, output):
        if info == StateImpl.INFO:
            self.record["x3dh"] = {
                "dh1": b64(key_material[32:64]),
                "dh2": b64(key_material[64:96]),
                "dh3": b64(key_material[96:128]),
                "dh4": b64(key_material[128:]),
                "sharedSecret": b64(output),
            }
        elif info == b"OMEMO Root Chain":
            self.record["rootChainSteps"].append({
                "rootKey": b64(salt), "dhOutput": b64(key_material),
                "nextRootKey": b64(output[:32]), "chainKey": b64(output[32:]),
            })
        elif info == b"OMEMO Message Key Material":
            self.record["messageKeyMaterial"] = split_key_material("messageKey", key_material, output)
        elif info == b"OMEMO Payload":
            self.record["payloadKeyMaterial"] = split_key_material("key", key_material, output)
        else:
            raise AssertionError(f"Unexpected HKDF info {info!r}")

    def hmac(self, key, data, output):
        if data == b"\x02":
            self.pending_chain_key = (key, output)
        elif data == b"\x01" and self.pending_chain_key is not None and self.pending_chain_key[0] == key:
            self.record["messageChainSteps"].append({
                "chainKey": b64(key), "nextChainKey": b64(self.pending_chain_key[1]), "messageKey": b64(output),
            })
            self.pending_chain_key = None


def split_key_material(input_name, key_material, output):
    return {
        input_name: b64(key_material),
        "encryptionKey": b64(output[:32]),
        "authenticationKey": b64(output[32:64]),
        "iv": b64(output[64:]),
    }


def traced(provider, name):
    original = getattr(provider, name)
    signature = inspect.signature(original)

    async def wrapper(*args, **kwargs):
        output = await original(*args, **kwargs)
        if Trace.current is not None:
            arguments = signature.bind(*args, **kwargs).arguments
            if name == "hkdf_derive":
                Trace.current.hkdf(arguments["info"], arguments["salt"], arguments["key_material"], output)
            else:
                Trace.current.hmac(arguments["key"], arguments["data"], output)
        return output

    setattr(provider, name, staticmethod(wrapper))


traced(x3dh.crypto_provider_cryptography.CryptoProviderImpl, "hkdf_derive")
traced(doubleratchet.recommended.crypto_provider_cryptography.CryptoProviderImpl, "hkdf_derive")
traced(doubleratchet.recommended.crypto_provider_cryptography.CryptoProviderImpl, "hmac_calculate")


class MemoryStorage(omemo.Storage):
    def __init__(self):
        super().__init__(True)
        self.values = {}

    async def _load(self, key):
        return omemo.Just(self.values[key]) if key in self.values else omemo.Nothing()

    async def _store(self, key, value):
        self.values[key] = value

    async def _delete(self, key):
        self.values.pop(key, None)


def b64(data):
    return base64.b64encode(data).decode("ascii")


def xml_string(element):
    return ET.tostring(element, encoding="unicode")


class Device:
    @classmethod
    async def make(cls, name):
        self = cls()
        self.name = name
        self.jid, self.device_id = DEVICES[name]
        self.sessions = {}
        RANDOMNESS.reseed(f"{name} device")
        seed = secrets.token_bytes(32)
        state = StateImpl.create(x3dh.IdentityKeyFormat.ED_25519, x3dh.HashFunction.SHA_256, StateImpl.INFO,
                                 x3dh.identity_key_pair.IdentityKeyPairSeed(seed))
        pre_key_ids = {}
        for pre_key_id in range(1, PRE_KEY_COUNT + 1):
            existing = state.bundle.pre_keys
            state.generate_pre_keys(1)
            (pre_key,) = state.bundle.pre_keys - existing
            pre_key_ids[pre_key] = pre_key_id

        storage = MemoryStorage()
        await storage.store("/ikp/is_seed", True)
        await storage.store_bytes("/ikp/key", seed)
        await storage.store(f"/{NAMESPACE}/x3dh", state.json)
        await storage.store(f"/{NAMESPACE}/signed_pre_key_ids", {b64(state.bundle.signed_pre_key): SIGNED_PRE_KEY_ID})
        await storage.store(f"/{NAMESPACE}/pre_key_ids", {b64(key): key_id for key, key_id in pre_key_ids.items()})
        await storage.store(f"/{NAMESPACE}/pre_key_id_counter", PRE_KEY_COUNT)
        self.backend = Twomemo(storage)

        bundle = await self.backend.get_bundle(self.jid, self.device_id)
        assert bundle.signed_pre_key_id == SIGNED_PRE_KEY_ID and bundle.pre_key_ids == pre_key_ids
        self.identity_key = bundle.identity_key
        identity_private = xeddsa.seed_to_priv(seed)
        agreement_public = xeddsa.priv_to_curve25519_pub(identity_private)
        assert self.identity_key == Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes_raw()
        assert agreement_public == xeddsa.ed25519_pub_to_curve25519_pub(self.identity_key)

        bundle_element = serialize_bundle(bundle)
        pre_keys_element = bundle_element.find(f"{{{NAMESPACE}}}prekeys")
        pre_key_elements = sorted(pre_keys_element, key=lambda element: int(element.get("id")))
        for element in pre_key_elements:
            pre_keys_element.remove(element)
        pre_keys_element.extend(pre_key_elements)
        self.bundle_xml = xml_string(bundle_element)

        model = state.model
        pre_key_private = {xeddsa.priv_to_curve25519_pub(private): private for private in model.pre_keys}
        self.fixture = {
            "jid": self.jid,
            "deviceID": self.device_id,
            "identityKey": {
                "seed": b64(seed),
                "publicKey": b64(self.identity_key),
                "agreementPublicKey": b64(agreement_public),
            },
            "signedPreKey": {
                "id": SIGNED_PRE_KEY_ID,
                "privateKey": b64(model.signed_pre_key.priv),
                "publicKey": b64(state.bundle.signed_pre_key),
                "signature": b64(state.bundle.signed_pre_key_sig),
            },
            "preKeys": [
                {"id": key_id, "privateKey": b64(pre_key_private[key]), "publicKey": b64(key)}
                for key, key_id in sorted(pre_key_ids.items(), key=lambda item: item[1])
            ],
            "deviceList": xml_string(serialize_device_list({self.device_id: None})),
            "bundle": self.bundle_xml,
        }
        return self

    @property
    def address(self):
        return (self.jid, self.device_id)

    async def send(self, recipient, plaintext):
        Trace.current = Trace()
        if plaintext is None:
            content, key_material = await self.backend.encrypt_empty()
        else:
            content, key_material = await self.backend.encrypt_plaintext(plaintext.encode())
        session = self.sessions.get(recipient.address)
        if session is None:
            bundle = parse_bundle(ET.fromstring(recipient.bundle_xml), recipient.jid, recipient.device_id)
            session, encrypted_key_material = await self.backend.build_session_active(
                recipient.jid, recipient.device_id, bundle, key_material)
            self.sessions[recipient.address] = session
        else:
            encrypted_key_material = await self.backend.encrypt_key_material(session, key_material)
        key_exchange = (session.key_exchange
                        if session.initiation is Initiation.ACTIVE and not session.confirmed else None)
        message = omemo.Message(NAMESPACE, self.jid, self.device_id, content,
                                frozenset({(encrypted_key_material, key_exchange)}))
        step = finish_trace(session)
        if plaintext is not None:
            step["payloadKeyMaterial"]["hmac"] = b64(key_material.auth_tag)
        return xml_string(serialize_message(message)), step

    async def receive(self, sender, encrypted, plaintext):
        message = parse_message(ET.fromstring(encrypted), sender.jid)
        assert message.device_id == sender.device_id, "The sid does not match the sender's device id"
        keys = [key for key in message.keys if (key[0].bare_jid, key[0].device_id) == self.address]
        assert len(keys) == 1, f"The message holds {len(keys)} keys for {self.jid}/{self.device_id}"
        encrypted_key_material, key_exchange = keys[0]
        session = self.sessions.get(sender.address)
        Trace.current = Trace()
        if key_exchange is not None and (session is None or not session.key_exchange.builds_same_session(key_exchange)):
            assert key_exchange.identity_key == sender.identity_key, "The key exchange's ik is not the bundle's ik"
            session, key_material = await self.backend.build_session_passive(
                sender.jid, sender.device_id, key_exchange, encrypted_key_material)
            self.sessions[sender.address] = session
            outcome = "built"
        else:
            assert session is not None, "The first message does not carry a key exchange"
            key_material = await self.backend.decrypt_key_material(session, encrypted_key_material)
            outcome = "kept"
        if message.content.empty:
            assert plaintext is None, "The message has no payload"
            assert key_material.key == bytes(32) and key_material.auth_tag == b"", "Empty message key material"
        else:
            decrypted = await self.backend.decrypt_plaintext(message.content, key_material)
            assert decrypted == plaintext.encode(), f"Decrypted {decrypted!r}"
        step = finish_trace(session)
        step["session"] = outcome
        if not message.content.empty:
            step["payloadKeyMaterial"]["hmac"] = b64(key_material.auth_tag)
        return step


def finish_trace(session):
    record = Trace.current.record
    Trace.current = None
    record["ratchet"] = ratchet_state(session.double_ratchet.model)
    return record


def ratchet_state(model):
    ratchet = model.diffie_hellman_ratchet
    chains = ratchet.symmetric_key_ratchet

    def chain(kdf_chain):
        return None if kdf_chain is None else {"key": b64(kdf_chain.key), "length": kdf_chain.length}

    return {
        "ownPrivateKey": b64(ratchet.own_ratchet_priv),
        "ownPublicKey": b64(xeddsa.priv_to_curve25519_pub(ratchet.own_ratchet_priv)),
        "otherPublicKey": b64(ratchet.other_ratchet_pub),
        "rootKey": b64(ratchet.root_chain.key),
        "sendingChain": chain(chains.sending_chain),
        "receivingChain": chain(chains.receiving_chain),
        "previousSendingChainLength": chains.previous_sending_chain_length,
        "skippedMessageKeys": [
            {"ratchetPublicKey": b64(key.ratchet_pub), "index": key.index, "messageKey": b64(key.message_key)}
            for key in model.skipped_message_keys
        ],
    }


def wire_fields(encrypted):
    key = ET.fromstring(encrypted).find(f".//{{{NAMESPACE}}}key")
    data = base64.b64decode(key.text)
    kex = key.get("kex") == "true"
    if kex:
        key_exchange = OMEMOKeyExchange.FromString(data)
        authenticated_bytes = key_exchange.message.SerializeToString()
        key_exchange_fields = {
            "pkID": key_exchange.pk_id, "spkID": key_exchange.spk_id,
            "ik": b64(key_exchange.ik), "ek": b64(key_exchange.ek), "bytes": b64(data),
        }
    else:
        authenticated_bytes = data
        key_exchange_fields = None
    authenticated = OMEMOAuthenticatedMessage.FromString(authenticated_bytes)
    message = OMEMOMessage.FromString(authenticated.message)
    payload = ET.fromstring(encrypted).find(f"{{{NAMESPACE}}}payload")
    return {
        "keyExchange": key_exchange_fields,
        "authenticatedMessage": {"mac": b64(authenticated.mac), "bytes": b64(authenticated_bytes)},
        "message": {
            "n": message.n, "pn": message.pn, "dhPub": b64(message.dh_pub),
            "ciphertext": b64(message.ciphertext) if message.HasField("ciphertext") else None,
            "bytes": b64(authenticated.message),
        },
        "payload": None if payload is None else payload.text,
    }


def envelope(body, sender, recipient, stamp, padding):
    return ("<envelope xmlns='urn:xmpp:sce:1'>"
            f"<content><body xmlns='jabber:client'>{body}</body></content>"
            f"<rpad>{padding}</rpad>"
            f"<time stamp='{stamp}'/>"
            f"<to jid='{recipient.jid}'/>"
            f"<from jid='{sender.jid}'/>"
            "</envelope>")


async def generate(directory):
    alice = await Device.make("alice")
    bob = await Device.make("bob")
    RANDOMNESS.reseed("conversation")
    messages = []
    events = []

    async def send(sender, recipient, plaintext):
        encrypted, step = await sender.send(recipient, plaintext)
        index = len(messages)
        messages.append({"sender": sender.name, "recipient": recipient.name, "plaintext": plaintext,
                         "encrypted": encrypted, **wire_fields(encrypted)})
        events.append({"party": sender.name, "action": "send", "message": index, **step})

    async def receive(recipient, index):
        message = messages[index]
        sender = alice if message["sender"] == "alice" else bob
        step = await recipient.receive(sender, message["encrypted"], message["plaintext"])
        events.append({"party": recipient.name, "action": "receive", "message": index, **step})

    await send(alice, bob, envelope("Hello Bob!", alice, bob, "2026-10-20T12:00:00Z", "kAvF"))
    await send(alice, bob, envelope("Fish &amp; chips tonight?", alice, bob, "2026-10-20T12:00:05Z", "Qx"))
    await send(alice, bob, envelope("This one arrives last.", alice, bob, "2026-10-20T12:00:10Z", "eW3pZ1"))
    await receive(bob, 0)
    await send(bob, alice, None)
    await receive(bob, 1)
    await receive(alice, 3)
    await send(alice, bob, envelope("Grüße 🦆", alice, bob, "2026-10-20T12:01:00Z", ""))
    await send(alice, bob, envelope("Out of order, second.", alice, bob, "2026-10-20T12:01:05Z", "p"))
    await send(alice, bob, envelope("A longer message that spans several AES blocks, so the payload is more "
                                    "than one block of ciphertext.", alice, bob, "2026-10-20T12:01:10Z", "Zz9"))
    await receive(bob, 4)
    await receive(bob, 6)
    await receive(bob, 5)
    await receive(bob, 2)
    await send(bob, alice, envelope("Got them all.", bob, alice, "2026-10-20T12:02:00Z", "r0Ta"))
    await receive(alice, 7)

    conversation = {
        "associatedData": b64(alice.identity_key + bob.identity_key),
        "messages": messages,
        "events": events,
    }
    directory.mkdir(parents=True, exist_ok=True)
    for name, value in (("alice", alice.fixture), ("bob", bob.fixture), ("conversation", conversation)):
        (directory / f"{name}.json").write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


async def verify(directory):
    device = json.loads((directory / "device.json").read_text(encoding="utf-8"))
    conversation = json.loads((directory / "conversation.json").read_text(encoding="utf-8"))
    sender = Device()
    sender.name = "ducko"
    sender.jid, sender.device_id = device["jid"], device["deviceID"]
    bundle = parse_bundle(ET.fromstring(device["bundle"]), sender.jid, sender.device_id).bundle
    sender.identity_key = bundle.identity_key
    if not xeddsa.ed25519_verify(bundle.signed_pre_key_sig, bundle.identity_key, bundle.signed_pre_key):
        sys.exit("The bundle's signed pre-key signature does not verify")
    bob = await Device.make("bob")
    for index, message in enumerate(conversation["messages"]):
        try:
            await bob.receive(sender, message["encrypted"], message["plaintext"])
        except Exception as error:
            sys.exit(f"Message {index}: {type(error).__name__}: {error}")
    print(f"The reference implementation decrypted all {len(conversation['messages'])} messages")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "generate" and len(sys.argv) <= 3:
        directory = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else pathlib.Path(__file__).parent / "OMEMO2"
        asyncio.run(generate(directory))
    elif len(sys.argv) == 3 and sys.argv[1] == "verify":
        asyncio.run(verify(pathlib.Path(sys.argv[2])))
    else:
        sys.exit(f"usage: {sys.argv[0]} generate [directory] | verify <directory>")


main()
