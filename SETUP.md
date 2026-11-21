# One-time setup

Everything here is per account and done once. None of it runs on a login node: start an
interactive job first (`bsub -q interactive -Is /bin/bash`; the `short` queue takes batch jobs only) and do
the setup there. The README assumes
all of this is in place.

## 1. Get the wrappers

```bash
cd
git clone https://github.com/JaneliaScientificComputingSystems/agentic-sandbox.git
SANDBOX="$HOME/agentic-sandbox/scripts"       # the README's examples use this variable
# a new job shell starts without it: put the line above in your shell startup file
```

The rest of this document assumes the checkout is `~/agentic-sandbox`. Anywhere else works; set
`SANDBOX` to its `scripts/` directory.

Run the wrappers from a work directory, not from inside the checkout: the directory you invoke
them from is bound read-write, and the wrapper and its helper scripts run on the host. (If you do
run from the checkout, the wrapper re-binds its own directory read-only and says so.)

## 2. bwrap: nothing to set up

`sandbox-run.sh` needs only `bwrap` and `python3`, both present on the cluster nodes, and
unprivileged user namespaces (`/proc/sys/user/max_user_namespaces` > 0), which are enabled here.
`--gpu` additionally needs `nvidia-smi` on the host (inside an LSF GPU job); nothing else.

## 3. Podman (container images)

Skip this unless a task needs a container image. GPU access alone does not: `sandbox-run.sh --gpu`
uses the host's driver and needs none of the setup below.

**Rootless podman needs a `/etc/subuid`/`/etc/subgid` range for your account.** HPC provisions
these per user; they are not self-service and not granted by default. Ask before your first
podman job. For `--keep-id` the range must be *wider than your real GID*, which for AD/LDAP
accounts means more than the standard 65536 (a 131072-wide range works); ask for that explicitly
if you want `--keep-id`.

Point podman's image and container storage at node-local scratch instead of your home
directory, and turn off its own logging. Both are per-user config files in `$HOME`, so this is
once per account even though `/scratch` is per node:

```bash
mkdir -p ~/.config/containers
cp "$SANDBOX"/../config/storage.conf "$SANDBOX"/../config/containers.conf ~/.config/containers/
```

Both files are in this repo's `config/` directory and are the same for every account: the `$USER`
in `storage.conf` is written as is, and podman fills it in.

If you already have a `containers.conf`, add or update the three settings rather than overwriting
it. `podman-run.sh` passes both logging settings itself on every run, so a sandbox never logs
through podman even without this file; the file is what covers `podman` when you run it directly
(the node default, `journald`, copies everything a container prints into the system logs). You
do not need to create the storage directories; podman does that on first use on each node.

What this buys and costs: podman's per-user storage would otherwise land in
`~/.local/share/containers` and fill your home with multi-GB images. On scratch it is node-local
and wiped by the hourly cleanup whenever you have no job on that node, so a job on a new node, or
one starting more than an hour after your previous job there, pulls the image again (the lite
image is 1.24 GB; the PyTorch one several GB). If you'd rather trade that for a durable cache,
point `graphroot`/`runroot` at a path under `$HOME`.

No `podman login` or `podman pull` is needed: the images are public and `podman-run.sh` checks
for a newer one on every run.

## 4. Claude Code

Log in once outside the sandbox, from an interactive job:

```bash
claude auth login      # browser flow; paste the code back
```

That writes `~/.claude/.credentials.json`, which the wrappers bind through into every `--claude`
sandbox, so logins and token refreshes persist. A fresh `claude auth login` *inside* a sandbox
also works, but only if that file already exists on the host; otherwise the login is lost with
the job. The wrappers warn when that applies. The OAuth redirect goes to `platform.claude.com` and
lands on a paste-the-code prompt, so open the URL in your own browser, outside the sandbox.

Alternative, an API key: `export ANTHROPIC_API_KEY=...` and pass it with
`sandbox-run.sh --env ANTHROPIC_API_KEY`. For podman, which forwards no environment, put the key
in a `chmod 600` file under `/scratch/$USER/work` and read it inside the container. Never put
the key on a `bsub` command line: LSF keeps that verbatim in `bjobs -l`/`bhist -l`.

## 5. opencode with Kimi K3

Install opencode with its own installer, which puts the binary in `~/.opencode/bin` and works from a
compute node:

```bash
curl -fsSL https://opencode.ai/install | bash
```

Kimi K3 is served behind Janelia's LiteLLM gateway (`litellm.int.janelia.org`). Ask the HPC team
for a LiteLLM virtual key scoped to `kimi-k3`, then:

```bash
mkdir -p ~/.config/opencode && chmod 700 ~/.config/opencode
cat > ~/.config/opencode/opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.int.janelia.org/v1",
        "apiKey": "<your kimi-k3-scoped LiteLLM virtual key>"
      },
      "models": { "kimi-k3": { "name": "Kimi K3" } }
    }
  }
}
EOF
chmod 600 ~/.config/opencode/opencode.json
```

Then run opencode once outside the sandbox:

```bash
opencode models | grep litellm      # expect litellm/kimi-k3
```

This checks the config, and it is required after a fresh install: opencode writes
`~/.opencode/.gitignore` on its first start, and `--opencode` binds `~/.opencode` read-only, so a first
start inside the sandbox fails with `FileSystem.writeFile (.../.opencode/.gitignore)`.

The wrappers give each sandbox a throwaway copy of the config directory, so edits made inside never
reach it.

## 6. csub (optional: letting a sandboxed agent submit cluster jobs)

Skip this unless an agent must submit jobs. [csub](https://github.com/saalfeldlab/csub) is Stephan
Saalfeld's policy-checked job broker; the wrappers' `--csub` flag starts it for you. Clone it (for
its sample policy) and install it in a venv:

```bash
git clone https://github.com/saalfeldlab/csub ~/csub
python3 -m venv ~/.venvs/csub
~/.venvs/csub/bin/pip install ~/csub
```

This worked in a plain shell on the compute nodes checked on 2026-11-15 (it pulls `hatchling` and, on
Python 3.9, `tomli` from PyPI). If a node cannot reach PyPI, run the install through the wrappers'
allowlist proxy instead: `cd ~/csub && sandbox-run.sh --rw ~/.venvs/csub --allow pypi.org --allow
files.pythonhosted.org -- ~/.venvs/csub/bin/pip install .` (verified).

Write the policy with `scripts/csub-policy.sh`. It starts from csub's sample policy
(`~/csub/deploy/broker.janelia.toml`), so the queue and price tables are csub's current ones, and
sets what has to differ:

```bash
"$SANDBOX"/csub-policy.sh --bwrap --rw /groups/YOUR_LAB/YOUR_DIR/project
```

- `--bwrap` or `--podman`: how jobs submitted through csub are sandboxed. Use `--bwrap` unless you
  have the podman setup of §3; child jobs then run through `sandbox-run.sh` and need no image or
  subuid range.
- `--rw DIR` (repeatable): directories jobs may mount read-write. Use the narrowest directory under
  `/groups` or `/nrs` that holds the project, ideally one you created for agent work. The wrappers
  start the broker with the sandbox's mounts and hosts as its envelope (csub #12 for child jobs, #13
  for the top-level sandbox), so a job can only mount what the sandbox already sees; without the
  envelope (`CSUB_ENVELOPE=off`), a sandboxed agent can ask a job to mount any directory beneath a
  root, so everything under it is in reach. Never `$HOME` (csub refuses it) and never `/scratch` (the
  policy rejects it); the script refuses both.
- `--ro DIR` (repeatable): directories jobs may mount read-only at most, such as a dataset, a scorer
  or a venv. The broker forces any mount under them read-only even if the client asks for `:rw`.
- `--allow HOST` (repeatable): network hosts jobs may reach. None unless given.
- `--gpus N`, `--slots N`, `--walltime MIN`, `--cost USD`, `--pending N`: the limits for one job
  and the number of pending jobs per session. Without these options the limits stay as in csub's
  sample: 128 slots, 8 GPUs, 14 days, 200 dollars of estimated cost per job and 100 pending jobs. The
  cost limit is a check on each job when it is submitted (slots and GPUs times the walltime asked
  for, at the prices in the policy), not a budget across jobs.

Directories and hosts must be given in two places, because of the envelope: here, and as `--rw`,
`--ro` and `--allow` on the wrapper that starts the sandbox. The option names are the same on purpose.

The script writes the whole file from its options, checks that csub loads it and prints what it
set. It refuses to overwrite an existing policy; to change one, run it again with the full set of
options and `--replace`. For example, to add a read-only dataset and let jobs reach PyPI:

```bash
"$SANDBOX"/csub-policy.sh --bwrap --rw /groups/YOUR_LAB/YOUR_DIR/project \
    --ro /nrs/ml_datasets --allow pypi.org --allow files.pythonhosted.org --replace
```

What the script does not set, edit by hand in `~/.config/csub/broker.toml` afterwards (a later
`--replace` run discards hand edits):

- `[lsf] project`: the script deletes the sample's `"CHANGEME"` line, so jobs bill to your default
  (the tested case). Add `project = "NAME"` under `[lsf]` to bill to a lab or project.
- `allowed_images`: list the concrete images rather than the default glob, so `csub probe` and
  the in-sandbox README can tell an agent exactly what exists:
  `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest` and
  `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest`.
- `[queues.<name>]`: the sample has a stanza for every queue an agent may use. Delete the ones you
  do not want agents to reach.

Make the broker findable whenever you start a `--csub` sandbox:

```bash
export PATH=~/.venvs/csub/bin:$PATH
```

After a hand edit, check that csub still loads the policy:

```bash
echo '{"protocol":1,"op":"probe"}' | ~/.venvs/csub/bin/csub-broker     # expect "ok":true
```

The envelope covers hosts as well as mounts: a job that names an `agent` (policy `[agents]`) gets
that agent's hosts added, and the broker then refuses it unless the sandbox's own `--allow` list
includes them. Add the agent's hosts to `--allow` if its child jobs should run it.

## 7. The images (podman)

Both are pre-built on GHCR and pulled automatically. Build your own only if you need something
they lack:

```bash
cd agentic-sandbox/podman
podman build -t agentic-sandbox-lite:latest .                                   # CUDA runtime + CLIs
podman build -t agentic-sandbox-gpu:latest -f Dockerfile.pytorch .              # NVIDIA PyTorch + CLIs
# then: podman-run.sh --image localhost/agentic-sandbox-lite:latest ...
```

Note that csub policies cannot use `localhost/` images (they are not visible on other nodes).

## 8. An agent on your laptop (`ssh-entry.sh`)

Skip this unless the agent runs on your laptop and should do its work on the cluster. The README's
section "An agent on your laptop" says what this gives you. You need §1, and §6 if the agent should
submit jobs, which is the normal case. `LAPTOP` steps run in a terminal on the laptop, `CLUSTER` steps
on the cluster as yourself.

1. `CLUSTER`, inside an interactive job: make the project directory, outside your home directory, and
   write the csub policy for it.

```bash
PROJECT=/groups/YOUR_LAB/YOUR_DIR/project
mkdir -p "$PROJECT"
"$SANDBOX"/csub-policy.sh --bwrap --rw $PROJECT
```

   If you already wrote a policy in §6, this stops with `... exists; add --replace to overwrite it`.
   The script writes the whole policy each time, so give it everything again: the options you used
   in §6, plus `--rw $PROJECT`, plus `--replace`.

2. `LAPTOP`: make a key for the agent only. It has no passphrase, because the agent must use it
   unattended; the key line in step 4 is what limits it.

```bash
ssh-keygen -t ed25519 -N '' -C agent-cluster -f ~/.ssh/agent_cluster
```

3. `LAPTOP`: add an alias to `~/.ssh/config`, with your cluster user name, and copy the public half of
   the key over with your own login. The last three lines keep the agent from ever using your
   personal key.

```
Host janelia-agent
    HostName login1.int.janelia.org
    User YOUR_USER
    IdentityFile ~/.ssh/agent_cluster
    IdentitiesOnly yes
    IdentityAgent none
    BatchMode yes
```

```bash
scp ~/.ssh/agent_cluster.pub YOUR_USER@login1.int.janelia.org:agent_cluster.pub
```

4. `CLUSTER`, on the login node (this only edits a file): add the key line. `EXPIRES` is the first day
   the key no longer works, as year, month, day: sshd refuses the key from midnight at the start of
   that day, cluster time. Your existing keys stay untouched.

```bash
PROJECT=/groups/YOUR_LAB/YOUR_DIR/project
PUBKEY="$(cat ~/agent_cluster.pub)"
EXPIRES=20271231
ENTRY="env PATH=\$HOME/.venvs/csub/bin:\$PATH \$HOME/agentic-sandbox/scripts/ssh-entry.sh"
OPTS="--project $PROJECT --queue interactive --walltime 60 -- --csub"
LOCK="no-port-forwarding,no-agent-forwarding,no-X11-forwarding"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "command=\"$ENTRY $OPTS\",$LOCK,expiry-time=\"$EXPIRES\" $PUBKEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
command rm ~/agent_cluster.pub
```

   To let the agent reach a host or read another directory, add `--allow HOST` or `--ro DIR` after
   `--csub` in `OPTS`, and give the same options to `csub-policy.sh` with `--replace`. Both places are
   needed. For podman, add `--podman` before `--queue` and write the policy with `--podman`.

5. `LAPTOP`: test by hand. Each command is a cluster job, so each takes up to a minute to start.

```bash
ssh janelia-agent 'hostname; pwd'              # a compute node, then your project directory
ssh janelia-agent 'ls ~/.ssh'                  # No such file or directory
ssh janelia-agent 'bsub -V'                    # command not found
ssh janelia-agent 'head -22 $SANDBOX_README'   # what the sandbox tells the agent
ssh janelia-agent 'csub probe'                 # queues and limits, your project under the allowed roots
```

6. `LAPTOP`: give the agent a working directory with the instruction file from `config/`, and let it
   run `ssh` to the alias without asking each time. The file is fetched from this repo, since the
   laptop has no checkout. For Claude Code:

```bash
RAW=https://raw.githubusercontent.com/JaneliaScientificComputingSystems/agentic-sandbox/main/config
mkdir -p ~/claude-cluster/.claude && cd ~/claude-cluster && git init -q
curl -fsSL $RAW/CLAUDE.md -o CLAUDE.md
echo '{"permissions": {"allow": ["Bash(ssh janelia-agent:*)", "Bash(curl -s https://hpc.int.janelia.org/docs/ai-agent-hints.md:*)"]}}' > .claude/settings.json
```

   For Codex (use `AGENTS-podman.md` in place of `AGENTS.md` with `--podman`):

```bash
RAW=https://raw.githubusercontent.com/JaneliaScientificComputingSystems/agentic-sandbox/main/config
mkdir -p ~/codex-cluster ~/.codex/rules && cd ~/codex-cluster && git init -q
curl -fsSL $RAW/AGENTS.md -o AGENTS.md
echo 'prefix_rule(pattern = ["ssh", "janelia-agent"], decision = "allow")' >> ~/.codex/rules/default.rules
```

   Read the instruction file before you use it: it is what the agent will follow. Besides the sandbox's
   own description, it points the agent at the HPC team's hints page for AI agents
   (`https://hpc.int.janelia.org/docs/ai-agent-hints.md`, reachable from the Janelia network or VPN);
   the second permission in the Claude Code settings lets it fetch that page without asking. Then
   start the agent in that directory, with `claude` or `codex`.

   Claude Code: the first start in that directory must be the interactive one (`claude`, not
   `claude -p "..."`), and you must accept its question whether you trust the folder. Until you
   have, Claude Code ignores the two permissions above and says so ("Ignoring 2
   permissions.allow entries from .claude/settings.json: this workspace has not been trusted"),
   and a `claude -p` run cannot use `ssh janelia-agent`. Once is enough; after that `claude -p`
   works there too.

   The instruction file applies only when the agent is started in that directory. There, the agent
   still runs the code it writes, but on the cluster: each test or script goes through `ssh
   janelia-agent` and runs as a sandboxed job in the project directory, which takes from a few
   seconds to a minute to start. Started anywhere else on the laptop, the agent works as usual and
   runs its code locally. (The Codex rule that allows `ssh janelia-agent` without asking is
   account-wide; only the instruction to send the work there belongs to the directory.)

To watch: log in as yourself. `bjobs -a` lists the agent's jobs, the ssh sessions among them named
`agent-ssh`, and `PROJECT/.csub/jobs` has one directory per submitted job. To stop it: `bkill -J
agent-ssh 0` and `bkill -g /csub/$USER 0`. To cut it off: delete its line from
`~/.ssh/authorized_keys`.
