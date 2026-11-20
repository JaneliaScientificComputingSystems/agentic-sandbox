#!/usr/bin/env python3
"""Runs inside one sandbox of tests/test-multinode.sh, once per node.

usage: multinode-probe.py OUTDIR MY_ADDR ADDR[,ADDR...] OUTSIDER_ADDR

Listens on a port the system picks, publishes it in OUTDIR, connects to every other node's
listener, accepts their connections, and then tries what must fail: a host outside the job,
the internet, a DNS lookup, a route change. Prints one MARKER line per check.
"""
import os
import socket
import subprocess
import sys
import time

out, me, addrs, outsider = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4]
host = socket.gethostname().split(".")[0]


def say(marker, *detail):
    print(f"{marker} [{host}]", *detail, flush=True)


srv = socket.socket()
srv.bind((me, 0))
srv.listen(16)
port = srv.getsockname()[1]
with open(f"{out}/port.{me}", "w") as f:
    f.write(str(port))
say("LISTEN", me, port)
say("OWNER_OK" if os.stat(f"{out}/port.{me}").st_uid == os.getuid() else "OWNER_BAD")

others = [a for a in addrs if a != me]
for a in others:
    path = f"{out}/port.{a}"
    for _ in range(240):
        if os.path.exists(path) and open(path).read().strip():
            break
        time.sleep(0.5)
    try:
        c = socket.create_connection((a, int(open(path).read())), timeout=15)
        c.sendall(f"hello from {host}".encode())
        c.close()
        say("PEER_OUT_OK", a)
    except Exception as e:  # noqa: BLE001 - every failure is a result here
        say("PEER_OUT_BAD", a, e)

srv.settimeout(60)
for _ in others:
    try:
        c, peer = srv.accept()
        c.recv(100)
        c.close()
        say("PEER_IN_OK" if peer[0] in others else "PEER_IN_BAD", peer[0])
    except Exception as e:  # noqa: BLE001
        say("PEER_IN_BAD", e)

for target, tport in ((outsider, 22), ("1.1.1.1", 443)):
    try:
        socket.create_connection((target, tport), timeout=5).close()
        say("OUTSIDER_BAD", target, "connects")
    except OSError as e:
        say("OUTSIDER_BLOCKED", target, e.strerror or e)

try:
    socket.getaddrinfo("example.org", 80)
    say("DNS_BAD", "a lookup worked")
except OSError:
    say("DNS_BLOCKED")

try:
    say("HOSTS_OK" if socket.gethostbyaddr(others[0])[0] else "HOSTS_BAD")
except Exception as e:  # noqa: BLE001
    say("HOSTS_BAD", e)

try:
    r = subprocess.run(["/usr/sbin/ip", "route", "add", "1.1.1.1/32", "dev", "lo"], capture_output=True)
    say("ROUTE_REFUSED" if r.returncode != 0 else "ROUTE_BAD")
except FileNotFoundError:
    # An image without iproute2. The kernel checks the permission before it looks at the request,
    # so an empty "add route" request tells the same: EPERM without the right, EINVAL with it.
    import errno
    import fcntl

    try:
        fcntl.ioctl(socket.socket(socket.AF_INET, socket.SOCK_DGRAM), 0x890B, bytes(120))  # SIOCADDRT
        say("ROUTE_BAD", "accepted")
    except OSError as e:
        say("ROUTE_REFUSED" if e.errno == errno.EPERM else "ROUTE_BAD", e.strerror)
