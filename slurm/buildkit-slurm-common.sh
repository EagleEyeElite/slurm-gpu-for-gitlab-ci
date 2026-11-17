#!/bin/bash
# buildkit-slurm-common.sh — shared setup sourced by buildkit-slurm-build.sh.
# That script supports both build-only (default) and build+push (--push).
#
# Provides:
#   - Standard env (JOB_ID, BUILDKIT_ROOT, SHARED_SOCK, INNER_BUILD_ARGS, ...)
#   - Rootfs sanity check against the persistent daemon's state
#   - Build-context preparation (tar from $PROJECT_ROOT, mtime-touch so the
#     GC sweep doesn't reap it)
#   - Registry auth shim
#   - Job-ephemera GC (anything in $BUILDKIT_ROOT/tmp/ older than 4h)
#   - pivot_and_exec (re-exported from lib/pivot.sh) — runs the inner
#     script inside the same pivoted rootfs the shared daemon uses, so
#     buildctl inside sees /run/buildkit/buildkit-shared.sock at the
#     expected path. CI env-vars (REGISTRY_IMAGE, COMMIT_SHA, ...) are
#     baked into the inner-script heredoc by buildkit-slurm-build.sh,
#     not injected here — keeps pivot_and_exec generic enough for
#     buildkitd-sbatch.sh to reuse.
#
# Not directly invokable; exit 1 if run as a script.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: buildkit-slurm-common.sh is a library; source it, don't run it." >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pivot.sh"
PROJECT_ROOT="${CI_PROJECT_DIR:-$PWD}"
FAKEMOUNT="$SCRIPT_DIR/fakemount"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
JOB_ID="${CI_JOB_ID:-$$}"
# shellcheck disable=SC2034  # used by the sourcing script's heredoc
SHARED_SOCK="unix:///run/buildkit/buildkit-shared.sock"

# Outside CI (slurm-job-local, a manual run) there is no registry: a build
# works, a push needs CI_REGISTRY_IMAGE (and credentials) set by hand.
: "${CI_REGISTRY_IMAGE:=local/$(basename "$PROJECT_ROOT")}"
: "${CI_REGISTRY:=${CI_REGISTRY_IMAGE%%/*}}"
: "${CI_COMMIT_SHORT_SHA:=test}"

# Forward selected env vars as docker build-args. CI_JOB_TOKEN is always
# forwarded when set so Dockerfiles can consume it via --mount=type=secret
# (docs/consumer-api.md, "Private GitLab tokens in Dockerfiles"). BUILDKIT_BUILD_ARGS is a space-separated opt-in list
# of additional env-var names to forward as --opt build-arg:NAME=VALUE.
INNER_BUILD_ARGS=""
forward_list="${BUILDKIT_BUILD_ARGS:-}"
if [[ -n "${CI_JOB_TOKEN:-}" ]]; then
    case " $forward_list " in
        *" CI_JOB_TOKEN "*) ;;
        *) forward_list="CI_JOB_TOKEN $forward_list" ;;
    esac
fi
for name in $forward_list; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
        INNER_BUILD_ARGS="$INNER_BUILD_ARGS --opt build-arg:$name=$value"
    fi
done

# Rootfs must already exist (bootstrapped once; the daemon sbatch uses
# it too). Error loudly if missing — usually means the rootfs was wiped
# and needs re-extraction. See docs/operator.md, "Bootstrap the rootfs".
if [[ ! -x "$BUILDKIT_ROOT/usr/bin/buildctl" ]]; then
    echo "ERROR: $BUILDKIT_ROOT/usr/bin/buildctl missing on $(hostname) — the shared" >&2
    echo "       BuildKit rootfs hasn't been bootstrapped here. Is this job on" >&2
    echo "       BUILDKIT_NODE (${BUILDKIT_NODE:-unset})? Check that the" >&2
    echo "       buildkitd-${BUILDKIT_NODE:-<node>} sbatch is RUNNING and see docs/operator.md." >&2
    exit 1
fi

# Stage fakemount under a per-user dir, not a fixed /tmp/fakemount: /tmp is
# usually shared 1777 across users, so a fixed path would collide.
# Export FAKEMOUNT_BIN so lib/pivot.sh execs this copy.
export FAKEMOUNT_BIN="/tmp/${USER:-$(id -un)}/buildkit/fakemount"
mkdir -p "$(dirname "$FAKEMOUNT_BIN")"
cp "$FAKEMOUNT" "$FAKEMOUNT_BIN" 2>/dev/null || true
chmod +x "$FAKEMOUNT_BIN" 2>/dev/null || true

# --- Per-job build context preparation --------------------------------
# Outside the pivot. The inner script (inside pivot) reads this as
# /tmp/build-context-$JOB_ID because both daemon and consumer pivots
# see the same $BUILDKIT_ROOT as /.
cp /etc/resolv.conf "$BUILDKIT_ROOT/etc/resolv.conf"
rm -rf "$BUILDKIT_ROOT/tmp/build-context-$JOB_ID" 2>/dev/null || true
mkdir -p "$BUILDKIT_ROOT/tmp/build-context-$JOB_ID" \
         "$BUILDKIT_ROOT/home/builder/.docker"
tar cf - -C "$PROJECT_ROOT" . \
    | tar xf - -C "$BUILDKIT_ROOT/tmp/build-context-$JOB_ID"
# `tar xf` propagates the archive's "./" mtime onto the dest dir, which
# can be hours old when gitlab-runner reuses an older builds/<slot>/<proj>
# checkout. Without this touch, the -mmin +240 GC below would delete
# the just-extracted context before buildctl runs.
touch "$BUILDKIT_ROOT/tmp/build-context-$JOB_ID"

# Registry auth for buildctl (used only by push; harmless for build-only).
if [[ -n "${CI_REGISTRY_USER:-}" && -n "${CI_REGISTRY_PASSWORD:-}" ]]; then
    AUTH_B64=$(printf '%s:%s' "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" | base64 -w0)
    cat > "$BUILDKIT_ROOT/home/builder/.docker/config.json" <<EOF
{"auths":{"$CI_REGISTRY":{"auth":"$AUTH_B64"}}}
EOF
elif [[ -f "$HOME/.docker/config.json" ]]; then
    cp "$HOME/.docker/config.json" "$BUILDKIT_ROOT/home/builder/.docker/config.json"
fi

rm -f "$BUILDKIT_ROOT/tmp/buildkit-layers-$JOB_ID"

# GC job ephemera older than 4h. State dir (`buildkit-shared`) is NOT
# touched — that's the persistent daemon's warm cache.
find "$BUILDKIT_ROOT/tmp/" -maxdepth 1 \
    \( -name "build-context-*" -o -name "probe-ctx-*" \
     -o -name "buildkit-layers-*" -o -name "buildkit-probe-*.log" \
     -o -name "build-*.sh" -o -name "push-*.sh" \) \
    -mmin +240 -exec rm -rf {} + 2>/dev/null || true

# Every inner script first checks the shared daemon is reachable. Shared
# helper so both the build and push inner scripts look identical on this
# boilerplate.
# shellcheck disable=SC2034  # used by the sourcing script's heredoc
daemon_ready_check='
for i in $(seq 1 10); do
    if buildctl --addr "$SHARED_SOCK" debug workers >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! buildctl --addr "$SHARED_SOCK" debug workers >/dev/null 2>&1; then
    echo "ERROR: shared buildkitd at $SHARED_SOCK not reachable."
    echo "       Check squeue --me -n buildkitd-${BUILDKIT_NODE:-<node>}."
    exit 1
fi
'
