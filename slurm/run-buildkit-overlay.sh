#!/bin/bash
# run-buildkit-overlay.sh — Run from BuildKit overlay snapshots via fuse-overlayfs.
# Zero extraction, zero SIF conversion. Mounts layer diffs directly.
#
# Reads layer paths saved by buildkit-slurm-build.sh, converts them to
# host paths, mounts with fuse-overlayfs, and runs via singularity.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# Per-user host-/tmp base. /tmp is usually shared 1777 across users, so the
# fuse-overlayfs binary and per-run mount dirs must be namespaced — a fixed
# /tmp/fuse-overlayfs would collide with another user's copy.
USER_TMP="/tmp/${USER:-$(id -un)}/buildkit"
mkdir -p "$USER_TMP"
# A fuse-overlayfs the node already has wins (FUSE_OVERLAYFS_BIN, else PATH);
# otherwise a static release binary is downloaded once per node.
FUSE_OVERLAYFS="${FUSE_OVERLAYFS_BIN:-$(command -v fuse-overlayfs 2>/dev/null || echo "$USER_TMP/fuse-overlayfs")}"
FUSE_OVERLAYFS_VERSION="${FUSE_OVERLAYFS_VERSION:-v1.14}"
# Per-job layer paths file, written by buildkit-slurm-build.sh. Keyed on
# CI_JOB_ID so concurrent pipelines never read each other's paths. Falls
# back to SLURM_JOB_ID / $$ for manual invocations.
JOB_ID="${CI_JOB_ID:-${SLURM_JOB_ID:-$$}}"
LAYERS_FILE="$BUILDKIT_ROOT/tmp/buildkit-layers-$JOB_ID"
RUN_DIR="$USER_TMP/fuse-run-$JOB_ID"
PROJECT_ROOT="${CI_PROJECT_DIR:-$PWD}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"

# Ensure fuse-overlayfs
if [[ ! -x "$FUSE_OVERLAYFS" ]]; then
    curl -fsSL "https://github.com/containers/fuse-overlayfs/releases/download/$FUSE_OVERLAYFS_VERSION/fuse-overlayfs-$(uname -m)" \
        -o "$FUSE_OVERLAYFS.part" && chmod +x "$FUSE_OVERLAYFS.part" && mv "$FUSE_OVERLAYFS.part" "$FUSE_OVERLAYFS"
fi

# Read layer paths (saved by buildkit-slurm-build.sh inside the rootfs)
if [[ ! -f "$LAYERS_FILE" ]]; then
    echo "ERROR: $LAYERS_FILE not found. Run buildkit-slurm-build.sh first."
    exit 1
fi
INNER_LAYERS=$(cat "$LAYERS_FILE")

# Convert inside-rootfs paths to host paths
# Inside: /home/builder/.local/share/buildkit-shared/runc-overlayfs/snapshots/snapshots/8/fs
# Host:   $BUILDKIT_ROOT/home/builder/.local/share/buildkit-shared/runc-overlayfs/snapshots/snapshots/8/fs
HOST_LAYERS=$(echo "$INNER_LAYERS" | sed "s|/home/builder|$BUILDKIT_ROOT/home/builder|g")

NLAYERS=$(echo "$HOST_LAYERS" | tr ':' '\n' | wc -l)
echo "==> Mounting $NLAYERS overlay layers via fuse-overlayfs"

# Unmount and remove this run's overlay on ANY exit -- a failing container
# (set -e) or a cancelled job used to skip the cleanup at the bottom and leave
# the fuse-overlayfs mount and its fuse-run-<job> dir behind on the node.
# SLURM cancels with SIGTERM; turning it into a normal exit runs the trap.
cleanup() {
    fusermount3 -u "$RUN_DIR/merged" 2>/dev/null || true
    rm -rf "$RUN_DIR"
    [[ -n "${JOB_TMP:-}" ]] && rm -rf "$JOB_TMP"
    return 0
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Leftovers of runs that were SIGKILLed (no trap runs then), older than 4h.
# A plain (non-lazy) unmount fails with EBUSY while a run still uses it, so
# a long job's live mount is skipped, never pulled away.
find "$USER_TMP" -maxdepth 1 -mindepth 1 -name 'fuse-run-*' -mmin +240 2>/dev/null |
while read -r stale; do
    if mountpoint -q "$stale/merged"; then
        fusermount3 -u "$stale/merged" 2>/dev/null || continue
    fi
    rm -rf "$stale"
done

# Set up run directory
mkdir -p "$RUN_DIR"/{upper,work,merged}

# Singularity metadata in upper layer. `singularity run` consumes
# .singularity.d/runscript + env/*.sh — we synthesize them from the
# consumer project's Dockerfile so its CMD/ENTRYPOINT/ENV/WORKDIR are the
# single source of truth (no RUN_CMD override needed in .gitlab-ci.yml).
mkdir -p "$RUN_DIR/upper/.singularity.d/libs" "$RUN_DIR/upper/.singularity.d/env"
cat > "$RUN_DIR/upper/.singularity.d/env/99-base.sh" <<'EOF'
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/.singularity.d/libs"
export LD_LIBRARY_PATH
EOF

python3 "$SCRIPT_DIR/synthesize-singularity-runscript.py" \
    --dockerfile "$PROJECT_ROOT/$DOCKERFILE" \
    --output-dir "$RUN_DIR/upper/.singularity.d"

# Mount
"$FUSE_OVERLAYFS" -o "lowerdir=$HOST_LAYERS,upperdir=$RUN_DIR/upper,workdir=$RUN_DIR/work" \
    "$RUN_DIR/merged"

# Persistent per-node runner cache. Bind-mounted into every job at a
# stable container path so libraries (any HF_HOME / pooch / pip-cache user)
# can rely on it surviving across pipelines on the same compute node. Lives
# under NODE_LOCAL_DIR (the node's local disk); one cache per CI runner user
# keeps usage bounded.
#
# THE VARIABLE IS EXPORTED HERE, BY THE SCRIPT THAT CREATES THE MOUNT, and
# nowhere else. It used to be a constant in every job's environment
# (nix/modules/slurm-runner.nix set RUNNER_CACHE=/runner-cache), which made it a
# promise the runner could not keep: /runner-cache exists only inside a
# container this script launched. A job that runs `srun` directly, or its own
# `singularity exec`, or anything at all on the bare compute node, inherited a
# path to nothing — and singularity forwards the host environment, so the wrong
# value followed the job into every container it started for itself.
#
# It failed the way that kind of bug always does: not at export, but minutes
# later and three layers down, as
#   FileNotFoundError: '/runner-cache/...'
# from a library doing exactly what it was told. Setting it here means the
# variable and the mount are created by the same eleven lines; they cannot
# disagree, because there is no second place for them to disagree in.
#
# SINGULARITYENV_ prefix: singularity strips it and sets RUNNER_CACHE inside the
# container. Consumers see the same name they always did.
RUNNER_CACHE_HOST="${RUNNER_CACHE_HOST:-$NODE_LOCAL_DIR/gitlab-runner-cache}"
RUNNER_CACHE_CONTAINER="${RUNNER_CACHE_CONTAINER:-/runner-cache}"
mkdir -p "$RUNNER_CACHE_HOST"
export SINGULARITYENV_RUNNER_CACHE="$RUNNER_CACHE_CONTAINER"

BIND_ARGS="--bind $RUNNER_CACHE_HOST:$RUNNER_CACHE_CONTAINER"

# Per-job private /tmp. SLURM's /tmp is a shared 1777 dir with no per-job
# isolation, so by default singularity binds the host's shared /tmp into
# every container and concurrent jobs writing the same /tmp/* paths (e.g.
# /tmp/output) would collide. Bind a per-user, per-job dir instead — disk-backed (/tmp
# is on the node SSD), namespaced by $JOB_ID. This bind must come BEFORE any
# BIND_MOUNTS so a nested spec like ".../out:/tmp/output" layers on top of
# it. Removed by the EXIT trap above; dirs older than 4h are GC'd as well,
# for runs that were SIGKILLed before the trap could run.
# Path: /tmp/$USER/<category>/<job-id> — the "gitlab-pipeline" category keeps
# the per-user dir tidy instead of a flat pile of IDs.
JOB_TMP_BASE="/tmp/${USER:-$(id -un)}/gitlab-pipeline"
JOB_TMP="$JOB_TMP_BASE/${JOB_ID}"
find "$JOB_TMP_BASE" -maxdepth 1 -mindepth 1 -mmin +240 \
    -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$JOB_TMP"
BIND_ARGS="$BIND_ARGS --bind $JOB_TMP:/tmp"

# Additional bind mounts: BIND_MOUNTS is a space-separated list of
# "host:container" or "host:container:ro" specs forwarded to singularity.
# Used e.g. to surface build artifacts back to the runner so the CI job
# can archive them.
#
# Validate the syntax up-front (1 or 2 ':' separators, absolute host
# path) and fail loudly. Earlier revisions silently `mkdir -p`'d the
# host path, which masked typos in CI YAML — the consumer is now
# responsible for ensuring the host path exists before slurm-run.
for spec in ${BIND_MOUNTS:-}; do
    colons=${spec//[^:]/}
    if (( ${#colons} < 1 || ${#colons} > 2 )); then
        echo "ERROR: BIND_MOUNTS spec '$spec' must be host:container or host:container:ro" >&2
        exit 1
    fi
    host_path="${spec%%:*}"
    if [[ "$host_path" != /* ]]; then
        echo "ERROR: BIND_MOUNTS host path '$host_path' must be absolute (got '$spec')" >&2
        exit 1
    fi
    BIND_ARGS="$BIND_ARGS --bind $spec"
done

singularity run --userns --nv \
    $BIND_ARGS \
    "$RUN_DIR/merged"
# The EXIT trap unmounts and removes $RUN_DIR.
