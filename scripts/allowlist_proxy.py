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

Allowlist entries are hostnames (case-insensitive; a leading dot is ignored,
so ".example.com" and "example.com" mean the same thing). An entry matches
itself and any subdomain: "example.com" allows "api.example.com" but not
"evil-example.com" or "example.com.evil.net". Any port is allowed on an
allowed host.

Usage:
    python3 allowlist_proxy.py /run/agent-proxy.sock litellm.int.janelia.org example.com
"""
import asyncio
import sys
from typing import Optional, Tuple


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


def normalize_host(host: str) -> str:
    """Lower-case, strip whitespace and a trailing dot (FQDN form)."""
    return host.strip().lower().rstrip(".")


def normalize_allowlist(entries: list) -> list:
    """Allowlist as given on the command line -> canonical form used by host_allowed()."""
    out = []
    for entry in entries:
        entry = normalize_host(entry).lstrip(".")
        if entry and entry not in out:
            out.append(entry)
    return out


def host_allowed(host: str, allowlist: list) -> bool:
    host = normalize_host(host)
    return bool(host) and any(host == a or host.endswith("." + a) for a in allowlist)


def split_hostport(hostport: str, default_port: int) -> Optional[Tuple[str, int]]:
    """Split "host", "host:port" or "[v6]:port" into (host, port).

    Returns None when the port is not a valid TCP port. The host is returned
    without brackets, ready for asyncio.open_connection().
    """
    hostport = hostport.strip()
    if hostport.startswith("["):
        host, sep, rest = hostport[1:].partition("]")
        if not sep:
            return None
        portstr = rest[1:] if rest.startswith(":") else ""
        if rest and not rest.startswith(":"):
            return None
    else:
        host, sep, portstr = hostport.rpartition(":")
        if not sep:
            host, portstr = hostport, ""
        elif ":" in host:
            # Bare IPv6 literal with no brackets: ambiguous, refuse.
            return None
    if not host:
        return None
    try:
        port = int(portstr) if portstr else default_port
    except ValueError:
        return None
    if not 0 < port < 65536:
        return None
    return host, port


async def _reject(writer, status: bytes):
    writer.write(b"HTTP/1.1 " + status + b"\r\nConnection: close\r\n\r\n")
    await writer.drain()
    writer.close()


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
            headers = b""
            while True:
                line = await reader.readline()
                headers += line
                if line in (b"\r\n", b""):
                    break
            hp = split_hostport(target, 443)
            if hp is None:
                print(f"[allowlist_proxy] BAD CONNECT target {target!r} (peer={peer})", file=sys.stderr)
                await _reject(writer, b"400 Bad Request")
                return
            host, port = hp
            if not host_allowed(host, allowlist):
                print(f"[allowlist_proxy] DENY CONNECT {host}:{port} (peer={peer})", file=sys.stderr)
                await _reject(writer, b"403 Forbidden")
                return
            print(f"[allowlist_proxy] ALLOW CONNECT {host}:{port} (peer={peer})", file=sys.stderr)
            try:
                remote_reader, remote_writer = await asyncio.open_connection(host, port)
            except OSError:
                await _reject(writer, b"502 Bad Gateway")
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
            hostport = None
            while True:
                line = await reader.readline()
                headers += line
                if line.lower().startswith(b"host:"):
                    hostport = line.split(b":", 1)[1].strip().decode("latin1")
                if line in (b"\r\n", b""):
                    break
            hp = split_hostport(hostport, 80) if hostport else None
            if hp is None:
                print(f"[allowlist_proxy] DENY HTTP bad/missing Host {hostport!r} (peer={peer})", file=sys.stderr)
                await _reject(writer, b"400 Bad Request")
                return
            host, port = hp
            if not host_allowed(host, allowlist):
                print(f"[allowlist_proxy] DENY HTTP {host}:{port} (peer={peer})", file=sys.stderr)
                await _reject(writer, b"403 Forbidden")
                return
            print(f"[allowlist_proxy] ALLOW HTTP {host}:{port} (peer={peer})", file=sys.stderr)
            try:
                remote_reader, remote_writer = await asyncio.open_connection(host, port)
            except OSError:
                await _reject(writer, b"502 Bad Gateway")
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
    allowlist = normalize_allowlist(sys.argv[2:])
    if not allowlist:
        print("[allowlist_proxy] refusing to start: allowlist is empty after normalization", file=sys.stderr)
        sys.exit(1)
    print(f"[allowlist_proxy] listening on {sock_path}, allowlist={allowlist}", file=sys.stderr)

    server = await asyncio.start_unix_server(
        lambda r, w: handle_client(r, w, allowlist), path=sock_path
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
