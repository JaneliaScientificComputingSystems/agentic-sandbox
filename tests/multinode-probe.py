#!/usr/bin/env python3
"""Runs inside one sandbox of tests/test-multinode.sh, once per node.

usage: multinode-probe.py OUTDIR MY_ADDR ADDR[,ADDR...] HIDDEN_PATH

Listens on a port the system picks, publishes it in OUTDIR, connects to every other node's
listener, accepts their connections, and checks the node's own name, that HIDDEN_PATH (a file
in the caller's home directory) is not visible, and that MN_CANARY (set in the environment the
wrapper was started from) did not come in. Prints one MARKER line per check.
"""
import os
import socket
import sys
import time

out, me, addrs, hidden = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4]
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

# The node's own name must resolve to the node's address: torchrun hands that name to the other
# nodes as the master's.
try:
    name = socket.getfqdn()
    say("NAME_OK" if "containers.internal" not in name and socket.gethostbyname(name) == me else "NAME_BAD", name)
except OSError as e:
    say("NAME_BAD", e)

say("HOME_HIDDEN" if not os.path.lexists(hidden) else "HOME_VISIBLE", hidden)
say("ENV_HIDDEN" if "MN_CANARY" not in os.environ else "ENV_VISIBLE")
