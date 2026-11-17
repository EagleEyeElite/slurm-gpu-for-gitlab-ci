#!/bin/bash
#
# buildah-build.sh — Build Docker images with a patched buildah, in
# environments without enough privileges for Docker or podman (a notebook or
# IDE container: no daemon, no CAP_SYS_ADMIN, no user namespaces) where sudo
# (chroot, mknod) still works.
#
# Works without CAP_SYS_ADMIN or user namespaces by combining:
#   1. A patched buildah binary (non-fatal mount/capability errors, VFS fallback)
#   2. A simple seccomp BPF filter (fakemount-simple) that fakes mount/umount/
#      pivot_root/unshare syscalls
#
# The approach uses sudo chroot into a Fedora-based buildah rootfs with VFS
# storage. No overlay mounts, no user namespaces, no runc.
#
# Requirements:
#   - sudo (with CAP_SYS_CHROOT and CAP_MKNOD)
#   - the patched buildah v1.41.5 and the two static helpers (fakemount-simple,
#     buildah-wrap). Installed through nix (`buildah-build`, the
#     restricted-builders home-manager module), which passes them in as BUILDAH_PATCHED,
#     FAKEMOUNT_BIN and WRAPPER_BIN. Without them, the hand-built
#     ~/.local/share/buildah-builder/buildah-patched is used and gcc compiles the
#     helpers next to this script on first run.
#   - the Fedora buildah rootfs, ~/.local/share/buildah-builder/chroot-clean.tar:
#     exported from quay.io/buildah/stable:$BUILDAH_ROOTFS_TAG with crane on
#     first run if it is missing (anonymous, public image).
#
# Docker Hub pulls go through DOCKER_HUB_MIRROR if it is set (host[:port] of
# a pull-through cache). Push credentials: the "auths" of ~/.docker/config.json
# (or $REGISTRY_AUTH_FILE), copied into the chroot.
#
# Usage:
#   ./buildah-build.sh [options]
#
# Options:
#   -f, --dockerfile PATH   Path to Dockerfile (default: ./Dockerfile)
#   -c, --context PATH      Build context directory (default: current directory)
#   -d, --destination TAG   Full image tag for push (e.g. registry.example.com/img:v1)
#   --push                  Push after build (requires -d)
#   -v, --verbose           Verbose output (buildah --log-level debug)
#   -h, --help              Show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDAH_DATA_DIR="$HOME/.local/share/buildah-builder"
BUILDAH_CHROOT_TAR="$BUILDAH_DATA_DIR/chroot-clean.tar"
BUILDAH_ROOTFS_TAG="${BUILDAH_ROOTFS_TAG:-v1.41.5}"
BUILDAH_PATCHED="${BUILDAH_PATCHED:-$BUILDAH_DATA_DIR/buildah-patched}"
FAKEMOUNT_SRC="$SCRIPT_DIR/fakemount-simple.c"
FAKEMOUNT_BIN="${FAKEMOUNT_BIN:-$SCRIPT_DIR/fakemount-simple}"
WRAPPER_SRC="$SCRIPT_DIR/buildah-wrap.c"
WRAPPER_BIN="${WRAPPER_BIN:-$SCRIPT_DIR/buildah-wrap}"

# --- Defaults ---
DOCKERFILE="Dockerfile"
CONTEXT="."
DESTINATION=""
PUSH=false
VERBOSE=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--dockerfile) DOCKERFILE="$2"; shift 2 ;;
        -c|--context)    CONTEXT="$2"; shift 2 ;;
        -d|--destination) DESTINATION="$2"; PUSH=true; shift 2 ;;
        --push)          PUSH=true; shift ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        -h|--help)       sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Resolve paths ---
CONTEXT="$(cd "$CONTEXT" && pwd)"
[[ "$DOCKERFILE" != /* ]] && DOCKERFILE="${CONTEXT}/${DOCKERFILE}"

log() { echo "==> $*"; }
vlog() { $VERBOSE && echo "    $*" || true; }

# --- Compile seccomp filter (first-time) ---
if [[ ! -x "$FAKEMOUNT_BIN" ]]; then
    log "Compiling fakemount-simple seccomp filter..."
    gcc -static -o "$FAKEMOUNT_BIN" "$FAKEMOUNT_SRC"
fi

# --- Compile buildah wrapper (first-time) ---
if [[ ! -x "$WRAPPER_BIN" ]] || [[ "$WRAPPER_SRC" -nt "$WRAPPER_BIN" ]]; then
    log "Compiling buildah wrapper..."
    gcc -static -O2 -o "$WRAPPER_BIN" "$WRAPPER_SRC"
fi

# --- Buildah rootfs (first-time) ---
if [[ ! -f "$BUILDAH_CHROOT_TAR" ]]; then
    command -v crane >/dev/null || { echo "Error: $BUILDAH_CHROOT_TAR not found and no crane to fetch it." >&2; exit 1; }
    log "Fetching the buildah rootfs quay.io/buildah/stable:$BUILDAH_ROOTFS_TAG (first-time only)..."
    mkdir -p "$BUILDAH_DATA_DIR"
    crane export --platform linux/amd64 "quay.io/buildah/stable:$BUILDAH_ROOTFS_TAG" "$BUILDAH_CHROOT_TAR.part"
    mv "$BUILDAH_CHROOT_TAR.part" "$BUILDAH_CHROOT_TAR"
fi

# --- Check prerequisites ---
[[ ! -f "$BUILDAH_PATCHED" ]]    && { echo "Error: $BUILDAH_PATCHED not found. Build from patched source first." >&2; exit 1; }
[[ ! -f "$DOCKERFILE" ]]         && { echo "Error: Dockerfile not found at $DOCKERFILE" >&2; exit 1; }
sudo -n true 2>/dev/null         || { echo "Error: passwordless sudo required." >&2; exit 1; }

# ============================================================
# Persistent build chroot (reuse across builds for VFS layer cache)
# ============================================================
BUILD_CHROOT="/tmp/buildah-restricted-persistent"

install_buildah_wrapper() {
    # /proc/self/exe is symlinked to /usr/bin/buildah. When patched buildah
    # re-execs itself as "buildah-chroot-runtime"/"buildah-copier", the child
    # inherits only LOGLEVEL=5. Without HOME, containers/common/pkg/config
    # fails with "cannot determine user's homedir". A static C wrapper sets
    # HOME=/root and execs the real binary preserving argv[0] (a shell wrapper
    # would lose argv[0] via the shebang dispatch).
    sudo cp "$BUILDAH_PATCHED" "$BUILD_CHROOT/usr/bin/buildah.real"
    sudo chmod +x "$BUILD_CHROOT/usr/bin/buildah.real"
    sudo cp "$WRAPPER_BIN" "$BUILD_CHROOT/usr/bin/buildah"
    sudo chmod +x "$BUILD_CHROOT/usr/bin/buildah"
}

setup_chroot() {
    log "Setting up persistent buildah chroot at $BUILD_CHROOT (first-time only)..."
    sudo mkdir -p "$BUILD_CHROOT"
    sudo tar xf "$BUILDAH_CHROOT_TAR" -C "$BUILD_CHROOT"
    install_buildah_wrapper
    sudo cp "$FAKEMOUNT_BIN" "$BUILD_CHROOT/usr/local/bin/fakemount-simple"
    sudo chmod +x "$BUILD_CHROOT/usr/local/bin/fakemount-simple"
    sudo touch "$BUILD_CHROOT/.buildah-restricted-ready"
}

if [[ ! -f "$BUILD_CHROOT/.buildah-restricted-ready" ]]; then
    setup_chroot
else
    log "Reusing persistent chroot at $BUILD_CHROOT (VFS layer cache preserved)"
    # Update buildah binary if it changed
    if ! cmp -s "$BUILDAH_PATCHED" "$BUILD_CHROOT/usr/bin/buildah.real" 2>/dev/null; then
        log "Updating patched buildah binary..."
        install_buildah_wrapper
    fi
fi

# ============================================================
# Configure container storage (VFS — no overlayfs/mount needed)
# ============================================================
sudo tee "$BUILD_CHROOT/etc/containers/storage.conf" > /dev/null << 'EOF'
[storage]
driver = "vfs"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
EOF

# ============================================================
# Configure registries
# ============================================================
{
    echo 'unqualified-search-registries = ["docker.io"]'
    if [[ -n "${DOCKER_HUB_MIRROR:-}" ]]; then
        printf '\n[[registry]]\nlocation = "docker.io"\n\n[[registry.mirror]]\nlocation = "%s"\n' "$DOCKER_HUB_MIRROR"
    fi
} | sudo tee "$BUILD_CHROOT/etc/containers/registries.conf" > /dev/null

# ============================================================
# Container policy: accept anything
# ============================================================
echo '{"default": [{"type": "insecureAcceptAnything"}]}' \
    | sudo tee "$BUILD_CHROOT/etc/containers/policy.json" > /dev/null

# ============================================================
# containers.conf: disable userns / cgroup manager
# ============================================================
sudo tee "$BUILD_CHROOT/etc/containers/containers.conf" > /dev/null << 'EOF'
[containers]
default_capabilities = []
[engine]
cgroup_manager = "cgroupfs"
EOF

# ============================================================
# Empty subuid/subgid to prevent userns lookups
# ============================================================
echo "" | sudo tee "$BUILD_CHROOT/etc/subuid" > /dev/null
echo "" | sudo tee "$BUILD_CHROOT/etc/subgid" > /dev/null

# ============================================================
# Fake /proc entries (buildah reads these to determine state)
# ============================================================
log "Creating fake /proc entries..."
sudo mkdir -p "$BUILD_CHROOT/proc/self" "$BUILD_CHROOT/proc/sys/kernel"

# mountinfo: empty (no real mounts in VFS mode)
echo "" | sudo tee "$BUILD_CHROOT/proc/self/mountinfo" > /dev/null

# uid_map / gid_map: pretend full mapping
echo "         0          0 4294967295" | sudo tee "$BUILD_CHROOT/proc/self/uid_map" > /dev/null
echo "         0          0 4294967295" | sudo tee "$BUILD_CHROOT/proc/self/gid_map" > /dev/null

# status: full capabilities (buildah reads CapEff)
printf "CapEff:\tffffffffffffffff\n" | sudo tee "$BUILD_CHROOT/proc/self/status" > /dev/null

# exe: symlink to buildah binary
sudo ln -sf /usr/bin/buildah "$BUILD_CHROOT/proc/self/exe"

# cap_last_cap: kernel capability ceiling
echo 40 | sudo tee "$BUILD_CHROOT/proc/sys/kernel/cap_last_cap" > /dev/null

# cmdline: required by containers/storage C constructor after continue-pipe signal
printf 'buildah\0' | sudo tee "$BUILD_CHROOT/proc/self/cmdline" > /dev/null

# Additional /proc files that buildah or glibc may read
echo "" | sudo tee "$BUILD_CHROOT/proc/filesystems" > /dev/null
echo "" | sudo tee "$BUILD_CHROOT/proc/mounts" > /dev/null

# ============================================================
# Device nodes (buildah RUN steps may access /dev/null etc.)
# ============================================================
log "Creating device nodes..."
sudo mkdir -p "$BUILD_CHROOT/dev"
for dev_spec in "null:1:3" "zero:1:5" "random:1:8" "urandom:1:9"; do
    IFS=: read -r name major minor <<< "$dev_spec"
    sudo mknod "$BUILD_CHROOT/dev/$name" c "$major" "$minor" 2>/dev/null || true
    sudo chmod 666 "$BUILD_CHROOT/dev/$name" 2>/dev/null || true
done

# ============================================================
# DNS resolution
# ============================================================
sudo cp /etc/resolv.conf "$BUILD_CHROOT/etc/resolv.conf"

# ============================================================
# SSL certificates (Fedora uses /etc/pki/tls/certs/)
# ============================================================
sudo cp /etc/ssl/certs/ca-certificates.crt "$BUILD_CHROOT/etc/pki/tls/certs/" 2>/dev/null \
    || sudo cp /etc/ssl/certs/ca-certificates.crt "$BUILD_CHROOT/etc/ssl/certs/" 2>/dev/null \
    || true

# ============================================================
# Registry authentication: the static "auths" of the host's
# $REGISTRY_AUTH_FILE or ~/.docker/config.json (credHelpers are dropped: the
# helper binary is not reachable inside the chroot). Without one, an empty
# auth.json: public pulls need none, and buildah wants the file to exist.
# ============================================================
sudo mkdir -p "$BUILD_CHROOT/run/containers/0"
HOST_AUTH="${REGISTRY_AUTH_FILE:-$HOME/.docker/config.json}"
if [[ -f "$HOST_AUTH" ]] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("auths") else 1)' "$HOST_AUTH" 2>/dev/null; then
    python3 -c 'import json,sys; print(json.dumps({"auths": json.load(open(sys.argv[1]))["auths"]}))' "$HOST_AUTH" \
        | sudo tee "$BUILD_CHROOT/run/containers/0/auth.json" > /dev/null
    sudo chmod 600 "$BUILD_CHROOT/run/containers/0/auth.json"
else
    echo '{"auths":{}}' | sudo tee "$BUILD_CHROOT/run/containers/0/auth.json" > /dev/null
fi

# ============================================================
# Copy build context into chroot
# ============================================================
log "Copying build context..."
sudo mkdir -p "$BUILD_CHROOT/build-context"
tar cf - -C "$CONTEXT" . 2>/dev/null | sudo tar xf - -C "$BUILD_CHROOT/build-context"

# Copy Dockerfile explicitly if it lives outside the context directory
if [[ "$(dirname "$DOCKERFILE")" != "$CONTEXT" ]]; then
    sudo cp "$DOCKERFILE" "$BUILD_CHROOT/build-context/Dockerfile"
    DOCKERFILE_REL="Dockerfile"
else
    DOCKERFILE_REL="$(basename "$DOCKERFILE")"
fi

# ============================================================
# Generate inner build script
# ============================================================
BUILDAH_SD="--storage-driver vfs"
BUD_FLAGS="--isolation chroot --layers"
$VERBOSE && BUD_FLAGS="$BUD_FLAGS --log-level debug"

PUSH_CMD=""
if $PUSH && [[ -n "$DESTINATION" ]]; then
    PUSH_CMD="
echo '==> Pushing to $DESTINATION...'
buildah \$SD push --authfile /run/containers/0/auth.json \\
    --compression-format gzip \\
    '$DESTINATION' 'docker://$DESTINATION'
echo '==> Push complete!'
"
fi

sudo tee "$BUILD_CHROOT/build.sh" > /dev/null << BUILDSCRIPT
#!/bin/sh
set -eu
export HOME=/root
export BUILDAH_ISOLATION=chroot
export _CONTAINERS_USERNS_CONFIGURED=1
export _CONTAINERS_ROOTLESS_UID=1000
export _CONTAINERS_ROOTLESS_GID=1000
export REGISTRY_AUTH_FILE=/run/containers/0/auth.json
SD="$BUILDAH_SD"

echo "==> Building image..."
buildah \$SD bud $BUD_FLAGS \\
    --authfile /run/containers/0/auth.json \\
    --file /build-context/$DOCKERFILE_REL \\
    --tag buildah-restricted-build:latest \\
    ${DESTINATION:+--tag "$DESTINATION"} \\
    /build-context

echo "==> Build complete!"
buildah \$SD images

$PUSH_CMD
BUILDSCRIPT
sudo chmod +x "$BUILD_CHROOT/build.sh"

# ============================================================
# Run buildah bud inside chroot with seccomp filter
# ============================================================
log "Running buildah bud (patched buildah + VFS + chroot isolation + fakemount-simple)..."
echo ""

sudo chroot "$BUILD_CHROOT" \
    /usr/local/bin/fakemount-simple \
    env \
        _CONTAINERS_USERNS_CONFIGURED=1 \
        _CONTAINERS_ROOTLESS_UID=1000 \
        _CONTAINERS_ROOTLESS_GID=1000 \
        BUILDAH_ISOLATION=chroot \
        REGISTRY_AUTH_FILE=/run/containers/0/auth.json \
        HOME=/root \
    /bin/sh /build.sh

echo ""
log "Done!"
