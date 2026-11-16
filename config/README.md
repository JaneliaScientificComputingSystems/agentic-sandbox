# Files that setup copies

| File | Goes to | For |
|---|---|---|
| `storage.conf` | `~/.config/containers/storage.conf` on the cluster | podman: images and containers on node-local `/scratch`, not in your home directory |
| `containers.conf` | `~/.config/containers/containers.conf` on the cluster | podman: its own logging off, so nothing a container prints reaches the system logs |
| `CLAUDE.md` | the agent's working directory on your laptop | Claude Code on a laptop, working through `ssh-entry.sh` |
| `AGENTS.md` | the agent's working directory on your laptop | Codex on a laptop, working through `ssh-entry.sh` |
| `AGENTS-podman.md` | the same, saved as `AGENTS.md` | Codex on a laptop, with `ssh-entry.sh --podman` |

The two podman files are the same for every account and are needed only for `podman-run.sh`;
`SETUP.md` §3 says what they do and what they cost.

The three instruction files are the rules for an agent that runs on a laptop and does its work on the
cluster (`SETUP.md` §8). `CLAUDE.md` and `AGENTS.md` have the same text. `AGENTS-podman.md` differs in
one rule: it names the container image for GPU work where the others say to build a venv. They
assume the ssh alias is called `janelia-agent`; change the name in the file if yours differs.

The csub policy, `~/.config/csub/broker.toml`, is not a file here, because it holds your project
directory and csub's current queue table. `scripts/csub-policy.sh` writes it (`SETUP.md` §6).
