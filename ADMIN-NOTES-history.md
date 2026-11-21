# Engineering notes — history

This file holds passages moved out of `ADMIN-NOTES.md` word for word, each under the heading it has
there. Nothing in it describes the current scripts: every passage records a state the code has left, or
a test of that state. `ADMIN-NOTES.md` is the current record. Where a passage refers to another section,
that section is in `ADMIN-NOTES.md` unless it is in this file.

## The $HOME-to-$PWD default change, and why

> **Superseded in part.** Two things below no longer hold. Starting `sandbox-run.sh` from `$HOME`, or
> from a directory above it, is now refused, so the `$PWD == $HOME` case described here cannot
> occur. And a `$HOME` that is not bound gets no masks, so no empty `.ssh` or `.config/gcloud`
> placeholders appear in it. See "Review follow-ups: masks, bind order, podman refusals, `/dev/shm`
> (2026-11-09/10)" and README's troubleshooting.

`sandbox-run.sh` used to always read-only-bind all of `$HOME`, with a denylist of known credential
paths masked on top (see the masking block in `sandbox-run.sh`). The session that found podman's
masking does not work (see "The credential-masking attempt that didn't work" below) showed why that
is a standing liability even where masking *does* work (bwrap): a denylist protects the paths we
thought to list, not whatever shows up next (a new cloud CLI's config file, `.gnupg`, a password
manager's store). Anthropic's own secure-deployment guide never mounts the real home directory at
all, rather than mounting it and masking around it.

**Changed default**: `sandbox-run.sh` binds `$PWD` (read-write) instead of `$HOME` (read-only), and
`$HOME` is not bound unless the caller explicitly `--rw`/`--ro`s it. `--claude`/`--opencode`/
`--scratch` were already narrow, explicit opt-ins and are unaffected.

**The masking logic was kept and applies to both `$PWD` and `$HOME`**, deliberately redundant with
the new default, because a caller's `$PWD` could *be* `$HOME` (a login shell without a `cd`), and
the new default then bound all of it, with the old exposure. **It was also made unconditional**: it
runs after all `--ro`/`--rw` processing instead of before. The old documented behavior ("an explicit
`--ro`/`--rw` on one of these paths still overrides the mask") was dropped, since that is the
re-exposure this change closes off.

**Verified live** (real LSF job, ordinary user, not root):
- `$PWD` bound read-write by default: a file written inside landed on the real filesystem.
- From a `$PWD` other than `$HOME`, `$HOME` inside holds no real files. Only empty placeholder
  directories may appear (`.ssh`, `.config/gcloud`), because the mask loop needs a directory to hang
  the `--tmpfs` off. Both are dot-prefixed and invisible to a plain `ls`.
- Masking applies to `$PWD` too: `.git-credentials` and `.aws/credentials` created in a scratch
  project directory came back empty/zero-byte inside, with the real files on disk untouched.
- Masking is unconditional: `--rw "$WORKDIR/.git-credentials"` still returns 0 bytes.
- `$PWD == $HOME` (no `cd`, the login shell's default): the real home content was visible, as
  bound, and `.ssh`/`.config/gcloud` inside it were still masked (empty).
- `--claude`/`--opencode` still mount their specific narrow paths.

## Authenticating Claude Code — the rigorous login test

> **Superseded in part.** This test was done when `~/.claude` was bound read-write. Today `--claude`
> works on a per-job copy and binds only `~/.claude/.credentials.json`, and only if that file exists
> at start, so a first login done inside the sandbox persists only in that case (README, Harnesses).

A fresh `claude auth login` done entirely inside the sandbox was tested end to end:
1. Logged out **outside** the sandbox (`claude auth logout`), confirmed `loggedIn: false`.
2. **Inside** the sandbox, before any login attempt, the same logged-out state was visible, which
   proves the RW-bound `.claude` is the real file and not a stale view.
3. `claude auth login` ran **entirely inside** the sandbox, with no reused credentials, and printed
   an OAuth URL. The redirect URI is `https://platform.claude.com/oauth/code/callback`, **not a
   localhost callback**, so the "OAuth breaks under network-namespace isolation" concern (real for
   *some* other flows, e.g. MCP server OAuth, per public reports) does not apply to
   `claude auth login`. It goes straight to a manual "paste code here" prompt.
4. A human opened that URL in a browser outside the sandbox (the browser is not part of the
   sandboxed process and does not need the proxy) and pasted the resulting code into the sandboxed
   terminal's stdin.
5. Login succeeded. Verified from outside the sandbox afterward: `loggedIn: true`.

The proxy's log during this real login showed exactly `api.anthropic.com` (repeatedly) and
`platform.claude.com`. `claude.ai` was never contacted through the proxy, since the browser step
happens on the host's real network. One attempt was denied as expected:
`http-intake.logs.us5.datadoghq.com` (Datadog telemetry).

## GPU / device access — evidence

> **Superseded in part (2026-11-03, merged 2026-11-14).** The conclusion below, that bwrap cannot
> pass a GPU through, was wrong about the cause. The missing piece was sysfs: with the device nodes
> bound **and** `/sys/devices` and `/sys/module` visible read-only, `nvidia-smi`, CUDA and PyTorch
> work under bwrap. See "bwrap `--gpu`" further down. What follows is kept as the record of what
> was tried at the time; podman remains the way to run a container image.

**Tested live on a real GPU allocation (`gpu_l4` LSF queue).** Ruled out with direct tests:
- Device node visibility. `--dev-bind /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
  /dev/nvidia-uvm-tools /dev/nvidia-modeset` all showed up correctly inside the sandbox.
- Missing libraries/sockets. Everything `nvidia-container-cli list` (the NVIDIA Container Toolkit's
  own authoritative list) says is required was bound. Identical failure.
- `/proc` handling. A fresh private `/proc` and a real bind of the host's failed identically.
- User namespace alone, the key isolating result. Plain `unshare --user --map-root-user --
  nvidia-smi -L` (a new user namespace, no mount/root reconstruction) lists the GPU normally.

The failure tracked with bwrap building its own sandboxed root and mount namespace, which every
bwrap sandbox does by design. The conclusion drawn then was the well-known industry pattern: GPU
access inside a namespace-isolated process on modern data-center NVIDIA drivers generally requires
the NVIDIA Container Toolkit's runtime integration.

**What supported that conclusion at the time:** Anthropic's own `sandbox-runtime` has no GPU/CUDA
support at all, and its open, unresolved feature request
[anthropics/claude-code#13108](https://github.com/anthropics/claude-code/issues/13108) shows GPU
access failing in sandbox mode in every report, with no working example from anyone, official or
community. A near-identical open OpenAI Codex issue,
[openai/codex#19676](https://github.com/openai/codex/issues/19676), reports a simpler symptom
(missing device nodes entirely) and is also unresolved. NVIDIA's own CDI documentation scopes
support explicitly to *container runtimes* (podman, containerd, cri-o, the NVIDIA Container
Runtime), and bwrap implements raw namespaces directly rather than an OCI-hook-capable runtime.

## Identity and $HOME under podman

> **Superseded in part.** For `--claude` the mount destination described here and in the next section
> no longer applies: `podman-run.sh` mounts the per-job copy at its own path and Claude Code finds it
> through `CLAUDE_CONFIG_DIR`, so its location does not depend on `--keep-id`. For `--opencode` it
> still holds: `/root/...` by default, `$HOME/...` with `--keep-id`.

Unlike bwrap (where you're still "you" inside the sandbox), a podman container runs as **root** by
default, with `$HOME=/root`. So `claude`/`opencode` looked for their config at
`/root/.claude`/`/root/.config/opencode`, not the host's real path, even with the real files
bind-mounted.

- **First attempt**: `--userns=keep-id` (podman's built-in mapping of the container back to your
  real host UID). Failed: `chowning container workdir: potentially insufficient UIDs or GIDs
  available in user namespace`. The account had no `/etc/subuid`/`/etc/subgid` range yet (confirmed
  on a live node that these ranges exist and work here, granted per account by HPC on request, not
  cluster-wide or self-service). The next section shows that this was not the real cause.
- **Second attempt**: `--user $(id -u):$(id -g)` plus `-e HOME=$HOME` (no namespace remapping).
  Failed with exit 126 (permission denied): the CLIs were installed as root during the image build,
  and files created that way aren't readable/executable by a different numeric UID.
- **The fix that actually worked**: mount the host's real config files to `/root/...`, where the
  container's actual user (root) already looks, instead of to `$HOME/...`. Podman volume source and
  destination paths don't have to match, unlike bwrap's convention of identical paths in this repo.

## --userns=keep-id, revisited — full evidence and the actual root cause

The section above concluded `--userns=keep-id` failed for lack of a subuid/subgid range. Revisited
with a range confirmed provisioned (width 65536), it **still fails**, same error class, now with the
invoking account's exact real uid:gid in the message:
```
Error: chowning container ... workdir to container root: potentially insufficient UIDs or
GIDs available in user namespace (requested <uid>:<gid> for ...): Check /etc/subuid and
/etc/subgid if configured locally and run "podman system migrate"
```

**Isolated which value is the problem**, using `--userns=keep-id:uid=X,gid=Y` to test uid and gid
independently:

| Test | uid | gid | Result |
|---|---|---|---|
| A | 1000 (small) | `<gid>` (real) | **fails** |
| B | `<uid>` (real) | 1000 (small) | **works** |
| C | 65535 (range edge) | 1000 (small) | **works** |

The account's real **gid** is the entire cause. The real **uid** works right up to the range edge.

**Exact boundary**, sweeping gid values with a fixed small uid: 65534/65535/**65536** all work,
**65537**/90000/`<gid>` all fail. The threshold is the width of the granted subgid range (65536):
`keep-id`'s identity mapping needs the target gid `≤` the range width, wherever the range is
positioned. AD/LDAP here assigns primary GIDs well above the traditional 16-bit container UID/GID
space (0-65535), and the account's real gid exceeds the granted range's width.

**Resolved**: HPC widened all granted ranges to 131072 ("128k"), confirmed deployed live. Retested:
`--userns=keep-id --user "$(id -u):$(id -g)"` succeeds with the real uid/gid and no chown error.

**One more issue surfaced once identity worked**: `claude`/`opencode` failed with `Permission
denied` (confirmed via each CLI's full path, so not "not found"). Both are installed under `/root`
by their native installers (`/root/.local/bin/claude`, `/root/.opencode/bin/opencode`, symlinked
from `/usr/local/bin/`), and `/root` is `0700` by default, which blocks traversal for a non-root
process whatever the target files' own permissions. This is a different failure mode from the
"second attempt" above (`exit 126`, individual file permission denial) with the same root idea.
Fixed in `podman/Dockerfile`: `chmod o+rx /root && chmod -R o+rX /root/.local /root/.opencode`,
deliberately targeted (traversal on `/root` itself, read+execute on just the two install trees),
not a blanket loosening.

**Verified live end-to-end against the actual published GHCR image** (rebuilt and re-pushed, not
just tested locally): `whoami` → the real account name, `$HOME` → the real home directory,
`claude --version` → `2.1.267`, `opencode --version` → `1.18.30`.

**Important correction**, found via the with/without-`--keep-id` matrix of the checked-in test suite
(`tests/test-podman.sh`): a file written to a `--rw`-mounted host directory lands with real
ownership **even without `--keep-id`**. Rootless podman's default mapping already writes
bind-mounted files as the real invoking user. What stays root-owned regardless of `--keep-id` is the
*container's own internal storage*: a `/tmp` file (not bind-mounted) showed `root root` in both
cases.

So `--keep-id`'s value is narrower than originally framed (a framing borrowed from
`janelia-mojo-sandbox`'s comment, which conflated the two). It changes the **process identity inside
the container** (`whoami`, `$HOME` resolution), which is what `--claude`/`--opencode` need to mount
at your real `$HOME/...` instead of `/root/...`. It does not fix bind-mounted file ownership, which
was never broken. `podman-run.sh --keep-id` still closes the "podman runs as root" gap from the
Anthropic Docker-config comparison, via in-container identity, not volume ownership.

## The GHCR images

**`podman/Dockerfile.pytorch`** (the original default): `nvcr.io/nvidia/pytorch:26.07-py3` (CUDA
13.3.1, PyTorch 2.13, confirmed current as of the build date via NVIDIA's own release notes) plus
Node.js, `@anthropic-ai/claude-code`, and opencode. Verified live in one build+run job:
`nvidia-smi -L` returned a real GPU UUID, `claude --version` → `2.1.197 (Claude Code)`,
`opencode --version` → `1.18.23`. Pushed straight from that verified build, not a separately built
artifact, to `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest` (`podman push`
reported `Writing manifest to image destination`, and the GitHub API showed the package after the
push). Made public alongside the repo so `podman pull` needs no `podman login` first.

**`podman/Dockerfile`** (now the default, renamed from `Dockerfile.lite`; the above became
`Dockerfile.pytorch`): bare `nvcr.io/nvidia/cuda:13.3.0-base-ubuntu22.04` (same CUDA version as the
PyTorch image's toolkit) plus Node.js, Claude Code, and opencode, no ML framework stack. Built and
verified live via a real LSF GPU job as an ordinary user (not root):
`nvidia-smi --query-gpu=name,driver_version` → `NVIDIA L4, 610.43.02`, `claude --version` →
`2.1.267 (Claude Code)`, `opencode --version` → `1.18.30`. Final image size **1.24GB**, vs. the
PyTorch image's multi-GB footprint (`podman images` showed both side by side on the same node).
Tagged and pushed from that same build to
`ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest`, confirmed via the GitHub
API, and `podman-run.sh`'s default `--image` now points here instead of `agentic-sandbox-gpu`. Made
public via the GHCR web UI: no REST API endpoint exists for changing a container package's
visibility (`PATCH /orgs/.../packages/container/...` 404s even though `GET` on the identical path
succeeds).

**Rebuilt 2026-10-08** (`agentic-sandbox-gpu:latest`, digest `sha256:3a88ffe0…`): added the same
`chmod o+rx /root && chmod -R o+rX /root/.local /root/.opencode` the lite image has had since
2026-09-10, so `--keep-id` can run both CLIs on this image too (previously `Permission denied`:
`/root` is 0700 and the `/usr/local/bin` symlinks point into it). Built with `--no-cache` so the
installers fetched current CLIs: `claude --version` → `2.1.294`, `opencode --version` → `1.18.35`.
Verified live on `gpu_l4` under `--keep-id` against the published tag: both CLIs run as the real
uid, `torch.cuda.is_available()` → `True`.

## README restructured; verification record (2026-10-16)

`README.md` was rewritten as a use document (339 lines, from 905): quick start, a flag chooser,
one "how it works" section, `--csub`, an image table, a consolidated security model with explicit
non-protections, testing, troubleshooting. One-time setup moved to `SETUP.md`, behaviour changes
to `CHANGELOG.md`. The dated "confirmed live" statements it used to carry are recorded here so
nothing is lost:

- `$HOME` stopped being bound by default on 2026-09-10 (previously always, read-only).
- `--keep-id` verified end to end on 2026-09-10 once HPC widened the account's subuid/subgid range
  to 131072; a standard 65536-wide range fails with "potentially insufficient UIDs or GIDs".
- podman creates `/scratch/$USER/podman-run` and `podman-storage` itself on a node it has never
  run on; no manual `mkdir`.
- A file written from the default (container-root) identity to a `--rw` path lands owned by the
  real user (test 11b); `--keep-id` changes only the identity seen from inside.
- LSF cgroup GPU fencing: a 1-GPU job on an 8-GPU `gpu_l4` node sees one GPU inside a
  `gpu=all` container; `nvidia-smi -i 1` on the host reports no device; `CUDA_VISIBLE_DEVICES`
  is `0` in every 1-GPU job (2026-10-08).
- Two concurrent podman jobs pinned to one node ran to completion with isolated state (2026-10-08).
- Running from the checkout: the wrapper re-binds `scripts/` read-only (PR #5, test 13).
- `--csub` verified 2026-10-12 and again 2026-10-16: probe, submit with wait, status, policy
  rejection (rc 3), grandchild; nothing left behind.
- The in-sandbox `/run/sandbox/README.md` verified 2026-10-16 under both wrappers with `--csub`
  and `--claude`; the `CLAUDE.md` pointer lands in the per-job copy only.
