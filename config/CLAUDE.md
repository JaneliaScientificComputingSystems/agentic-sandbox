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
- There is no bsub on the cluster side, and no network except the hosts the sandbox's
  description lists.
- For anything longer than a few minutes, or needing more CPUs or a GPU, submit a job:
  ssh janelia-agent 'csub submit --cpus N --walltime MIN -q short --wait -- <command>'
  Run "ssh janelia-agent 'csub probe'" to see the queues and limits.
  Run "ssh janelia-agent 'csub submit -h'" for all options.
- To put a file on the cluster, write it there through ssh, or copy it with:
  scp FILE janelia-agent:<project directory>/FILE
- This laptop has internet access and the cluster has almost none. When the cluster cannot
  reach a site, download the file on this laptop and copy it to the project directory with
  scp. That is allowed without asking: downloading is not computation. Ask first for
  anything larger than about 1 GB, and check whether the data is already on the cluster.
- For Python packages, make a venv in the project directory and pip install into it.
- Use only the janelia-agent host. Do not use any other host, user name or key.
