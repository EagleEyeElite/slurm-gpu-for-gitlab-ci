#!/bin/bash
# buildkitd-sbatch.sh — persistent BuildKit daemon on $BUILDKIT_NODE.
#
# Intended to be run as the command of a long-running sbatch job submitted
# by ensure-buildkitd-sbatch. Sets up the BuildKit rootfs (one-time),
# enters a user namespace + mount namespace + PID namespace, pivot_roots
# into the rootfs, and execs buildkitd in the foreground on a shared
# unix socket.
#
# The shared socket lives inside the rootfs at
#   /run/buildkit/buildkit-shared.sock
# which is $BUILDKIT_ROOT/run/buildkit/buildkit-shared.sock on the node
# ($BUILDKIT_ROOT defaults to $NODE_LOCAL_DIR/buildkit, lib/config.sh).
# Consumer sruns (buildkit-slurm-build.sh) pivot_root into the same rootfs
# and see the same socket path — they talk to this daemon via buildctl
# instead of starting their own.
#
# BoltDB cache.db and the overlayfs snapshotter live in
#   /home/builder/.local/share/buildkit-shared
# (= $BUILDKIT_ROOT/home/builder/.local/share/buildkit-shared on the
# host). Put NODE_LOCAL_DIR on a local disk that is not cleared at boot,
# and the cache persists across daemon restarts, sbatch requeues, and node
# reboots. It must be local: overlayfs does not stack on NFS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
FAKEMOUNT="$SCRIPT_DIR/fakemount"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pivot.sh"

# Rootfs must already exist. A nix-built crane may not run on the node (its
# ELF interpreter points at /nix/store, which under nix-portable exists only
# inside the wrap), so the rootfs is seeded from the login node instead
# (bin/bootstrap-buildkit-rootfs). On a persistent NODE_LOCAL_DIR this branch
# only triggers on a first deploy, a wiped disk or a reinstalled node.
if [[ ! -x "$BUILDKIT_ROOT/usr/bin/buildkitd" ]]; then
    echo "ERROR: $BUILDKIT_ROOT/usr/bin/buildkitd missing on $(hostname)."
    echo "       The BuildKit rootfs hasn't been bootstrapped: run"
    echo "       ~/bin/bootstrap-buildkit-rootfs on the login node (docs/operator.md)."
    exit 1
fi

# Compile fakemount if needed
[[ ! -x "$FAKEMOUNT" ]] && [[ -f "$SCRIPT_DIR/fakemount.c" ]] && \
    gcc -static -o "$FAKEMOUNT" "$SCRIPT_DIR/fakemount.c"
# Per-user staging path (shared /tmp → no fixed /tmp/fakemount). pivot.sh
# execs $FAKEMOUNT_BIN.
export FAKEMOUNT_BIN="/tmp/${USER:-$(id -un)}/buildkit/fakemount"
mkdir -p "$(dirname "$FAKEMOUNT_BIN")"
cp "$FAKEMOUNT" "$FAKEMOUNT_BIN" 2>/dev/null || true
chmod +x "$FAKEMOUNT_BIN" 2>/dev/null || true

cp /etc/resolv.conf "$BUILDKIT_ROOT/etc/resolv.conf"
mkdir -p "$BUILDKIT_ROOT/run/buildkit" \
         "$BUILDKIT_ROOT/home/builder/.local/share" \
         "$BUILDKIT_ROOT/etc/buildkit"

# buildkitd.toml is written by home-manager into the slurm-build-scripts
# output tree (services.buildkitSlurm.registryMirrors, .gc); copy it in on
# every daemon start so a changed mirror takes effect on the next sbatch
# without rebuilding the rootfs.
# Use `install -m 0644` (not `cp`) — the source is in /nix/store with
# mode 0444, and a plain `cp` carries that into the destination, so the
# *next* daemon start fails with "Permission denied" trying to overwrite
# its own read-only output. install overrides the mode unconditionally.
install -m 0644 "$SCRIPT_DIR/buildkitd.toml" "$BUILDKIT_ROOT/etc/buildkit/buildkitd.toml"

# Clean up any leftover shared socket from a crashed previous daemon.
# (buildkitd refuses to start if the socket file already exists.) We only
# get here when the previous daemon has exited — the keepalive only
# submits a new sbatch if none is queued — so this is safe.
rm -f "$BUILDKIT_ROOT/run/buildkit/buildkit-shared.sock"

# --- Enter user ns + mount ns + pid ns, pivot_root, exec buildkitd ---
# pivot_and_exec --exec so SIGTERM from SLURM (on time-limit / scancel)
# propagates straight through to buildkitd; buildkitd in turn shuts down
# cleanly, flushing BoltDB and leaving the on-disk state consistent for
# the next daemon.
#
# Garbage collection is configured in buildkitd.toml ([worker.oci] gcpolicy,
# written by nix/modules/slurm-runner.nix): above maxUsedSpace, least
# recently used first, but never a snapshot used within keepDuration -- a
# running slurm-run reads its layers straight out of this state, unseen by
# BuildKit. A size limit alone (--oci-worker-gc-keepstorage) prunes the
# layers of a long job while it is still running on them.
pivot_and_exec --exec '
    export HOME=/home/builder
    mkdir -p /run/buildkit /home/builder/.local/share
    echo "==> Starting buildkitd (shared daemon) on /run/buildkit/buildkit-shared.sock"
    exec buildkitd \
        --config /etc/buildkit/buildkitd.toml \
        --addr unix:///run/buildkit/buildkit-shared.sock \
        --root /home/builder/.local/share/buildkit-shared \
        --oci-worker-snapshotter=overlayfs
'
