import base64
import hashlib
import hmac
import json
import pathlib
import socket
import ssl
import sys
import tempfile
from tls_identity import make_identity, identity_metadata
from srv_peer import DirectTLSSRVPeer
from stream_reader import StreamReader

SASL = 'urn:ietf:params:xml:ns:xmpp-sasl'
TLS = 'urn:ietf:params:xml:ns:xmpp-tls'
BIND = 'urn:ietf:params:xml:ns:xmpp-bind'
SASL2 = 'urn:xmpp:sasl:2'
BIND2 = 'urn:xmpp:bind:0'
OPEN = b"<stream:stream from='localhost' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"



def finish(connection, reader, allow_unavailable=False):
    kind, element = reader.next()
    if allow_unavailable and kind == 'stanza':
        assert element.tag == '{jabber:client}presence' and element.attrib.get('type') == 'unavailable'
        kind, element = reader.next()
    assert kind in ('close', 'eof'), kind
    if kind == 'close':
        connection.sendall(b'</stream:stream>')


def authenticate(connection, reader, leaf_der, plain, post_auth=b'', completed=None):
    mechanism = 'PLAIN' if plain else 'SCRAM-SHA-256-PLUS'
    namespace = SASL if plain else SASL2
    if plain:
        features = "<mechanisms xmlns='" + SASL + "'><mechanism>PLAIN</mechanism></mechanisms>"
    else:
        features = "<authentication xmlns='" + SASL2 + "'><mechanism>SCRAM-SHA-256-PLUS</mechanism><inline><bind xmlns='" + BIND2 + "'/></inline></authentication><sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'><channel-binding type='tls-server-end-point'/></sasl-channel-binding>"
    connection.sendall(OPEN + b'<stream:features>' + features.encode() + b'</stream:features>')
    auth = reader.stanza()
    assert auth.tag == '{' + namespace + '}' + ('auth' if plain else 'authenticate')
    assert auth.attrib['mechanism'] == mechanism
    if not plain:
        assert auth.find('{' + BIND2 + '}bind') is not None
        assert auth.find('{' + SASL2 + '}user-agent/{' + SASL2 + '}software').text == 'Ducko'
    first = base64.b64decode(auth.text if plain else auth.find('{' + SASL2 + '}initial-response').text)
    if plain:
        assert first == b'\0alice\0local-fixture'
        connection.sendall(("<success xmlns='" + SASL + "'/>").encode())
    else:
        header = b'p=tls-server-end-point,,'
        assert first.startswith(header)
        bare = first[len(header):]
        fields = dict(item.split(b'=', 1) for item in bare.split(b','))
        assert fields[b'n'] == b'alice'
        nonce = fields[b'r'] + b'-local-server'
        salt = b'ducko-local-test-salt'
        challenge = b'r=' + nonce + b',s=' + base64.b64encode(salt) + b',i=4096'
        connection.sendall(("<challenge xmlns='" + namespace + "'>").encode() + base64.b64encode(challenge) + b'</challenge>')
        response = reader.stanza()
        assert response.tag == '{' + namespace + '}response'
        final = base64.b64decode(response.text)
        fields = dict(item.split(b'=', 1) for item in final.split(b','))
        assert fields[b'r'] == nonce
        assert base64.b64decode(fields[b'c']) == header + hashlib.sha256(leaf_der).digest()
        message = bare + b',' + challenge + b',' + final.rsplit(b',p=', 1)[0]
        salted = hashlib.pbkdf2_hmac('sha256', b'local-fixture', salt, 4096)
        client_key = hmac.new(salted, b'Client Key', hashlib.sha256).digest()
        stored_key = hashlib.sha256(client_key).digest()
        signature = hmac.new(stored_key, message, hashlib.sha256).digest()
        proof = base64.b64decode(fields[b'p'])
        assert hmac.compare_digest(proof, bytes(a ^ b for a, b in zip(client_key, signature)))
        server_key = hmac.new(salted, b'Server Key', hashlib.sha256).digest()
        server_signature = hmac.new(server_key, message, hashlib.sha256).digest()
        success = b'v=' + base64.b64encode(server_signature)
        connection.sendall(("<success xmlns='" + SASL2 + "'><additional-data>").encode() + base64.b64encode(success) + ("</additional-data><authorization-identifier>alice@localhost/fixture</authorization-identifier><bound xmlns='" + BIND2 + "'/></success><stream:features>").encode() + post_auth + b'</stream:features>')
        if completed:
            completed(connection, reader)
        else:
            finish(connection, reader, allow_unavailable=True)
        return
    reader = StreamReader(connection)
    reader.opened()
    connection.sendall(OPEN + ("<stream:features><bind xmlns='" + BIND + "'/></stream:features>").encode())
    request = reader.stanza()
    assert request.tag == '{jabber:client}iq' and request.find('{' + BIND + '}bind') is not None
    result = "<iq type='result' id='" + request.attrib['id'] + "'><bind xmlns='" + BIND + "'><jid>alice@localhost/fixture</jid></bind></iq>"
    connection.sendall(result.encode())
    if completed:
        completed(connection, reader)
    else:
        finish(connection, reader, allow_unavailable=True)


def run(mode, root, leaf_der, listener):
    connection, _ = listener.accept()
    connection.settimeout(8)
    with connection:
        if mode not in ('client-direct', 'registration-direct'):
            reader = StreamReader(connection)
            reader.opened()
            advertise = mode not in ('client-forced', 'client-refused', 'client-plain', 'registration-no-tls')
            features = b"<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" if advertise else b''
            if mode == 'client-plain':
                authenticate(connection, reader, leaf_der, plain=True)
                return
            connection.sendall(OPEN + b'<stream:features>' + features + b'</stream:features>')
            if mode == 'registration-no-tls':
                finish(connection, reader)
                return
            start = reader.stanza()
            assert start.tag == '{' + TLS + '}starttls', 'Authentication was attempted before TLS'
            if mode == 'client-refused':
                connection.sendall(("<failure xmlns='" + TLS + "'/>").encode())
                finish(connection, reader)
                return
            proceed = ("<proceed xmlns='" + TLS + "'/>").encode()
            if mode == 'client-contaminated':
                connection.sendall(proceed + b'<message><body>unexpected</body></message>')
                finish(connection, reader)
                return
            connection.sendall(proceed)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_3 if ssl.HAS_TLSv1_3 else ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root/'server.pem', root/'server.key')
        context.set_alpn_protocols(['xmpp-client'])
        try:
            secure = context.wrap_socket(connection, server_side=True)
        except ssl.SSLError:
            assert mode == 'client-untrusted'
            return
        with secure:
            assert mode != 'client-untrusted'
            assert secure.version() == ('TLSv1.3' if ssl.HAS_TLSv1_3 else 'TLSv1.2')
            assert secure.selected_alpn_protocol() == 'xmpp-client'
            reader = StreamReader(secure)
            reader.opened()
            if mode.startswith('registration'):
                secure.sendall(OPEN + b"<stream:features><register xmlns='http://jabber.org/features/iq-register'/></stream:features>")
                request = reader.stanza()
                assert request.tag == '{jabber:client}iq' and request.attrib['type'] == 'get'
                assert request.find('{jabber:iq:register}query') is not None
                if mode == 'registration-error':
                    result = "<iq type='error' id='" + request.attrib['id'] + "'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
                else:
                    result = "<iq type='result' id='" + request.attrib['id'] + "'><query xmlns='jabber:iq:register'><instructions>Local fixture</instructions><username/><password/><email/></query></iq>"
                secure.sendall(result.encode())
                finish(secure, reader)
            else:
                authenticate(secure, reader, leaf_der, plain=False)


def main():
    mode = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix='ducko-xmpp-tls-') as temporary:
        root = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path(temporary)
        if len(sys.argv) == 2:
            make_identity(root, mode)
        leaf_der, metadata = identity_metadata(root)
        metadata['protocolVersion'] = 'TLS 1.3' if ssl.HAS_TLSv1_3 else 'TLS 1.2'
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.settimeout(10)
            port = listener.getsockname()[1]
            resolver = DirectTLSSRVPeer(port) if mode == 'registration-direct' else None
            try:
                print(json.dumps(dict(metadata, port=port)), flush=True)
                run(mode, root, leaf_der, listener)
            finally:
                if resolver:
                    resolver.close()


if __name__ == '__main__':
    main()
