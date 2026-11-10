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
import re
import sys
from typing import Optional, Tuple


# Header section limits: a client that never sends the blank line, or sends headers forever,
# must not hold a connection and its buffers open indefinitely.
MAX_HEADER_BYTES = 64 * 1024
MAX_HEADER_LINES = 200
HEADER_TIMEOUT = 30.0


async def pipe(reader, writer):
    """Copy until EOF, then half-close the far side so it sees the EOF too.

    Closing outright on the first EOF would cut off a response still in
    flight the other way (an HTTP client that shuts down its send side after
    the request, for one). The caller closes both ends once both directions
    are done.
    """
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except (ConnectionResetError, BrokenPipeError, OSError):
        writer.close()


async def read_headers(reader) -> bytes:
    """The header lines after the request line, up to and including the blank line.

    Raises ValueError when the section is too long or too slow (the caller
    answers 400 and closes).
    """
    headers = b""
    lines = 0
    while True:
        line = await asyncio.wait_for(reader.readline(), HEADER_TIMEOUT)
        headers += line
        lines += 1
        if line in (b"\r\n", b"\n", b""):
            return headers
        if len(headers) > MAX_HEADER_BYTES or lines > MAX_HEADER_LINES:
            raise ValueError("header section too large")


# What a host may look like at all. The client (the sandboxed process) chooses this string, it is
# written to the log, and the wrappers print denied hosts from the log to the user's terminal --
# so anything outside this set (control characters, escape sequences) is refused before it is
# logged or resolved, and reported with repr().
HOSTNAME_RE = re.compile(r"[A-Za-z0-9._-]+")
IPV6_RE = re.compile(r"[0-9A-Fa-f:.]+")


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

    Returns None when the host is not a plain hostname / IP literal or the
    port is not a valid TCP port. The host is returned without brackets,
    ready for asyncio.open_connection().
    """
    hostport = hostport.strip()
    if hostport.startswith("["):
        host, sep, rest = hostport[1:].partition("]")
        if not sep:
            return None
        portstr = rest[1:] if rest.startswith(":") else ""
        if rest and not rest.startswith(":"):
            return None
        if not IPV6_RE.fullmatch(host):
            return None
    else:
        host, sep, portstr = hostport.rpartition(":")
        if not sep:
            host, portstr = hostport, ""
        elif ":" in host:
            # Bare IPv6 literal with no brackets: ambiguous, refuse.
            return None
        if not HOSTNAME_RE.fullmatch(host):
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
    remote_writer = None
    try:
        first_line = await asyncio.wait_for(reader.readline(), HEADER_TIMEOUT)
        if not first_line:
            writer.close()
            return

        parts = first_line.decode("latin1", "replace").strip().split()
        if len(parts) < 2:
            writer.close()
            return
        method, target = parts[0], parts[1]

        try:
            headers = await read_headers(reader)
        except (ValueError, asyncio.TimeoutError, asyncio.LimitOverrunError) as e:
            print(f"[allowlist_proxy] BAD headers from peer={peer}: {e}", file=sys.stderr)
            await _reject(writer, b"400 Bad Request")
            return

        if method == "CONNECT":
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
            # Plain HTTP: find Host: in the headers already read, forward raw bytes.
            hostport = None
            for line in headers.splitlines(keepends=True):
                if line.lower().startswith(b"host:"):
                    hostport = line.split(b":", 1)[1].strip().decode("latin1")
                    break
            headers = first_line + headers
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
        if remote_writer is not None:
            remote_writer.close()
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
