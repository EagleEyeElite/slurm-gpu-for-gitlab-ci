# What the cluster must allow

Everything here runs as an ordinary user, with no root and no setuid binary
of its own. That only works because the cluster allows a few things for
unprivileged users -- and on the cluster this was built on, **some of them had
to be enabled by the admins first**. On most HPC clusters, at least the user
namespaces and the subuid range for the BuildKit node are a request to your
admins. This page is what to ask for and how to check it.

## The BuildKit node

The one compute node that hosts the BuildKit daemon (`BUILDKIT_NODE`) needs
the most:

| Requirement | Why | Check (on the node, e.g. `srun -w <node> --pty bash`) |
|---|---|---|
| **Unprivileged user namespaces** (`kernel.unprivileged_userns_clone=1` where that sysctl exists, `user.max_user_namespaces` > 0, and no AppArmor/SELinux policy denying them) | BuildKit runs rootless inside one | `unshare --user --map-root-user true && echo ok` |
| **A subordinate uid and gid range for your user** in `/etc/subuid` and `/etc/subgid` (65536 ids, e.g. `alice:300000:65536`), or via the site's subid source (`getsubids`) | the image's uids 0..65535 map into it | `getsubids $USER; getsubids -g $USER` or `grep $USER /etc/subuid /etc/subgid` |
| **`newuidmap` / `newgidmap`** (setuid root, package `uidmap` / `shadow-utils`) | write that mapping | `ls -l "$(command -v newuidmap)"` shows `-rwsr-xr-x root` |
| **Linux ≥ 5.11** | overlayfs inside a user namespace (BuildKit's snapshotter) | `uname -r` |
| **FUSE** (`/dev/fuse`, `fusermount3`) | `slurm-run` mounts the layers with fuse-overlayfs | `ls -l /dev/fuse; command -v fusermount3` |
| **A persistent node-local directory** for you (`NODE_LOCAL_DIR`), not NFS, ideally surviving reboots | the rootfs and the build cache; overlayfs does not stack on NFS | `df -T <dir>` |
| **SingularityCE or Apptainer** (≥ 4.2 for `slurm-sif` with zstd images) | runs the built image, `--nv` for the GPUs | `singularity --version` |

Each tool says which of these is missing when it fails
([operator.md → Troubleshooting](operator.md#troubleshooting)).

The other compute nodes only need SingularityCE/Apptainer and FUSE if jobs
that run images land there; a job that neither builds nor runs an image
(`SLURM_NODE: any`) needs nothing special.

## The login node

| Requirement | Why |
|---|---|
| SLURM client commands (`salloc`, `srun`, `sbatch`, `squeue`, `scontrol`) | the runner's jobs are SLURM jobs |
| A home directory shared with the compute nodes | the tools, the config and the job workspaces are read there |
| Outbound HTTPS to your GitLab (and to the registries you pull from) | the runner polls GitLab |
| `crontab` for your user | renews the BuildKit daemon, backstops the runner |
| **Linger** for your user (`loginctl enable-linger`) | the runner's systemd user unit starts at boot. Usually polkit lets a user enable it for themselves; otherwise an admin runs `loginctl enable-linger <user>`, or the cron backstop starts the runner |
| For nix-portable: user namespaces on the login node too (its `bwrap` backend), or it falls back to `proot` (slower) | nix without root |

## What the admins should know

What this setup does on their cluster, so they can decide:

- one long-running SLURM job (the BuildKit daemon, 2 CPUs and 4 GB by
  default, renewed every 24 h) on one node, plus normal CI jobs through
  `salloc` with the resources each job asks for;
- a persistent `gitlab-runner` process (shell executor) on the login node, as
  the user; it executes CI jobs of the projects the user registered it for,
  **as that user** -- who can push to those projects can run code as them;
- disk use under `NODE_LOCAL_DIR` on the BuildKit node, bounded by the GC
  limit (`services.buildkitSlurm.gc.maxUsedSpace`, 300 GB by default).

## Restricted environments

The image builders in [`builders/`](../builders) (`kaniko-build`,
`buildah-build`) are for environments that grant **none** of the above: a
notebook or IDE container without user namespaces, a container daemon or
`CAP_SYS_ADMIN`. They need `sudo` (for `chroot` and `mknod`) instead. See
[builders/kaniko.md](builders/kaniko.md) and
[builders/buildah.md](builders/buildah.md).
