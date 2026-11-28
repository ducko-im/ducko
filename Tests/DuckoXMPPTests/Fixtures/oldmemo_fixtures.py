"""Golden legacy OMEMO (XEP-0384 v0.3, eu.siacs.conversations.axolotl) fixtures from the reference Python implementation.

`generate [directory]` writes alice.json, bob.json and conversation.json (default: OMEMOLegacy/ next to this
script). Each device file holds the device's key material in the form Ducko loads (the identity key as its
32-byte Ed25519 seed, the X25519 signed pre-key and pre-key private keys), its device list and its bundle.
alice's Edwards identity key has its sign bit set and bob's has it clear, so the bundles carry the sign bit
in the signature both ways. conversation.json holds the X3DH associated data and every message alice and bob
send (the <encrypted> element, the decoded protobufs, the payload key material and the plaintext). It also
records the order in which they are sent and received. Each step lists the KDF inputs and outputs the
reference stack computed and the ratchet state it left behind. Bytes are base64; protobuf messages are the
exact bytes on the wire, and public keys inside them carry the 0x05 type prefix.

`verify <directory>...` checks Ducko's encryption against the reference stack. Each directory holds
device.json (the sender's jid, deviceID and bundle, in the device format) and conversation.json (messages
with plaintext, null for a key-transport element, and encrypted), all addressed to the fixture device bob.
It validates the bundle and every <encrypted> element against the schemas, checks the signed pre-key
signature with the sign bit the signature carries, and decrypts each message in order as a fresh bob,
building or keeping the session as the reference session manager does. It prints the first failure and
exits non-zero.

Every random draw (keys, nonces, ratchet keys, padding) comes from a SHA-512 stream seeded with a fixed
label, and the pre-key choice takes the lowest candidate, so `generate` reproduces the checked-in files byte
for byte.

Setup, outside the repository (XEdDSA ships wheels up to CPython 3.14):

    /opt/homebrew/bin/python3.14 -m venv "$TMPDIR/oldmemo-venv"
    "$TMPDIR/oldmemo-venv/bin/pip" install 'oldmemo[xml]==2.1.0' omemo==2.1.0 doubleratchet==1.3.0 x3dh==1.3.0 \
        xeddsa==1.2.0

Regenerate the fixtures:

    "$TMPDIR/oldmemo-venv/bin/python" -I Tests/DuckoXMPPTests/Fixtures/oldmemo_fixtures.py generate

Check Ducko's output:

    DUCKO_OMEMO_LEGACY_VERIFY_DIR=<dir> swift test --filter OMEMOLegacyVerify
    "$TMPDIR/oldmemo-venv/bin/python" -I Tests/DuckoXMPPTests/Fixtures/oldmemo_fixtures.py verify \
        <dir>/sign-bit-0 <dir>/sign-bit-1
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
import types
import xml.etree.ElementTree as ET

PINNED_VERSIONS = {"oldmemo": "2.1.0", "omemo": "2.1.0", "doubleratchet": "1.3.0", "x3dh": "1.3.0", "xeddsa": "1.2.0"}

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
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from omemo.session import Initiation
from oldmemo.etree import parse_bundle, parse_message, serialize_bundle, serialize_device_list, serialize_message
from oldmemo.oldmemo import (
    NAMESPACE, ContentImpl, KeyExchangeImpl, OMEMOAuthenticatedMessage, Oldmemo, PlainKeyMaterialImpl, StateImpl,
)
from oldmemo.oldmemo_pb2 import OMEMOKeyExchange, OMEMOMessage

ET.register_namespace("", NAMESPACE)

SIGNED_PRE_KEY_ID = 1
PRE_KEY_COUNT = 3
DEVICES = {
    "alice": ("alice@example.org", 31415926, 1),
    "bob": ("bob@example.org", 27182818, 0),
}


class FixtureRandomness:
    def reseed(self, label):
        self.label = label.encode()
        self.counter = 0
        self.draws = []

    def token_bytes(self, count):
        output = b""
        while len(output) < count:
            output += hashlib.sha512(b"ducko oldmemo fixtures\0" + self.label + b"\0"
                                     + self.counter.to_bytes(8, "big")).digest()
            self.counter += 1
        self.draws.append(output[:count])
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
        self.record = {"x3dh": None, "rootChainSteps": [], "messageChainSteps": [], "messageKeyMaterial": None}
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
        elif info == b"WhisperRatchet":
            self.record["rootChainSteps"].append({
                "rootKey": b64(salt), "dhOutput": b64(key_material),
                "nextRootKey": b64(output[:32]), "chainKey": b64(output[32:]),
            })
        elif info == b"WhisperMessageKeys":
            self.record["messageKeyMaterial"] = {
                "messageKey": b64(key_material),
                "encryptionKey": b64(output[:32]),
                "authenticationKey": b64(output[32:64]),
                "iv": b64(output[64:]),
            }
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


class KnownDevice:
    """The one sender device `parse_message` looks up to restore the sign bit of a key exchange's identity key."""

    def __init__(self, device):
        self.device = device

    async def get_device_information(self, bare_jid):
        assert bare_jid == self.device.jid
        return (types.SimpleNamespace(device_id=self.device.device_id, identity_key=self.device.identity_key),)

    async def refresh_device_list(self, namespace, bare_jid):
        raise omemo.DeviceListDownloadFailed(f"{bare_jid} has no device list here")


def b64(data):
    return base64.b64encode(data).decode("ascii")


def xml_string(element):
    return ET.tostring(element, encoding="unicode")


def serialized_identity_key(ed25519_public_key):
    return StateImpl.serialize_public_key(xeddsa.ed25519_pub_to_curve25519_pub(ed25519_public_key))


class Device:
    @classmethod
    async def make(cls, name):
        self = cls()
        self.name = name
        self.jid, self.device_id, sign_bit = DEVICES[name]
        self.sessions = {}
        # The first seed of the labelled streams whose Edwards public key has the wanted sign bit.
        attempt = 0
        while True:
            RANDOMNESS.reseed(f"{name} device" if attempt == 0 else f"{name} device {attempt}")
            seed = secrets.token_bytes(32)
            if xeddsa.seed_to_ed25519_pub(seed)[31] >> 7 == sign_bit:
                break
            attempt += 1
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
        self.backend = Oldmemo(storage)

        bundle = await self.backend.get_bundle(self.jid, self.device_id)
        assert bundle.signed_pre_key_id == SIGNED_PRE_KEY_ID and bundle.pre_key_ids == pre_key_ids
        self.identity_key = bundle.identity_key
        # Ducko keeps one Ed25519 seed for both versions and derives its X25519 scalar as SHA-512(seed)[0..<32].
        identity_private = xeddsa.seed_to_priv(seed)
        clamped = bytearray(hashlib.sha512(seed).digest()[:32])
        clamped[0] &= 248
        clamped[31] = (clamped[31] & 127) | 64
        assert identity_private == bytes(clamped), "The reference identity scalar is not Ducko's"
        agreement_public = xeddsa.priv_to_curve25519_pub(identity_private)
        assert self.identity_key == Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes_raw()
        assert agreement_public == xeddsa.ed25519_pub_to_curve25519_pub(self.identity_key)
        assert self.identity_key[31] >> 7 == sign_bit

        bundle_element = serialize_bundle(bundle)
        pre_keys_element = bundle_element.find(f"{{{NAMESPACE}}}prekeys")
        pre_key_elements = sorted(pre_keys_element, key=lambda element: int(element.get("preKeyId")))
        for element in pre_key_elements:
            pre_keys_element.remove(element)
        pre_keys_element.extend(pre_key_elements)
        self.bundle_xml = xml_string(bundle_element)
        published_signature = base64.b64decode(bundle_element.find(f"{{{NAMESPACE}}}signedPreKeySignature").text)
        assert parse_bundle(ET.fromstring(self.bundle_xml), self.jid, self.device_id) == bundle

        model = state.model
        pre_key_private = {xeddsa.priv_to_curve25519_pub(private): private for private in model.pre_keys}
        self.fixture = {
            "jid": self.jid,
            "deviceID": self.device_id,
            "identityKey": {
                "seed": b64(seed),
                "publicKey": b64(self.identity_key),
                "agreementPublicKey": b64(agreement_public),
                "serializedPublicKey": b64(serialized_identity_key(self.identity_key)),
                "signBit": sign_bit,
            },
            "signedPreKey": {
                "id": SIGNED_PRE_KEY_ID,
                "privateKey": b64(model.signed_pre_key.priv),
                "publicKey": b64(state.bundle.signed_pre_key),
                "signature": b64(state.bundle.signed_pre_key_sig),
                "publishedSignature": b64(published_signature),
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

    async def send(self, recipient, plaintext, iv_length=12):
        Trace.current = Trace()
        if plaintext is None:
            content, key_material = await self.backend.encrypt_empty()
        elif iv_length == 12:
            content, key_material = await self.backend.encrypt_plaintext(plaintext.encode())
        else:
            content, key_material = encrypt_plaintext_with_iv_length(plaintext.encode(), iv_length)
        session = self.sessions.get(recipient.address)
        ephemeral_private_key = None
        if session is None:
            bundle = parse_bundle(ET.fromstring(recipient.bundle_xml), recipient.jid, recipient.device_id)
            RANDOMNESS.draws = []
            session, encrypted_key_material = await self.backend.build_session_active(
                recipient.jid, recipient.device_id, bundle, key_material)
            (ephemeral_private_key,) = [
                draw for draw in RANDOMNESS.draws
                if len(draw) == 32 and xeddsa.priv_to_curve25519_pub(draw) == session.key_exchange.header.ephemeral_key
            ]
            self.sessions[recipient.address] = session
        else:
            encrypted_key_material = await self.backend.encrypt_key_material(session, key_material)
        key_exchange = (session.key_exchange
                        if session.initiation is Initiation.ACTIVE and not session.confirmed else None)
        message = omemo.Message(NAMESPACE, self.jid, self.device_id, content,
                                frozenset({(encrypted_key_material, key_exchange)}))
        step = finish_trace(session)
        if ephemeral_private_key is not None:
            step["x3dh"]["ephemeralPrivateKey"] = b64(ephemeral_private_key)
        return xml_string(serialize_message(message)), key_material.key + key_material.auth_tag, step

    async def receive(self, sender, encrypted, plaintext):
        message = await parse_message(ET.fromstring(encrypted), sender.jid, self.jid, KnownDevice(sender))
        assert message.device_id == sender.device_id, "The sid does not match the sender's device id"
        keys = [key for key in message.keys if key[0].device_id == self.device_id]
        assert len(keys) == 1, f"The message holds {len(keys)} keys for device {self.device_id}"
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
            assert len(key_material.key) == PlainKeyMaterialImpl.KEY_LENGTH and key_material.auth_tag == b"", \
                "Key-transport key material is not a 16-byte key"
        else:
            decrypted = await self.backend.decrypt_plaintext(message.content, key_material)
            assert decrypted == plaintext.encode(), f"Decrypted {decrypted!r}"
        step = finish_trace(session)
        step["session"] = outcome
        return step


def encrypt_plaintext_with_iv_length(plaintext, iv_length):
    """`Oldmemo.encrypt_plaintext` with an IV of another length, as older Conversations releases sent 16 bytes."""

    key = secrets.token_bytes(PlainKeyMaterialImpl.KEY_LENGTH)
    initialization_vector = secrets.token_bytes(iv_length)
    aes = Cipher(algorithms.AES(key), modes.GCM(initialization_vector)).encryptor()
    ciphertext = aes.update(plaintext) + aes.finalize()
    return ContentImpl(ciphertext, initialization_vector), PlainKeyMaterialImpl(key, aes.tag)


def conversations_padded(text):
    """`text` padded as Conversations' `XmppAxolotlMessage.getPaddedBytes` pads it: random tabs and spaces on both
    sides, up to a multiple of 32 bytes and at least 64."""

    length = len(text.encode())
    padding = max(64, (length // 32 + 1) * 32) - length
    draws = secrets.token_bytes(padding + 1)
    left = draws[0] % padding
    characters = ["\t" if draw & 1 else " " for draw in draws[1:]]
    return "".join(characters[:left]) + text + "".join(characters[left:])


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
    element = ET.fromstring(encrypted)
    key = element.find(f".//{{{NAMESPACE}}}key")
    data = base64.b64decode(key.text)
    if key.get("prekey") == "true":
        assert data[0] == 0x33
        key_exchange = OMEMOKeyExchange.FromString(data[1:])
        authenticated_bytes = key_exchange.message
        key_exchange_fields = {
            "pkID": key_exchange.pk_id, "spkID": key_exchange.spk_id,
            "ik": b64(key_exchange.ik), "ek": b64(key_exchange.ek), "bytes": b64(data),
        }
    else:
        authenticated_bytes = data
        key_exchange_fields = None
    authenticated = OMEMOAuthenticatedMessage.FromString(authenticated_bytes)
    assert authenticated.message[0] == 0x33
    message = OMEMOMessage.FromString(authenticated.message[1:])
    payload = element.find(f"{{{NAMESPACE}}}payload")
    return {
        "keyExchange": key_exchange_fields,
        "authenticatedMessage": {"mac": b64(authenticated.mac), "bytes": b64(authenticated_bytes)},
        "message": {
            "n": message.n, "pn": message.pn, "dhPub": b64(message.dh_pub),
            "ciphertext": b64(message.ciphertext),
            "bytes": b64(authenticated.message),
        },
        "iv": element.find(f"{{{NAMESPACE}}}header/{{{NAMESPACE}}}iv").text,
        "payload": None if payload is None else payload.text,
    }


async def generate(directory):
    alice = await Device.make("alice")
    bob = await Device.make("bob")
    RANDOMNESS.reseed("conversation")
    messages = []
    events = []

    async def send(sender, recipient, plaintext, iv_length=12):
        encrypted, key_material, step = await sender.send(recipient, plaintext, iv_length)
        index = len(messages)
        messages.append({
            "sender": sender.name, "recipient": recipient.name, "plaintext": plaintext,
            "body": None if plaintext is None else plaintext.strip(" \t"),
            "encrypted": encrypted,
            "associatedData": b64(serialized_identity_key(sender.identity_key)
                                  + serialized_identity_key(recipient.identity_key)),
            "keyMaterial": b64(key_material),
            **wire_fields(encrypted),
        })
        events.append({"party": sender.name, "action": "send", "message": index, **step})

    async def receive(recipient, index):
        message = messages[index]
        sender = alice if message["sender"] == "alice" else bob
        step = await recipient.receive(sender, message["encrypted"], message["plaintext"])
        events.append({"party": recipient.name, "action": "receive", "message": index, **step})

    await send(alice, bob, "Hello Bob!")
    await send(alice, bob, "Fish & chips <tonight>?")
    await send(alice, bob, "This one arrives last.")
    await receive(bob, 0)
    await send(bob, alice, None)
    await receive(bob, 1)
    await receive(alice, 3)
    await send(alice, bob, "Grüße 🦆, with a 16-byte IV.", iv_length=16)
    await send(alice, bob, conversations_padded("Padded as Conversations pads it."))
    await send(alice, bob, "A longer message that spans several AES blocks, so the payload is more than one block "
                           "of ciphertext.")
    await receive(bob, 4)
    await receive(bob, 6)
    await receive(bob, 5)
    await receive(bob, 2)
    await send(bob, alice, "Got them all.")
    await receive(alice, 7)

    conversation = {
        "associatedData": b64(serialized_identity_key(alice.identity_key) + serialized_identity_key(bob.identity_key)),
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
    if not xeddsa.ed25519_verify(bundle.signed_pre_key_sig, bundle.identity_key,
                                 StateImpl.serialize_public_key(bundle.signed_pre_key)):
        sys.exit(f"{directory}: the bundle's signed pre-key signature does not verify")
    bob = await Device.make("bob")
    for index, message in enumerate(conversation["messages"]):
        try:
            await bob.receive(sender, message["encrypted"], message["plaintext"])
        except Exception as error:
            sys.exit(f"{directory}: message {index}: {type(error).__name__}: {error}")
    print(f"{directory}: the reference implementation decrypted all {len(conversation['messages'])} messages")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "generate" and len(sys.argv) <= 3:
        directory = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else pathlib.Path(__file__).parent / "OMEMOLegacy"
        asyncio.run(generate(directory))
    elif len(sys.argv) >= 3 and sys.argv[1] == "verify":
        for directory in sys.argv[2:]:
            asyncio.run(verify(pathlib.Path(directory)))
    else:
        sys.exit(f"usage: {sys.argv[0]} generate [directory] | verify <directory>...")


main()
