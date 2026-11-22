#!/usr/bin/env python3
"""Minimal HTTP/HTTPS forward proxy with a hostname allowlist.

Runs OUTSIDE the bwrap sandbox, with real network access, listening on a
Unix domain socket (not a TCP port) so it can be bind-mounted into exactly
one sandbox at a time. This is the host-side half of the bwrap
network-allowlist pattern -- see "Network, default-deny" in the README.

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

A name on the list is not trusted to point anywhere: it is resolved once, here,
and refused when it resolves to a loopback, link-local, multicast, unspecified
or reserved address (a service on this node, the 169.254 metadata range). The
connection then goes to the address that was checked. Private addresses are
allowed, because the cluster's own services live there. An address given
literally on the allowlist, and the name localhost, are taken as meant.

Usage:
    python3 allowlist_proxy.py /run/agent-proxy.sock litellm.int.janelia.org example.com
"""
import asyncio
import ipaddress
import re
import socket
import sys
import time
from typing import Optional, Tuple


# Header section limits: a client that never sends the blank line, or sends headers forever,
# must not hold a connection and its buffers open indefinitely.
MAX_HEADER_BYTES = 64 * 1024
MAX_HEADER_LINES = 200
HEADER_TIMEOUT = 30.0
CONNECT_TIMEOUT = 30.0
# The sandboxed process chooses what gets logged and how often. Keep each value short and the
# log bounded, so that it cannot be used to fill the node's scratch disk.
MAX_LOGGED_VALUE = 200
MAX_LOG_LINE = 600
MAX_LOG_LINES = 20000
# Denials have a budget of their own: the wrappers show them to the user at exit, and a flood of
# allowed requests must not be able to use up the lines before a denial is recorded.
_log_lines = {"DENY": 0, "other": 0}


def log(msg: str):
    kind = "DENY" if msg.startswith("DENY ") else "other"
    _log_lines[kind] += 1
    if _log_lines[kind] > MAX_LOG_LINES:
        if _log_lines[kind] == MAX_LOG_LINES + 1:
            print(f"[allowlist_proxy] log limit of {MAX_LOG_LINES} lines reached ({kind}); further ones are not logged",
                  file=sys.stderr, flush=True)
        return
    # The time first: the wrappers copy these lines into the per-job record.
    print(f"[allowlist_proxy] {time.strftime('%Y-%m-%dT%H:%M:%S')} {msg[:MAX_LOG_LINE]}", file=sys.stderr)


def short(value) -> str:
    """A client-chosen value, safe and short enough to log."""
    text = repr(value)
    return text if len(text) <= MAX_LOGGED_VALUE else text[:MAX_LOGGED_VALUE] + "...(truncated)"


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


def is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def address_refused(address: str) -> bool:
    """True for an address no allowed NAME may resolve to."""
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    return ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved


def name_taken_as_meant(host: str) -> bool:
    """An address literal or localhost: the user allowed exactly that, so no address check."""
    host = normalize_host(host)
    return is_ip_literal(host) or host == "localhost" or host.endswith(".localhost")


async def open_checked(host: str, port: int):
    """Resolve once, refuse addresses an allowed name must not point at, connect to a checked one.

    Returns (reader, writer). Raises PermissionError when every address is refused and OSError
    when none can be reached.
    """
    loop = asyncio.get_running_loop()
    host = host.rstrip(".")
    if name_taken_as_meant(host):
        try:
            return await asyncio.wait_for(asyncio.open_connection(host, port), CONNECT_TIMEOUT)
        except PermissionError as e:   # refused by the local system, not by the address check
            raise OSError(str(e)) from None
    # A name with a dot is looked up as written (trailing dot), so the resolver cannot append
    # the node's search domains to a name that does not exist.
    lookup = host + "." if "." in host else host
    try:
        infos = await loop.getaddrinfo(lookup, port, type=socket.SOCK_STREAM)
    except UnicodeError as e:          # an empty or over-long label: not a name that can resolve
        raise OSError(f"not a resolvable name: {e}") from None
    usable = [(fam, sa[0]) for fam, _, _, _, sa in infos if not address_refused(sa[0])]
    if not usable:
        raise PermissionError(", ".join(sorted({sa[0] for *_, sa in infos})) or "no address")
    last = None
    for fam, addr in usable:
        try:
            return await asyncio.wait_for(asyncio.open_connection(addr, port, family=fam), CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError) as e:
            last = e
    raise OSError(str(last))


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
            log(f"BAD headers from peer={peer}: {e}")
            await _reject(writer, b"400 Bad Request")
            return

        if method == "CONNECT":
            hp = split_hostport(target, 443)
            if hp is None:
                log(f"BAD CONNECT target {short(target)} (peer={peer})")
                await _reject(writer, b"400 Bad Request")
                return
            host, port = hp
            if not host_allowed(host, allowlist):
                log(f"DENY CONNECT {host[:MAX_LOGGED_VALUE]}:{port} (peer={peer})")
                await _reject(writer, b"403 Forbidden")
                return
            log(f"ALLOW CONNECT {host}:{port} (peer={peer})")
            try:
                remote_reader, remote_writer = await open_checked(host, port)
            except PermissionError as e:
                log(f"DENY CONNECT {host[:MAX_LOGGED_VALUE]}:{port} resolves to {str(e)[:MAX_LOGGED_VALUE]} (peer={peer})")
                await _reject(writer, b"403 Forbidden")
                return
            except (OSError, asyncio.TimeoutError):
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
                log(f"BAD HTTP Host header {short(hostport)} (peer={peer})")
                await _reject(writer, b"400 Bad Request")
                return
            host, port = hp
            if not host_allowed(host, allowlist):
                log(f"DENY HTTP {host[:MAX_LOGGED_VALUE]}:{port} (peer={peer})")
                await _reject(writer, b"403 Forbidden")
                return
            log(f"ALLOW HTTP {host}:{port} (peer={peer})")
            try:
                remote_reader, remote_writer = await open_checked(host, port)
            except PermissionError as e:
                log(f"DENY HTTP {host[:MAX_LOGGED_VALUE]}:{port} resolves to {str(e)[:MAX_LOGGED_VALUE]} (peer={peer})")
                await _reject(writer, b"403 Forbidden")
                return
            except (OSError, asyncio.TimeoutError):
                await _reject(writer, b"502 Bad Gateway")
                return
            remote_writer.write(headers)
            await remote_writer.drain()
            await asyncio.gather(
                pipe(reader, remote_writer),
                pipe(remote_reader, writer),
            )
    except Exception as e:
        log(f"error: {short(str(e))}")
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
