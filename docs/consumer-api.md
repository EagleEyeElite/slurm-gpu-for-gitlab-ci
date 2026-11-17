# Consumer API

How a project uses the SLURM runner from its own `.gitlab-ci.yml`. Setting the
runner up is [setup.md](setup.md); running it is [operator.md](operator.md).

## Include: image builds

`templates/image.yml` holds the image build as two hidden jobs on one
convention, `.image-slurm` (this runner) and `.image-buildah` (a runner with
buildah, for projects without this one): `:<short sha>` always, `:latest` from the default branch,
`BUILDKIT_BUILD_ARGS` forwarded by name, the job token as the `gitlab_token`
secret. A project keeps its own stage, needs and rules:

```yaml
include:
  - project: my-group/slurm-gpu-for-gitlab-ci   # your GitLab copy of this repository
    ref: main
    file: templates/image.yml
  # or: - remote: https://raw.githubusercontent.com/EagleEyeElite/slurm-gpu-for-gitlab-ci/main/templates/image.yml

build-image:
  extends: .image-slurm
  needs: []
  variables:
    BUILDKIT_BUILD_ARGS: "MY_SERVICE_COMMIT"
    MY_SERVICE_COMMIT: "$CI_COMMIT_SHA"
```

## Pipeline template

Drop this into your project's `.gitlab-ci.yml` to get a working
build → run → push pipeline. The `tags: [slurm]` selector routes the
job to this runner; the runner's `pre_build_script` reserves one SLURM
allocation for the whole job and tears it down on exit (`trap EXIT`),
so consumer YAML never has to call `salloc` / `srun` itself.

```yaml
ship:
  tags: [slurm]
  variables:
    SLURM_GPUS: "1"     # --gres=gpu:N; default 0; "max" = all free on the node
    SLURM_CPUS: "4"     # -c N; default 2
    SLURM_TIME: "120"   # --time=N (minutes); default 120
  script:
    - slurm-build         # BuildKit solve (no push)
    - slurm-run           # fuse-overlayfs mount + singularity --nv
    - slurm-build --push  # cached re-solve + registry push
```

## Variables

| Name | Default | Effect |
|---|---|---|
| `SLURM_GPUS` | `0` | `--gres=<SLURM_GRES_NAME>:N` on the job's salloc (none at 0); `max`: every GPU free on the job's node now (see below) |
| `SLURM_CPUS` | `2` | `-c N` |
| `SLURM_TIME` | `120` | `--time=N` (minutes) |
| `SLURM_MEM` | _(partition default)_ | `--mem=…`, e.g. `300G` |
| `BUILDKIT_BUILD_ARGS` | _(unset)_ | space-separated env-var names to forward as `--opt build-arg:NAME=VALUE` |
| `BIND_MOUNTS` | _(unset)_ | space-separated `host:container` or `host:container:ro` pairs forwarded to `singularity --bind` |
| `DOCKERFILE` | `Dockerfile` | dockerfile path inside the project root |
| `SLURM_NODE` | `BUILDKIT_NODE` | the node the job's allocation is on; `any` lets SLURM choose (for jobs that neither build nor run an image) |
| `SLURM_PARTITION`, `SLURM_ACCOUNT`, `SLURM_QOS` | the runner owner's settings | override them per job |
| `SLURM_EXTRA_ARGS` | the runner owner's settings | more salloc arguments, word-split |

`SLURM_GPUS: "max"` asks for every GPU of the job's node that no job holds
at the moment the job starts: `slurm-allocate` reads the node's `Gres=` and
`GresUsed=` from `scontrol -d show node <node> -o` (plain `-o` has no
`GresUsed`, and `AllocTRES` does not count gres on every cluster) and asks
salloc for the difference. The number it asked for replaces `max` in the job
shell (`export SLURM_GPUS=<n>`), so a script hands `$SLURM_GPUS` to its tool,
and the `>> slurm-allocate: ... held (gpu=<n> of <total>, max ...)` line in the
log says what it got. With every GPU taken it asks for **1** and queues for
it, with a line saying so: a whole node may never come free while serving
jobs hold cards, and one GPU is a slow build rather than none. It is a
snapshot -- a job that takes GPUs between the read and the salloc makes the
salloc wait for them. For jobs that scale with the GPUs they get, not for
ones that need an exact count. It needs a node (`SLURM_NODE` or
`BUILDKIT_NODE`), not `any`.

`BIND_MOUNTS` host paths must be absolute and must already exist —
the wrapper validates the syntax and refuses to silently `mkdir` for
you. Create the directory in an earlier `script:` step if you need it
(e.g. `- mkdir -p $CI_PROJECT_DIR/output`).

## Scripts

| Script | Role |
|---|---|
| `slurm-build` | BuildKit solve, no push. Writes overlay-layer paths for `slurm-run`. |
| `slurm-build --push` | Build + push to `$CI_REGISTRY_IMAGE` in a single `buildctl` call. The cache from the preceding `slurm-build` makes this a near-instant re-solve. |
| `slurm-run` | fuse-overlayfs mount of the just-built snapshots + `singularity run --nv`. Honors `BIND_MOUNTS`. |
| `slurm-monitor start <dir>` … `slurm-monitor stop <dir>` | Samples the job's own cgroup (CPU, memory, IO, GPUs) on the compute node, as an extra step of the allocation; `stop` writes `trace.json` (Perfetto), `summary.txt`, `performance.json` and the figure. The job marks its phases by appending to `$RESMON_EVENTS`. See *Profiling a job*. |
| `slurm-service <name> --image … --cmd '… {port}' -- <command>` | Starts a service from an image (as a SIF) on a free port, waits for its `--ready` paths, runs the command with `<NAME>_URL` set, stops the service. In CI all of it runs as a step of the job's allocation on its node. See *Services beside a command*. |
| `slurm-job-local <job> [--var K=V]... [--dry-run]` | Not for pipelines: one job of the working tree's `.gitlab-ci.yml`, run on the login node as this runner would, without a commit. See [operator.md](operator.md#a-ci-job-by-hand-slurm-job-local). |
| `package put <file> <package> <version> [<name>]` | One file into the generic package registry, as `<name>` (default its own). In CI the job token, into the job's own project; off CI `GITLAB_TOKEN` and `--project`. Needs no allocation. |
| `package get <package> <version> <name> [<dest>]`, `package exists …` | Read one file back (prints the path), or test that it is there. Reads use `GITLAB_TOKEN` (or the one in `~/.config/slurm-gitlab-ci/secrets`) before the job token, which reaches another project only where that project allows it. `--project <id\|path>` for another project's registry. |
| `slurm-sif <docker://registry/path/name:tag>` | The image as `~/.local/sif/<name>-<tag>.sif`, pulled on a compute node if it is not there; prints the path. See *Images as SIFs*. |
| `slurm-cache put\|fetch\|publish …` | A large tarball handed to a later job on this cluster, published to the package registry, and fetched back verified. See *Large artifacts between jobs*. |

The four BuildKit/upload commands refuse to run if `$SLURM_PIPELINE_ALLOC` is unset (= the runner
is mis-registered; see [setup.md](setup.md)). Within a job, `slurm-build` and
`slurm-run` share `$CI_JOB_ID` so the build's overlay layer paths at
`$BUILDKIT_ROOT/tmp/buildkit-layers-$CI_JOB_ID` on the BuildKit node are the
automatic handoff between the two steps.

## Forwarding build-args

`BUILDKIT_BUILD_ARGS` is a space-separated list of env-var names. Each
named var, if set in the CI job's environment, is forwarded to BuildKit
as a `--opt build-arg:NAME=VALUE`. Define the value in the same
`variables:` block:

```yaml
variables:
  DATA_VERSION: "v1"
  BUILDKIT_BUILD_ARGS: "DATA_VERSION"
```

The Dockerfile then reads it via `ARG DATA_VERSION` as usual.

## Private GitLab tokens in Dockerfiles

`CI_JOB_TOKEN` is auto-forwarded to `buildctl` as a BuildKit secret
(id `gitlab_token`) whenever the env var is set in the CI job. Access
it from a Dockerfile via `--mount=type=secret`; the token never
contributes to the layer hash, so private git clones and authenticated
curls cache on their real inputs (commit pin, package version).

```dockerfile
ARG CORE_LIB_COMMIT=abc1234
RUN --mount=type=secret,id=gitlab_token \
    TOKEN="$(cat /run/secrets/gitlab_token)" && \
    git clone "https://gitlab-ci-token:${TOKEN}@gitlab.example.org/group/project.git" \
        /tmp/project && \
    (cd /tmp/project && git checkout "$CORE_LIB_COMMIT")
```

For maven `settings.xml` that reads `${env.CI_JOB_TOKEN}`:

```dockerfile
RUN --mount=type=secret,id=gitlab_token \
    export CI_JOB_TOKEN="$(cat /run/secrets/gitlab_token)" && \
    mvn -f pom.xml package
```

The legacy `ARG CI_JOB_TOKEN=""` pattern still works but invalidates
the RUN layer every pipeline (the token rotates), so prefer the secret
mount for any RUN that's expensive.

## Gating the push to default-branch only

```yaml
build-and-run:
  tags: [slurm]
  variables:
    SLURM_GPUS: "4"
    BIND_MOUNTS: "$CI_PROJECT_DIR/output:/tmp/output"
  script:
    - mkdir -p output
    - slurm-build
    - slurm-run
  artifacts:
    paths: [output/*.tar.gz]

push:
  tags: [slurm]
  needs: [build-and-run]
  script:
    - slurm-build --push
    - package put output/thing.tar.gz my-package "$CI_COMMIT_SHORT_SHA"
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

The split-job re-solve still pays a small cost (daemon warmup, context
tar) — fine when cleanliness matters more than 4 seconds.

## Images as SIFs

Whatever is STARTED on the cluster from an image (a long-running service, a
benchmark rig) runs from a SIF. A service repository does not need to know
that: it pushes its image, and whoever starts it asks for the SIF.

```yaml
# optional pre-warm in the service's own pipeline, so the first start does not wait
sif:
  tags: [slurm]
  script:
    - slurm-sif "docker://${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}"
```

```bash
SIF="$(slurm-sif docker://<registry>/<group>/<project>:<tag>)"   # in a job or a script
ssh login-node '~/bin/slurm-sif docker://…'                        # from elsewhere
```

- The pull runs on a compute node: in place inside a SLURM job, otherwise as
  its own `srun` (`SIF_PARTITION`, default `SLURM_PARTITION`; `SIF_TIME`
  00:30:00, `SIF_MEM` 8G). `lib/pull-sif.sh` keeps a per-job
  `SINGULARITY_TMPDIR` that is removed even on cancel, and a layer cache on the
  node's local disk (`$NODE_LOCAL_DIR/singularity-cache`) that `singularity
  cache clean` trims on every pull (`SIF_CACHE_DAYS`, 14).
- In a CI job the job token is used for the GitLab registry; the image's
  project must allow the calling project (Settings → CI/CD → Job token
  permissions).
- Retention: per image name the `SIF_KEEP` (6) most recently used SIFs stay
  (a reuse touches the file). With `SIF_PROTECT_DIR` set, a SIF that any file
  under it names (e.g. your service definitions) is never deleted; if that
  directory cannot be read, nothing is. `slurm-sif --prune [<name>]` applies the rule
  without pulling.

## Large artifacts between jobs

A job artifact goes through GitLab: an 8 GB search index took 6.5 min to
upload and as long to download again, only for the next job on the same cluster to
read it. `slurm-cache` keeps it on the shared home instead, unpacked once:

```yaml
build:
  script:
    - ...                                   # produces out/thing.tar.gz
    - slurm-cache put thing "$V" out/thing.tar.gz --keep-tarball
publish:                                    # optional, later
  script:
    - slurm-cache publish thing "$V" "$(slurm-cache tarball thing "$V")" extra.json
    - slurm-cache drop-tarball thing "$V"
consume:
  script:
    - DIR="$(slurm-cache fetch thing "$V" --project <id of the publishing project>)"
```

- `put` unpacks into `~/.cache/slurm-cache/<name>/<version>/` and marks it
  ready (with the tarball's sha256) only once the extraction succeeded.
- `fetch` returns the cached copy only if its sha256 is the one the package
  registry's `manifest.json` records for that version right now; otherwise
  it downloads, verifies and unpacks. A copy that was never published, or was
  republished under the same name, is never handed out as the published one.
- `publish` uploads in 4 GiB parts plus `manifest.json` (GitLab's 5 GB file
  cap), the manifest last, so a manifest means a complete version.
- Retention per name: the `SLURM_CACHE_KEEP` (4) most recently used
  versions and the `SLURM_CACHE_TARBALLS_KEEP` (2) newest kept tarballs.

## Profiling a job

What a job used, attributed to it alone -- the sampler reads the allocation's
cgroup, so a neighbour on the shared node never shows up:

```yaml
build-and-run:
  tags: [slurm]
  variables:
    BIND_MOUNTS: "$CI_PROJECT_DIR/out:/tmp/output"
    RESMON_EVENTS: /tmp/output/events.jsonl   # where the job, in its container, marks phases
  script:
    - mkdir -p out
    - slurm-monitor start out
    - slurm-build
    - slurm-run
  after_script:
    - slurm-monitor stop out     # never fails; also runs when the job did
  artifacts:
    when: always
    paths: [out/trace.json, out/summary.txt, out/performance.json, out/*.svg]
```

The job's side is one file: JSON lines `{"t": <unix seconds>, "label": "...",
"kind": "phase-start"|"phase-end"|"point"}` appended to `$RESMON_EVENTS`
(`slurm-monitor mark "<label>" phase-start` from a shell). A label with a `/`
nests under the one before it. `slurm-monitor plot <dir>` draws the figure
anywhere matplotlib (or uv) is, `slurm-monitor compare --before <dir> --after
<dir>` diffs two profiles phase by phase. Outside an allocation it samples
locally; `--subtree <pid>` narrows it to one process tree (the restricted-pod
configuration has it too).

What only the job can say about itself -- how busy its services were, what its
own process held -- goes in `<dir>/series.jsonl`, one line per moment and
panel: `{"t": ..., "panel": "<name>", "unit": "...", "values": {"<label>":
<number>}}`. Panel `cpu` (cores) and `memory` (bytes) are drawn as dashed lines
in the figure's own panels, any other name becomes a panel of its own above the
disk; the figure stays one picture, drawn the same way for every job.

## Services beside a command

A measurement against a service, on the node that holds the GPUs, with
nothing over a network route:

```yaml
benchmark:
  tags: [slurm]
  variables:
    SLURM_GPUS: "2"
    SLURM_CPUS: "32"
    SLURM_MEM: "128G"
  script:
    - slurm-service embed --image "docker://$EMBED_IMAGE" --gpu
        --cmd 'serve --host 127.0.0.1 --port {port}' --ready /healthz --wait 1200 --
      slurm-service search --image "docker://$SEARCH_IMAGE"
        --env 'EMBED_URL=${EMBED_URL}' --cmd 'java -jar app.jar --server.port={port}' --ready /health --
      python3 measure.py          # SEARCH_URL and EMBED_URL are set
```

- The services and the command run as ONE step of the job's allocation on its
  compute node, with all of its CPUs, GPUs and memory -- not on the login
  node, and not as a second job (`srun --gres=…` next to the runner's
  allocation is one, and holds the cards twice).
- Nested calls start in order (an inner service once the outer one serves)
  and stop in reverse. `${VAR}` in an `--env` value is expanded at start.
- The image is pulled as a SIF by `slurm-sif`, with the job token in CI: the
  image's project must allow the calling one (job token allowlist).
- `--ready` is the path that answers 200 once the service SERVES; a server
  that binds before its models are loaded needs that path, not `/`.

