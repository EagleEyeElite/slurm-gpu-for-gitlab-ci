# Operator manual

Daemon lifecycle, runner topology, how the build and run steps work, the
cache, and troubleshooting. The first setup is [setup.md](setup.md); what a
project writes in its `.gitlab-ci.yml` is [consumer-api.md](consumer-api.md);
what the cluster must allow is [admin-requirements.md](admin-requirements.md).

## Configuration

Every tool reads its site settings from three places; the first one wins:

1. the environment (a job's `variables:`, the runner's `environment`, an `export`),
2. `~/.config/slurm-gitlab-ci/config` (`$SLURM_CI_CONFIG`), which `hm-switch`
   writes from `services.slurmCi` and `services.buildkitSlurm`
   ([`local.example.nix`](../local.example.nix)),
3. the defaults in [`slurm/lib/config.sh`](../slurm/lib/config.sh).

The file is on the shared home, so the login node, cron and every compute
node read the same settings. Without nix you can write it by hand:

```bash
# ~/.config/slurm-gitlab-ci/config -- KEY="value", shell words ($USER expands)
GITLAB_URL="https://gitlab.example.org"
BUILDKIT_NODE="gpu-node-01"
NODE_LOCAL_DIR="/scratch/local/$USER"
SLURM_PARTITION="gpu"
```

| Setting | Default | Meaning |
|---|---|---|
| `BUILDKIT_NODE` | _(none)_ | the compute node of the BuildKit daemon; jobs that build or run images land there |
| `NODE_LOCAL_DIR` | `/tmp/$USER` | per-user directory on each node's **local** disk |
| `BUILDKIT_ROOT` | `$NODE_LOCAL_DIR/buildkit` | the BuildKit rootfs and its state |
| `SLURM_PARTITION`, `SLURM_ACCOUNT`, `SLURM_QOS` | _(unset)_ | passed to every salloc/srun/sbatch |
| `SLURM_GRES_NAME` | `gpu` | the GRES that counts GPUs |
| `SLURM_EXTRA_ARGS` | _(unset)_ | more salloc arguments for CI jobs |
| `GITLAB_URL` | _(unset)_ | for the tools outside CI (`CI_SERVER_URL` wins in a job) |
| `SLURM_CI_NIX_PORTABLE` | `1` | translate `/nix/store` paths to `~/.nix-portable/nix/store` for the compute nodes; `0` with a system nix |
| `SUBUID_START`/`SUBUID_COUNT`, `SUBGID_START`/`SUBGID_COUNT` | from `getsubids` or `/etc/subuid`, `/etc/subgid` | the subordinate range of the user namespace |
| `FUSE_OVERLAYFS_BIN` | `fuse-overlayfs` on PATH, else a static release download | the binary `slurm-run` mounts the layers with |
| `BUILDKIT_DAEMON_CPUS`/`_MEM`/`_TIME` | `2` / `4G` / `24:00:00` | the daemon's sbatch |
| `RUNNER_CACHE_HOST` | `$NODE_LOCAL_DIR/gitlab-runner-cache` | bound to `/runner-cache` in `slurm-run` containers |

Secrets are not in that file: `GITLAB_TOKEN` (for `package`, `slurm-cache`
and `slurm-job-local` outside CI) goes into `~/.config/slurm-gitlab-ci/secrets`
(mode 600).

## The runner daemon

The runner is the systemd **user** service `gitlab-runner.service`
(ExecStart `~/bin/gitlab-runner-run`). `hm-switch` writes the unit and the
shim, enables it, and restarts it only when the unit or the package changed:
a restart on every switch would interrupt running jobs.

```bash
systemctl --user status gitlab-runner     # active (running)
systemctl --user restart gitlab-runner    # after editing config.toml by hand
journalctl --user -u gitlab-runner -n 50  # recent log
```

A `nohup`-started runner dies with its login session (logind SIGTERMs the
session's processes on logout) and silently after a reboot. With linger
(`loginctl enable-linger`, which the switch runs) the user manager starts at
boot and brings the unit up with no login. The keepalive cron line
([setup.md](setup.md#5-cron)) is the backstop, and the fallback where there
is no systemd `--user` at all (it then starts the runner detached, with a pid
file).

## The BuildKit daemon

`buildkitd` runs as a 24 h sbatch named `buildkitd-<node>` on
`BUILDKIT_NODE`. `~/bin/buildkitd-keepalive` (cron, every 5 minutes) is
idempotent: if that job is queued or running it does nothing, otherwise it
submits a new one.

```bash
squeue --me -n "buildkitd-$BUILDKIT_NODE"     # one RUNNING job
tail ~/.local/share/buildkitd-sbatch/cron.log
ls ~/.local/share/buildkitd-sbatch/           # the daemon's own logs
```

The daemon pivot_roots into `$BUILDKIT_ROOT` on the node, which
`~/bin/bootstrap-buildkit-rootfs` seeds once: `crane export` on the login node
streams the BuildKit image (`moby/buildkit`, Alpine) over `srun` to the node,
where `tar` inside a user namespace extracts it. With
`services.buildkitSlurm.enable` every switch runs it; it does nothing when the
rootfs is there. On a node whose local disk was wiped, run it again by hand,
then `~/bin/buildkitd-keepalive`.

To move the daemon to another node, change `services.buildkitSlurm.node`,
`hm-switch` (it seeds the new node), and `scancel` the old `buildkitd-<node>`
job.

## Registering runners

One `gitlab-runner` daemon serves any number of registrations: one
`[[runners]]` block per group or project in `~/.gitlab-runner/config.toml`.
After adding one, `hm-switch` patches it (the `environment`, the
`pre_build_script`, `request_concurrency`); a block with an executor other
than `shell` is left alone.

### Via the API (scriptable)

```bash
# Group runner (every project in the group); project_type + project_id=<ID> for one project
glab api -X POST user/runners \
    -f runner_type=group_type -f group_id=<GROUP_ID> \
    -f description='my-group_on_slurm' \
    -f tag_list=slurm -f run_untagged=false
# => {"id":N,"token":"glrt-..."}
```

and append a block with that `id` and `token`:

```toml
[[runners]]
  name = "my-group_on_slurm"
  url = "https://gitlab.example.org"
  id = N
  token = "glrt-..."
  executor = "shell"
```

then `hm-switch` (it adds the rest) -- the runner reloads `config.toml` by
itself.

### Scope

A runner's `runner_type` (`instance_type`, `group_type`, `project_type`) is
fixed when it is created; `PUT /runners/:id` cannot change it. So:

- a `project_type` runner cannot also be scoped to a group;
- a `group_type` runner serves exactly one group (and its subgroups);
  several top-level groups need one registration each, or an instance runner
  (admin);
- a `project_type` runner can be enabled on more projects:
  `glab api -X POST projects/<id>/runners -f runner_id=<runner id>`.

### Names, tags and notes

Sites with a naming policy for runners can keep it in
`services.gitlabRunnerSlurm.runners` (name, extra tags, maintenance note per
runner id). The switch sets the local name; `gitlab-runner-sync-metadata`
(with a personal access token, scope `api`, in `GITLAB_TOKEN`) puts all three
into GitLab. It is idempotent and keeps every existing tag.

## A CI job by hand: `slurm-job-local`

To iterate on a job without a commit, a push and a queue wait per attempt,
run it from the working tree on the login node:

```bash
cd ~/src/my-project
slurm-job-local build-and-run                        # as the pipeline would
slurm-job-local build-and-run --var SLURM_GPUS=1 --var SLURM_TIME=30
slurm-job-local build-and-run --dry-run              # the resolved job and its environment
```

It reads the job as GitLab does (`extends`, `include:` of another project's
file -- with `GITLAB_TOKEN` or the one in `~/.config/slurm-gitlab-ci/secrets`
--, `default:`, the variables with `$VAR` expanded), sets what this runner sets
(PATH, the `CI_*` a job reads, from the working tree's git), holds one SLURM
allocation for it like the runner's pre_build_script, and runs before_script,
script and after_script. Not set: `CI` (a script that tells a pipeline from a
person sees a person) and a job token -- a job that pushes or publishes is a
pipeline's. Rules, needs, artifacts and dotenv are ignored; give what a
previous job's dotenv would have with `--var`. Only jobs for this runner
(`tags: [slurm]`) run.

## How it works

**The job.** The runner uses the shell executor on the login node. Its
`pre_build_script` is `eval "$(~/bin/slurm-allocate)"`: one `salloc` for the
whole job (`SLURM_GPUS`, `SLURM_CPUS`, `SLURM_MEM`, `SLURM_TIME`), exported as
`SLURM_PIPELINE_ALLOC`, and a `trap EXIT` that `scancel`s it when the job
shell ends -- success, failure or cancel. Every tool then runs its steps with
`srun --jobid=$SLURM_PIPELINE_ALLOC --overlap`.

**Isolation.** User namespace + mount namespace + the `fakemount` seccomp
filter + `pivot_root` into the BuildKit rootfs. Inside the user namespace runc
has the capabilities it needs (mount, pivot_root, /proc), so BuildKit runs as
standard rootless. `fakemount` only fakes the mount-propagation changes
(`MS_PRIVATE|MS_REC`) that fail even in a user namespace.

**Run step.** After the build, a probe step appends `RUN cat
/proc/self/mountinfo` to the Dockerfile and builds again (fully cached, ~0 s).
Its output names the overlay `lowerdir=` paths -- the snapshot directories in
layer order. `run-buildkit-overlay.sh` mounts them with fuse-overlayfs and
runs `singularity run --userns --nv` on the merged rootfs: no SIF conversion,
no push needed to run.

**Cache mounts.** `RUN --mount=type=cache` (pip, uv, apt, maven) persists in
BuildKit's state across builds, surviving layer-cache invalidation.

### Timings

On a 2-core daemon with a ~3 GB PyTorch image:

| Scenario | Build+run | Push | Total |
|----------|-----------|------|-------|
| Code-only change (warm cache) | **~9s** | ~4s | **~13s** |
| Dependency change (cached downloads) | **~23s** | ~72s | **~95s** |
| Full cold build (nothing cached) | ~100s | ~72s | **~172s** |

- cache mounts: a dependency change skips the 3.4 GB re-download;
- zstd level 1: 3x faster layer export than gzip;
- 2 cores: more were slower (I/O contention in Go's zstd);
- build+run feedback comes before the push.

### The scripts underneath

```bash
# Build on the daemon node (no push; what slurm-build does):
srun -w "$BUILDKIT_NODE" -c 2 bash slurm/buildkit-slurm-build.sh
# Run the freshly built image (slurm-run):
srun -w "$BUILDKIT_NODE" --gres=gpu:1 -c 2 bash slurm/run-buildkit-overlay.sh
# Push the warm-cached build (slurm-build --push):
srun -w "$BUILDKIT_NODE" -c 2 bash slurm/buildkit-slurm-build.sh --push
```

## The cache on the node

BuildKit's state persists on the node's local disk between jobs:

```
$BUILDKIT_ROOT/home/builder/.local/share/buildkit-shared/
├── runc-overlayfs/snapshots/   # overlay layer diffs (used by fuse-overlayfs)
├── runc-overlayfs/content/     # content-addressable store (manifests, configs)
├── runc-overlayfs/cachemounts/ # download caches (survive layer prune)
└── cache.db                    # build cache metadata
```

Small per-user helpers on the node's `/tmp` live under `/tmp/$USER/buildkit/`
(`fakemount`, a downloaded `fuse-overlayfs`, the per-run `fuse-run-<job>`
mount directories), so users on a shared node never collide. A `slurm-run`
container gets a private `/tmp` bound from
`/tmp/$USER/gitlab-pipeline/<job-id>`, so the app writes plain `/tmp/...`.

**Garbage collection** is the `[worker.oci]` policy in `buildkitd.toml`
(`services.buildkitSlurm.gc`): nothing used within `keepDuration` (12h) is
pruned -- `slurm-run` reads snapshots BuildKit holds no lease for, so a plain
size limit would delete the layers of a running job --, and above
`maxUsedSpace` (300GB) the rest goes, least recently used first.

### Cleaning it by hand

The files belong to your subordinate uids. Remove them inside a user
namespace with the same mapping (run on the node, e.g. in an `srun -w`):

```bash
read -r S C < <(getsubids "$USER" | awk '{print $3, $4}')   # or your /etc/subuid line
read -r GS GC < <(getsubids -g "$USER" | awk '{print $3, $4}')
unshare --user sleep infinity & PID=$!; sleep 0.2
newuidmap $PID 0 "$(id -u)" 1 1 "$S" "$C"
newgidmap $PID 0 "$(id -g)" 1 1 "$GS" "$GC"
nsenter -t $PID --user rm -rf "$BUILDKIT_ROOT/home/builder/.local/share/buildkit-shared"
kill $PID
```

## Troubleshooting

- **"BUILDKIT_NODE is not set"** -- set `services.buildkitSlurm.node` (or
  `BUILDKIT_NODE` in `~/.config/slurm-gitlab-ci/config`).
- **"no subordinate uid range for …"** -- the node has no `/etc/subuid` entry
  for you ([admin-requirements.md](admin-requirements.md)), or set
  `SUBUID_START`/`SUBUID_COUNT` to the one you have.
- **`unshare: unshare failed: Operation not permitted`** -- unprivileged user
  namespaces are off on that node.
- **"remount /, flags: 0x44000: invalid argument"** -- the fakemount filter
  was not applied: `/tmp/$USER/buildkit/fakemount` is missing on the node
  (it is copied there, or compiled with gcc, on the daemon's start).
- **"runc run failed: no cgroup mount found"** -- the build script
  bind-mounts `/sys/fs/cgroup` from the host; the node has no cgroup v2 mount
  there.
- **"Permission denied" cleaning the cache** -- see *Cleaning it by hand*.
- **zstd images fail with `singularity pull`** -- SingularityCE before 4.2
  cannot read zstd layers. `slurm-run` is unaffected (fuse-overlayfs, no
  pull); `slurm-sif` needs ≥ 4.2.
- **Every job fails at `prepare_environment` with "exit status 1"** -- a
  `~/.bash_logout` that runs `clear_console` without a TTY. The module gates
  the Debian default on a TTY; check any other logout hook.
- **The runner idles for minutes between jobs** -- `request_concurrency` 1
  with several runners on one daemon; the module sets 4.

## Source tree

```
slurm/
├── bin/                              entrypoints (~/bin shims)
│   ├── slurm-allocate                pre_build_script: salloc + eval'able bash
│   ├── slurm-build [--push]          build via the daemon + probe the layer paths
│   ├── slurm-run                     fuse-overlayfs + singularity --nv
│   ├── slurm-sif <image>             the image as a SIF on the shared home, pulled on a node
│   ├── slurm-cache                   large artifacts between jobs: put / fetch / publish
│   ├── slurm-monitor                 a job's resource profile: start / stop / plot / compare / mark
│   ├── slurm-service                 a command with services from images beside it
│   ├── package                       one file in the generic package registry: put / get / exists
│   ├── upload-to-package-registry    `package put` on the allocation's node (older pipelines)
│   ├── ensure-buildkitd-sbatch       the daemon keepalive (cron)
│   └── bootstrap-buildkit-rootfs     one-time rootfs seed via crane + tar
├── lib/                              sourced helpers
│   ├── config.sh                     settings: environment > config file > defaults
│   ├── dispatch.sh                   require_alloc, run_in_alloc, store-path translation
│   ├── registry.sh                   package registry URLs and tokens
│   ├── pull-sif.sh                   singularity pull on a node
│   └── pivot.sh                      user namespace, id maps, pivot_and_exec
├── monitor/                          slurm-monitor's sampler and renderers
├── tests/                            slurm-allocate against a fake salloc/scontrol
├── buildkit-slurm-build.sh           build orchestrator (inside an srun)
├── buildkit-slurm-common.sh          per-job context tar, GC, registry auth
├── buildkitd-sbatch.sh               the daemon (sbatch payload)
├── run-buildkit-overlay.sh           BIND_MOUNTS validation + singularity run
├── slurm-job-local.py                one CI job by hand
├── synthesize-singularity-runscript.py  Dockerfile CMD/ENV/WORKDIR for singularity
└── fakemount.c                       the seccomp filter, statically linked
builders/                             kaniko-build, buildah-build (restricted environments)
nix/modules/                          the home-manager modules
templates/image.yml                   the image build to include:
images/slurm-cache/                   slurm-cache + package as an image
```
