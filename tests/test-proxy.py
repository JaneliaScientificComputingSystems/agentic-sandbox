#!/usr/bin/env python3
"""Regression tests for scripts/allowlist_proxy.py.

Unlike test-bwrap.sh / test-podman.sh these need no cluster, no bwrap and no
network: a throwaway HTTP "upstream" is started on 127.0.0.1, the proxy is
started on a Unix socket in a temp dir, and requests are sent to the proxy
directly (the same bytes relay.py would hand it from inside a sandbox).

    python3 tests/test-proxy.py
"""
import asyncio
import importlib.util
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY = os.path.join(HERE, "..", "scripts", "allowlist_proxy.py")

spec = importlib.util.spec_from_file_location("allowlist_proxy", PROXY)
proxy_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy_mod)

PASS = 0
FAIL = 0


def check(label, actual, expected):
    global PASS, FAIL
    if actual == expected:
        print(f"PASS: {label} (got: {actual!r})")
        PASS += 1
    else:
        print(f"FAIL: {label} (expected: {expected!r}, got: {actual!r})")
        FAIL += 1


# --- pure-function checks -----------------------------------------------------------

check("allowlist lower-cased", proxy_mod.normalize_allowlist(["LiteLLM.INT.Janelia.org"]), ["litellm.int.janelia.org"])
check("allowlist leading dot stripped", proxy_mod.normalize_allowlist([".github.com"]), ["github.com"])
check("allowlist blank entries dropped", proxy_mod.normalize_allowlist(["", "  ", "a.b"]), ["a.b"])

AL = proxy_mod.normalize_allowlist(["github.com", ".Example.ORG"])
check("exact host allowed", proxy_mod.host_allowed("github.com", AL), True)
check("subdomain allowed", proxy_mod.host_allowed("api.github.com", AL), True)
check("mixed-case request host allowed", proxy_mod.host_allowed("API.GitHub.COM", AL), True)
check("trailing-dot FQDN allowed", proxy_mod.host_allowed("github.com.", AL), True)
check("leading-dot entry matches apex", proxy_mod.host_allowed("example.org", AL), True)
check("leading-dot entry matches subdomain", proxy_mod.host_allowed("www.example.org", AL), True)
check("prefix lookalike denied", proxy_mod.host_allowed("evil-github.com", AL), False)
check("suffix lookalike denied", proxy_mod.host_allowed("github.com.evil.net", AL), False)
check("empty host denied", proxy_mod.host_allowed("", AL), False)

check("host only -> default port", proxy_mod.split_hostport("example.com", 443), ("example.com", 443))
check("host:port", proxy_mod.split_hostport("example.com:8443", 443), ("example.com", 8443))
check("[v6]:port", proxy_mod.split_hostport("[::1]:8080", 80), ("::1", 8080))
check("[v6] no port", proxy_mod.split_hostport("[::1]", 80), ("::1", 80))
check("bare v6 refused", proxy_mod.split_hostport("::1", 80), None)
check("non-numeric port refused", proxy_mod.split_hostport("example.com:http", 80), None)
check("out-of-range port refused", proxy_mod.split_hostport("example.com:70000", 80), None)
check("empty host refused", proxy_mod.split_hostport(":80", 80), None)


# --- end-to-end through a real proxy process ------------------------------------------

async def start_upstream():
    async def handle(reader, writer):
        try:
            await reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError:
            # A CONNECT tunnel that the client closes without sending anything.
            writer.close()
            return
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nupstream")
        await writer.drain()
        writer.close()
    return await asyncio.start_server(handle, "127.0.0.1", 0)


def start_proxy(sock, allowlist):
    proc = subprocess.Popen([sys.executable, PROXY, sock, *allowlist],
                            stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if os.path.exists(sock):
            return proc
        if proc.poll() is not None:
            raise RuntimeError(f"proxy exited early: {proc.communicate()[1]}")
        time.sleep(0.05)
    raise RuntimeError("proxy socket never appeared")


async def talk(sock, request: bytes) -> str:
    reader, writer = await asyncio.open_unix_connection(sock)
    writer.write(request)
    await writer.drain()
    try:
        data = await asyncio.wait_for(reader.read(4096), 3)
    except asyncio.TimeoutError:
        return "<timeout>"
    finally:
        writer.close()
    return data.decode("latin1", "replace").split("\r\n")[0]


async def e2e():
    upstream = await start_upstream()
    port = upstream.sockets[0].getsockname()[1]
    tmp = tempfile.mkdtemp(prefix="allowlist-proxy-test.")
    sock = os.path.join(tmp, "proxy.sock")

    def http(hostport):
        return f"GET http://{hostport}/ HTTP/1.1\r\nHost: {hostport}\r\n\r\n".encode()

    def connect(hostport):
        return f"CONNECT {hostport} HTTP/1.1\r\nHost: {hostport}\r\n\r\n".encode()

    # Allowlist given in mixed case with a leading dot: both must be normalized away.
    proc = start_proxy(sock, [".LocalHost", "127.0.0.1"])
    try:
        check("e2e plain HTTP to non-80 port reaches upstream",
              await talk(sock, http(f"localhost:{port}")), "HTTP/1.1 200 OK")
        check("e2e plain HTTP by IP literal reaches upstream",
              await talk(sock, http(f"127.0.0.1:{port}")), "HTTP/1.1 200 OK")
        check("e2e CONNECT to allowed host",
              await talk(sock, connect(f"localhost:{port}")), "HTTP/1.1 200 Connection Established")
        check("e2e CONNECT to lookalike denied",
              await talk(sock, connect(f"evil-localhost:{port}")), "HTTP/1.1 403 Forbidden")
        check("e2e plain HTTP to lookalike denied",
              await talk(sock, http(f"localhost.evil:{port}")), "HTTP/1.1 403 Forbidden")
        check("e2e plain HTTP without Host header rejected",
              await talk(sock, b"GET / HTTP/1.1\r\n\r\n"), "HTTP/1.1 400 Bad Request")
        check("e2e CONNECT with bad port rejected",
              await talk(sock, connect("localhost:99999")), "HTTP/1.1 400 Bad Request")
        check("e2e CONNECT to IPv6 literal not on allowlist denied",
              await talk(sock, connect(f"[::1]:{port}")), "HTTP/1.1 403 Forbidden")
    finally:
        proc.terminate()
        proc.wait()
        os.unlink(sock)
    upstream.close()
    await upstream.wait_closed()

    # Empty allowlist after normalization must refuse to start (fail closed).
    proc = subprocess.Popen([sys.executable, PROXY, sock, ".", " "], stderr=subprocess.PIPE, text=True)
    proc.wait(timeout=5)
    check("empty allowlist refuses to start", proc.returncode, 1)
    os.rmdir(tmp)


asyncio.run(e2e())
print(f"=== SUMMARY: {PASS} passed, {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
