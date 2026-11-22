# Working on the Janelia cluster

All computation, compilation and installation happens on the cluster, never on this laptop.

- Run cluster commands as: ssh janelia-agent '<command>'
- Before your first cluster command in a session, run: ssh janelia-agent 'cat $SANDBOX_README'
  It describes what the sandbox allows right now: directories, network and how to submit
  jobs. Where it differs from this file, it is right. If it prints nothing, use this file.
  Read it again when a command fails in a way this file does not explain.
- Each ssh command is a separate job on a compute node. It can take up to a minute to
  start. Nothing carries over between commands except files in the project directory.
- Commands start in the project directory. Only that directory is readable and writable.
  Some files in it are read-only on purpose (git hooks and configuration, .mcp.json, .claude/
  settings, .vscode): leave them alone. If a command's error output says "the command created
  files that tools run or load outside the sandbox", repeat that list to the user.
- There is no bsub on the cluster side, and no network except the hosts the sandbox's
  description lists.
- For anything longer than a few minutes, or needing more CPUs or a GPU, submit a job:
  ssh janelia-agent 'csub submit --cpus N --walltime MIN -q short -- <command>'
  For a GPU add --gpus 1 and name a GPU queue in place of short; csub probe lists them.
  It prints the job id and returns. Check on the job with
  ssh janelia-agent 'csub status JOBID' and read its output with
  ssh janelia-agent 'csub logs JOBID'. Check no more often than once a minute, and with
  several jobs name them all in one csub status. Do not use --wait or csub wait from this
  laptop, even though the sandbox's description lists --wait: they ask the scheduler more
  often than that and hold a job slot while they wait.
  Run "ssh janelia-agent 'csub probe'" to see the queues and limits.
  Run "ssh janelia-agent 'csub submit -h'" for all options.
- To put a file on the cluster, write it there through ssh, or copy it with:
  scp FILE janelia-agent:<project directory>/FILE
- This laptop has internet access and the cluster has almost none. When the cluster cannot
  reach a site, download the file on this laptop and copy it to the project directory with
  scp. That is allowed without asking: downloading is not computation. Ask first for
  anything larger than about 1 GB, and check whether the data is already on the cluster.
- For how the cluster works in general (queues, GPU types, storage, billing), read
  https://hpc.int.janelia.org/docs/ai-agent-hints.md from this laptop before choosing
  a queue or sizing a job: curl -s https://hpc.int.janelia.org/docs/ai-agent-hints.md
  Where it says bsub, use csub. Where it differs from the sandbox's description, the
  sandbox is right.
- For Python packages, make a venv in the project directory and pip install into it. That
  needs pypi.org and files.pythonhosted.org among the hosts the sandbox's description lists.
  If they are missing, ask the user to add them; do not download packages on this laptop.
- For ssh and scp, use only janelia-agent: no other ssh host, user name or key.
