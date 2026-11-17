#!/bin/bash
# buildkit-slurm-build.sh — build the CI project's Dockerfile via the
# persistent BuildKit daemon on $BUILDKIT_NODE.
#
# Modes:
#   (default)  Build only. Writes layer paths for the subsequent
#              slurm-run step to fuse-overlayfs mount.
#   --push     Build + push to $CI_REGISTRY_IMAGE. The daemon's cache
#              is warm from the preceding default invocation, so this
#              is a near-instant cached re-solve plus image export.
#              No probe / layer-paths file (push doesn't feed slurm-run).
#
# Expected invocation: from slurm-build (which srun's into the node with
# --jobid=$SLURM_PIPELINE_ALLOC --overlap). The ambient SLURM allocation
# is created by the runner's pre_build_script and torn down by its
# bash EXIT trap.
set -euo pipefail

PUSH=0
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# shellcheck disable=SC1091
# shellcheck source-path=SCRIPTDIR source=buildkit-slurm-common.sh
source "$(dirname "$(readlink -f "$0")")/buildkit-slurm-common.sh"

# Inner script: runs inside the pivoted Alpine rootfs, talks to the
# shared daemon. In default mode: build (no push) + probe overlay layer
# paths for slurm-run. In --push mode: build with image export (push)
# in a single buildctl call, no probe.
cat > "$BUILDKIT_ROOT/tmp/build-$JOB_ID.sh" <<BUILDSCRIPT
#!/bin/sh
set -eu
export HOME=/home/builder
export DOCKER_CONFIG="\$HOME/.docker"

# CI env vars consumed by the buildctl invocation below. Set here (in the
# heredoc) rather than inside pivot_and_exec so the pivot helper can be
# reused by buildkitd-sbatch.sh without dragging CI knowledge into it.
# Outer expansion writes the literal values into the file; single-quotes
# protect them from re-expansion when the inner sh sources this script.
export REGISTRY_IMAGE='$CI_REGISTRY_IMAGE'
export COMMIT_SHA='$CI_COMMIT_SHORT_SHA'
export DOCKERFILE_NAME='$DOCKERFILE'
export JOB_ID='$JOB_ID'
export SHARED_SOCK='$SHARED_SOCK'
export INNER_BUILD_ARGS='$INNER_BUILD_ARGS'
export CI_JOB_TOKEN='${CI_JOB_TOKEN:-}'

$daemon_ready_check

SECRET_ARG=""
if [ -n "\${CI_JOB_TOKEN:-}" ]; then
    SECRET_ARG="--secret id=gitlab_token,env=CI_JOB_TOKEN"
fi

if [ "$PUSH" = "1" ]; then
    echo "==> Building + pushing \$DOCKERFILE_NAME (job=\$JOB_ID) to \$REGISTRY_IMAGE:\$COMMIT_SHA ..."
    time buildctl --addr "\$SHARED_SOCK" build \\
        --frontend dockerfile.v0 \\
        --local "context=/tmp/build-context-\${JOB_ID}" \\
        --local "dockerfile=/tmp/build-context-\${JOB_ID}" \\
        --opt filename="\$DOCKERFILE_NAME" \\
        \$INNER_BUILD_ARGS \\
        \$SECRET_ARG \\
        --output "type=image,\"name=\${REGISTRY_IMAGE}:\${COMMIT_SHA},\${REGISTRY_IMAGE}:latest\",push=true,compression=zstd,compression-level=1,force-compression=true,oci-mediatypes=true"
    echo "==> Push complete."
    exit 0
fi

echo "==> Building \$DOCKERFILE_NAME (job=\$JOB_ID) via shared daemon ..."
time buildctl --addr "\$SHARED_SOCK" build \\
    --frontend dockerfile.v0 \\
    --local "context=/tmp/build-context-\${JOB_ID}" \\
    --local "dockerfile=/tmp/build-context-\${JOB_ID}" \\
    --opt filename="\$DOCKERFILE_NAME" \\
    \$INNER_BUILD_ARGS \\
    \$SECRET_ARG
echo "==> Build complete (no push)."

# --- Overlay-layer probe for slurm-run's fuse-overlayfs mount ---
echo "==> Probing overlay layer paths..."
rm -rf "/tmp/probe-ctx-\${JOB_ID}"
mkdir -p "/tmp/probe-ctx-\${JOB_ID}"
cp -a "/tmp/build-context-\${JOB_ID}/." "/tmp/probe-ctx-\${JOB_ID}/"
# CI_JOB_ID + \$RANDOM guarantees uniqueness across concurrent pipelines.
# (Alpine busybox date inside the rootfs doesn't support %N, so a
# timestamp-based nonce collides on sub-second races.)
PROBE_NONCE="\${JOB_ID}-\$RANDOM"
echo "RUN echo probe-\$PROBE_NONCE && cat /proc/self/mountinfo" \\
    >> "/tmp/probe-ctx-\${JOB_ID}/\$DOCKERFILE_NAME"
PROBE_LOG="/tmp/buildkit-probe-\${JOB_ID}.log"
buildctl --addr "\$SHARED_SOCK" build \\
    --progress=plain \\
    --frontend dockerfile.v0 \\
    --local "context=/tmp/probe-ctx-\${JOB_ID}" \\
    --local "dockerfile=/tmp/probe-ctx-\${JOB_ID}" \\
    --opt filename="\$DOCKERFILE_NAME" \\
    \$INNER_BUILD_ARGS \\
    \$SECRET_ARG > "\$PROBE_LOG" 2>&1 || true
OVERLAY_INFO=\$(grep 'lowerdir=' "\$PROBE_LOG" | head -1 || true)
if [ -n "\$OVERLAY_INFO" ]; then
    LAYERS=\$(echo "\$OVERLAY_INFO" | sed 's/.*lowerdir=//' | sed 's/,.*//')
    echo "\$LAYERS" > "/tmp/buildkit-layers-\${JOB_ID}"
    echo "==> Layer paths saved (\$(echo "\$LAYERS" | tr ':' '\n' | wc -l) layers)"
else
    echo "==> Warning: could not discover layer paths"
    echo "==> Last 30 lines of probe build log (\$PROBE_LOG):"
    tail -30 "\$PROBE_LOG" || true
fi
BUILDSCRIPT
chmod +x "$BUILDKIT_ROOT/tmp/build-$JOB_ID.sh"

pivot_and_exec "/tmp/build-$JOB_ID.sh"
