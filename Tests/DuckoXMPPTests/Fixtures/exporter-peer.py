import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
from tls_identity import make_identity, identity_metadata

CASES = {
    'tls13-aes128': ['-tls1_3', '-ciphersuites', 'TLS_AES_128_GCM_SHA256'],
    'tls13-chacha20': ['-tls1_3', '-ciphersuites', 'TLS_CHACHA20_POLY1305_SHA256'],
    'tls13-aes256': ['-tls1_3', '-ciphersuites', 'TLS_AES_256_GCM_SHA384'],
    # The client's first key share is not for P-384, so the server answers with a HelloRetryRequest.
    'tls13-hrr': ['-tls1_3', '-groups', 'P-384'],
    'tls12': ['-tls1_2'],
}

# A stopped peer exits through the finally blocks below, which remove its certificates and stop s_server.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
mode = sys.argv[1]
temporary = tempfile.TemporaryDirectory(prefix="ducko-exporter-test-")
root = pathlib.Path(temporary.name)
make_identity(root, 'direct')
_, metadata = identity_metadata(root)
if mode == 'identity':
    # Only the certificates, for a TLS server the test runs itself. They stay on disk until the test stops this peer or
    # 10 seconds pass, since the test reads the root from rootPath after the line arrives.
    try:
        print(json.dumps(dict(metadata, port=0, certificate=(root / 'server.pem').read_text(),
                              key=(root / 'server.key').read_text())), flush=True)
        time.sleep(10)
    finally:
        temporary.cleanup()
    sys.exit(0)
# s_server quits on EOF from stdin, so stdin stays an open pipe until the handshake is over.
server = subprocess.Popen(
    [os.environ['DUCKO_TLS_OPENSSL'], 's_server', '-accept', '127.0.0.1:0', '-naccept', '1',
     '-cert', str(root / 'server.pem'), '-key', str(root / 'server.key'),
     '-keymatexport', 'EXPORTER-Channel-Binding', '-keymatexportlen', '32', *CASES[mode]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
watchdog = threading.Timer(8, server.kill)
watchdog.start()
try:
    keying_material = None
    for output in server.stdout:
        output = output.strip()
        if output.startswith('ACCEPT '):
            print(json.dumps(dict(metadata, port=int(output.rsplit(':', 1)[1]))), flush=True)
        elif output.startswith('Keying material:'):
            keying_material = output.split(':', 1)[1].strip().lower()
            print(json.dumps({'keyingMaterial': keying_material}), flush=True)
            break
    assert keying_material, 'The handshake exported no keying material'
    server.stdin.close()
    server.wait()
finally:
    watchdog.cancel()
    if server.poll() is None:
        server.kill()
    temporary.cleanup()
