#!/bin/bash
# jobnet-hook.sh -- OCI createRuntime hook for podman-run.sh --job-nodes. Not run by hand.
#
#   jobnet-hook.sh STATE_DIR IFNAME [PEER_ADDR...]      (the container's state as JSON on stdin)
#
# podman has by now created the container's network namespace and started pasta on it, with the
# node's own routes copied in; the container's command has not started. This hook replaces those
# routes with one host route per node of the job, so nothing else is reachable. It runs on the
# node, outside the container, as root of podman's user namespace, which owns that network
# namespace. The container's command runs without CAP_NET_ADMIN and cannot change the routes
# back. A failure here makes podman give up before the command starts.
#
# It then removes STATE_DIR/net.starting, which tells podman-run.sh that pasta holds its ports.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
dir="${1:-}" ifn="${2:-}"
[[ -d "$dir" && -n "$ifn" ]] || exit 1
shift 2
exec >> "$dir/hook.log" 2>&1
die() { echo "jobnet-hook.sh: $*"; exit 1; }

pid="$(python3 -I -c 'import json, sys; print(int(json.load(sys.stdin)["pid"]))')" || die "no pid in the container state"
target="$(readlink "/proc/$pid/ns/net")" || die "cannot read the network namespace of pid $pid"
# Never the node's own routing table. (As a normal user the flush below would be refused there
# anyway; this is for the day someone runs the wrapper as root.)
[[ "$target" != "$(readlink /proc/self/ns/net)" ]] || die "pid $pid is in the node's own network namespace"
ns() { nsenter -t "$pid" -n "$@"; }

ns ip -4 route flush dev "$ifn" || die "cannot flush the routes of $ifn"
ns ip -6 route flush dev "$ifn" 2>/dev/null
n=0
for a in "$@"; do
  [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not an address: $a"
  ns ip -4 route add "$a/32" dev "$ifn" || die "cannot add the route to $a"
  n=$((n + 1))
done
# Exactly the job's nodes, nothing else: no default route, no network route.
routes="$(ns ip -4 route show)" || die "cannot read the routes back"
[[ "$(grep -c . <<< "$routes" || true)" -eq "$n" ]] || die "unexpected routes: $routes"
! grep -qE '^default|/' <<< "$routes" || die "unexpected routes: $routes"
rm -f "$dir/net.starting"
exit 0
