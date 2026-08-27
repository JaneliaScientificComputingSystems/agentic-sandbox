#!/usr/bin/env python3
"""Minimal HTTP/HTTPS forward proxy with a hostname allowlist.

Runs OUTSIDE the bwrap sandbox, with real network access, listening on a
Unix domain socket (not a TCP port) so it can be bind-mounted into exactly
one sandbox at a time. This is the host-side half of the bwrap
network-allowlist pattern -- see the main README's "Network access" section.

Supports:
  - HTTPS via CONNECT (checks the CONNECT target host against the allowlist,
    then just shovels bytes -- it never decrypts TLS).
  - Plain HTTP via the Host header (checks that against the allowlist, then
    forwards the raw request bytes as-is).

Usage:
    python3 allowlist_proxy.py /run/agent-proxy.sock litellm.int.janelia.org example.com
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


def host_allowed(host: str, allowlist: list[str]) -> bool:
    host = host.lower()
    return any(host == a or host.endswith("." + a) for a in allowlist)


async def handle_client(reader, writer, allowlist):
    peer = writer.get_extra_info("peername")
    try:
        first_line = await reader.readline()
        if not first_line:
            writer.close()
            return

        parts = first_line.decode("latin1", "replace").strip().split()
        if len(parts) < 2:
            writer.close()
            return
        method, target = parts[0], parts[1]

        if method == "CONNECT":
            host = target.split(":")[0]
            headers = b""
            while True:
                line = await reader.readline()
                headers += line
                if line in (b"\r\n", b""):
                    break
            if not host_allowed(host, allowlist):
                print(f"[allowlist_proxy] DENY CONNECT {host} (peer={peer})", file=sys.stderr)
                writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                await writer.drain()
                writer.close()
                return
            print(f"[allowlist_proxy] ALLOW CONNECT {host} (peer={peer})", file=sys.stderr)
            hostname, _, portstr = target.partition(":")
            port = int(portstr) if portstr else 443
            try:
                remote_reader, remote_writer = await asyncio.open_connection(hostname, port)
            except OSError as e:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                await writer.drain()
                writer.close()
                return
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(
                pipe(reader, remote_writer),
                pipe(remote_reader, writer),
            )
        else:
            # Plain HTTP: read headers, find Host:, forward raw bytes.
            headers = first_line
            host = None
            while True:
                line = await reader.readline()
                headers += line
                if line.lower().startswith(b"host:"):
                    host = line.split(b":", 1)[1].strip().decode("latin1").split(":")[0]
                if line in (b"\r\n", b""):
                    break
            if not host or not host_allowed(host, allowlist):
                print(f"[allowlist_proxy] DENY HTTP {host} (peer={peer})", file=sys.stderr)
                writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                await writer.drain()
                writer.close()
                return
            print(f"[allowlist_proxy] ALLOW HTTP {host} (peer={peer})", file=sys.stderr)
            try:
                remote_reader, remote_writer = await asyncio.open_connection(host, 80)
            except OSError:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                await writer.drain()
                writer.close()
                return
            remote_writer.write(headers)
            await remote_writer.drain()
            await asyncio.gather(
                pipe(reader, remote_writer),
                pipe(remote_reader, writer),
            )
    except Exception as e:
        print(f"[allowlist_proxy] error: {e}", file=sys.stderr)
    finally:
        writer.close()


async def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <unix-socket-path> <allowed-host> [more-allowed-hosts...]", file=sys.stderr)
        sys.exit(1)
    sock_path = sys.argv[1]
    allowlist = sys.argv[2:]
    print(f"[allowlist_proxy] listening on {sock_path}, allowlist={allowlist}", file=sys.stderr)

    server = await asyncio.start_unix_server(
        lambda r, w: handle_client(r, w, allowlist), path=sock_path
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
