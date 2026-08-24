#!/usr/bin/env python3
import asyncio
import os


SOCKET_PATH = os.environ["OMASHIKI_HOST_SOCKET"]
LISTEN_PORT = int(os.environ.get("OMASHIKI_HOST_RELAY_PORT", "8080"))


async def copy(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def relay(client_reader, client_writer):
    try:
        host_reader, host_writer = await asyncio.open_unix_connection(SOCKET_PATH)
    except OSError:
        client_writer.close()
        return

    await asyncio.gather(
        copy(client_reader, host_writer),
        copy(host_reader, client_writer),
        return_exceptions=True,
    )


async def main():
    server = await asyncio.start_server(relay, "127.0.0.1", LISTEN_PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
