# Files to copy during setup

| File | Copy to | For |
|---|---|---|
| `storage.conf` | `~/.config/containers/storage.conf` | podman: images and containers on node-local `/scratch`, not in your home directory |
| `containers.conf` | `~/.config/containers/containers.conf` | podman: its own logging off, so nothing a container prints reaches the system logs |

Both are the same for every account and are needed only for `podman-run.sh`. `SETUP.md` §3 says
what they do and what they cost.

The csub policy, `~/.config/csub/broker.toml`, is not a file here, because it holds your project
directory and csub's current queue table. `scripts/csub-policy.sh` writes it (`SETUP.md` §6).
