#!/usr/bin/env python3
"""Tiny TCP-to-Unix-socket relay. Runs INSIDE the bwrap sandbox.

Since --unshare-net leaves loopback up, this listens on 127.0.0.1:<port>
and forwards every byte to a Unix domain socket that was bind-mounted into
the sandbox (the other end of that socket is allowlist_proxy.py, running
outside the sandbox with real network access). This lets any ordinary HTTP
client use plain http_proxy/https_proxy env vars pointed at 127.0.0.1,
instead of needing unix-socket-proxy support (inconsistent across tools).

Usage:
    python3 relay.py 127.0.0.1 8080 /run/proxy.sock
"""
import asyncio
import sys


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def handle(reader, writer, sock_path):
    try:
        remote_reader, remote_writer = await asyncio.open_unix_connection(sock_path)
    except OSError as e:
        print(f"[relay] failed to connect to {sock_path}: {e}", file=sys.stderr)
        writer.close()
        return
    await asyncio.gather(
        pipe(reader, remote_writer),
        pipe(remote_reader, writer),
    )


async def main():
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <listen-host> <listen-port> <unix-socket-path>", file=sys.stderr)
        sys.exit(1)
    host, port, sock_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    server = await asyncio.start_server(lambda r, w: handle(r, w, sock_path), host, port)
    print(f"[relay] listening on {host}:{port} -> {sock_path}", file=sys.stderr)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
