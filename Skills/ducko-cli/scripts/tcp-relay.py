"""TCP relay for staging a connection drop.

Usage: python3 tcp-relay.py <listen-port> <target-host> [target-port]

Forwards 127.0.0.1:<listen-port> to <target-host>:<target-port> (default 5222).
SIGUSR1 closes every relayed socket pair while the listener stays up, so the
client sees a lost connection and can reconnect (and resume) through the relay.
"""

import asyncio
import signal
import sys

if len(sys.argv) not in (3, 4):
    sys.exit(__doc__)

LISTEN_PORT = int(sys.argv[1])
TARGET_HOST = sys.argv[2]
TARGET_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 5222

writers: set[asyncio.StreamWriter] = set()


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    try:
        server_reader, server_writer = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
    except OSError as error:
        print(f"relay: upstream connect failed: {error}", flush=True)
        client_writer.close()
        return
    print("relay: connection opened", flush=True)
    pair = {client_writer, server_writer}
    writers.update(pair)
    await asyncio.gather(pump(client_reader, server_writer), pump(server_reader, client_writer))
    writers.difference_update(pair)
    print("relay: connection closed", flush=True)


def drop_all() -> None:
    print(f"relay: dropping {len(writers)} sockets", flush=True)
    for writer in list(writers):
        writer.transport.abort()


async def main() -> None:
    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, drop_all)
    server = await asyncio.start_server(handle, "127.0.0.1", LISTEN_PORT)
    print(f"relay: listening on 127.0.0.1:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
