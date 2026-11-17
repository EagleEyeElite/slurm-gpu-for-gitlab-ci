#!/bin/bash
#
# kaniko-build.sh - Build Docker images locally using kaniko + sudo chroot
#
# For environments without enough privileges for Docker or podman -- a
# notebook/IDE container (JupyterHub, Coder, ...) with no daemon, no user
# namespaces and no CAP_SYS_ADMIN -- where sudo (chroot) still works.
# Kaniko runs inside an isolated chroot with a disposable rootfs.
#
# Docker Hub pulls go through DOCKER_HUB_MIRROR if it is set (host[:port] of
# a pull-through cache, e.g. to avoid Docker Hub's rate limits); otherwise
# straight to Docker Hub.
#
# Prerequisites:
#   - sudo access
#
# Usage:
#   ./kaniko-build.sh [options]
#
# Options:
#   -f, --dockerfile PATH   Path to Dockerfile (default: ./Dockerfile)
#   -c, --context PATH      Build context directory (default: current directory)
#   -o, --output PATH       Output tar path (default: ./image.tar)
#   -d, --destination TAG   Image tag/destination (for registry push)
#   --no-push               Don't push, just build tar (default)
#   --push                  Push to registry
#   --cache                 Enable kaniko layer caching (local filesystem)
#   --cache-dir PATH        Cache directory (default: /tmp/kaniko-cache, implies --cache)
#   -v, --verbose           Verbose output
#   -h, --help              Show this help
#

set -euo pipefail

# --- Configuration ---
KANIKO_DATA_DIR="$HOME/.local/share/kaniko"
KANIKO_CLEAN_TAR="$KANIKO_DATA_DIR/rootfs-clean.tar"
KANIKO_IMAGE_REPO="kaniko-build/dist/chainguard-dev-kaniko/executor"
KANIKO_IMAGE_TAG="v1.25.5-debug"
KANIKO_REGISTRY="https://ghcr.io"
DOCKER_HUB_MIRROR="${DOCKER_HUB_MIRROR:-}"

# --- Defaults ---
DOCKERFILE="Dockerfile"
CONTEXT="."
OUTPUT="image.tar"
DESTINATION=""
NO_PUSH=true
VERBOSITY="info"
CACHE_ENABLED=false
CACHE_DIR=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--dockerfile) DOCKERFILE="$2"; shift 2 ;;
        -c|--context) CONTEXT="$2"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        -d|--destination) DESTINATION="$2"; NO_PUSH=false; shift 2 ;;
        --no-push) NO_PUSH=true; shift ;;
        --push) NO_PUSH=false; shift ;;
        --cache) CACHE_ENABLED=true; shift ;;
        --cache-dir) CACHE_DIR="$2"; CACHE_ENABLED=true; shift 2 ;;
        -v|--verbose) VERBOSITY="debug"; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Resolve absolute paths ---
CONTEXT="$(cd "$CONTEXT" && pwd)"
if [[ ! "$DOCKERFILE" = /* ]]; then
    DOCKERFILE="${CONTEXT}/${DOCKERFILE}"
fi
if [[ ! "$OUTPUT" = /* ]]; then
    OUTPUT="$(pwd)/${OUTPUT}"
fi

# --- Check prerequisites ---
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo access is required"
    exit 1
fi

if [[ ! -f "$DOCKERFILE" ]]; then
    echo "Error: Dockerfile not found at $DOCKERFILE"
    exit 1
fi

# --- Setup kaniko (first-time: download and create clean rootfs tar) ---
setup_kaniko() {
    echo "Setting up kaniko (first-time only)..."
    mkdir -p "$KANIKO_DATA_DIR"

    # Get anonymous token from ghcr.io (kaniko executor is public)
    local scope="repository:${KANIKO_IMAGE_REPO}:pull"
    local jwt_response
    jwt_response=$(curl -sS "${KANIKO_REGISTRY}/token?scope=${scope}")
    if [[ -z "$jwt_response" ]]; then
        echo "Error: Empty response from ghcr.io token endpoint" >&2
        exit 1
    fi
    local jwt
    jwt=$(echo "$jwt_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('Error: Invalid JSON from ghcr.io token endpoint', file=sys.stderr)
    sys.exit(1)
if 'token' not in data:
    msg = data.get('error', data.get('message', str(data)))
    print(f'Error: Token request failed: {msg}', file=sys.stderr)
    sys.exit(1)
print(data['token'])
")

    # Get manifest and extract layer digests (handles multi-arch manifest lists)
    local manifest
    manifest=$(curl -sS -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
        "${KANIKO_REGISTRY}/v2/${KANIKO_IMAGE_REPO}/manifests/${KANIKO_IMAGE_TAG}")
    if [[ -z "$manifest" ]]; then
        echo "Error: Empty response fetching manifest for ${KANIKO_IMAGE_REPO}:${KANIKO_IMAGE_TAG}" >&2
        exit 1
    fi
    local layer_digests
    layer_digests=$(echo "$manifest" | python3 -c "
import sys, json
try:
    m = json.load(sys.stdin)
except json.JSONDecodeError:
    print('Error: Invalid JSON in manifest response', file=sys.stderr)
    sys.exit(1)
if 'errors' in m:
    print(f\"Error: Registry returned: {m['errors'][0].get('message', m['errors'])}\", file=sys.stderr)
    sys.exit(1)
# If manifest list, resolve to amd64 platform digest
if m.get('mediaType') == 'application/vnd.docker.distribution.manifest.list.v2+json':
    for entry in m['manifests']:
        p = entry.get('platform', {})
        if p.get('architecture') == 'amd64' and p.get('os') == 'linux':
            print('RESOLVE:' + entry['digest'])
            break
    else:
        print('Error: no amd64/linux manifest found', file=sys.stderr)
        sys.exit(1)
else:
    for layer in m['layers']:
        print(layer['digest'])
")
    # If we got a manifest list, resolve the platform-specific manifest
    if [[ "$layer_digests" == RESOLVE:* ]]; then
        local platform_digest="${layer_digests#RESOLVE:}"
        echo "  Resolving amd64 manifest: ${platform_digest:7:12}..."
        local platform_manifest
        platform_manifest=$(curl -sS -H "Authorization: Bearer $jwt" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            "${KANIKO_REGISTRY}/v2/${KANIKO_IMAGE_REPO}/manifests/${platform_digest}")
        if [[ -z "$platform_manifest" ]]; then
            echo "Error: Empty response fetching platform manifest ${platform_digest:7:12}" >&2
            exit 1
        fi
        layer_digests=$(echo "$platform_manifest" | python3 -c "
import sys, json
try:
    m = json.load(sys.stdin)
except json.JSONDecodeError:
    print('Error: Invalid JSON in platform manifest', file=sys.stderr)
    sys.exit(1)
for layer in m['layers']:
    print(layer['digest'])
")
    fi

    # Download and extract layers into a temporary rootfs
    local tmpdir
    tmpdir=$(mktemp -d)
    local i=0
    local total
    total=$(echo "$layer_digests" | wc -l)
    while IFS= read -r digest; do
        i=$((i + 1))
        echo "  Downloading layer ${i}/${total}: ${digest:7:12}..."
        curl -sfL -H "Authorization: Bearer $jwt" \
            "${KANIKO_REGISTRY}/v2/${KANIKO_IMAGE_REPO}/blobs/${digest}" \
            | tar xz -C "$tmpdir" 2>/dev/null || true
    done <<< "$layer_digests"

    # Add host SSL certs
    mkdir -p "$tmpdir/kaniko/ssl/certs"
    cp /etc/ssl/certs/ca-certificates.crt "$tmpdir/kaniko/ssl/certs/" 2>/dev/null || true

    # Save clean rootfs as tar
    tar cf "$KANIKO_CLEAN_TAR" -C "$tmpdir" .
    rm -rf "$tmpdir"

    echo "  Kaniko setup complete ($(du -h "$KANIKO_CLEAN_TAR" | cut -f1) rootfs)"
}

if [[ ! -f "$KANIKO_CLEAN_TAR" ]]; then
    setup_kaniko
fi

# --- Create a fresh rootfs for this build ---
# Kaniko modifies / when unpacking base images, so each build needs a clean copy
BUILD_ROOTFS=$(mktemp -d)

cleanup() {
    # Persist cache back to host before destroying the rootfs.
    # kaniko with oci: prefix creates dirs named /tmp/kaniko-cache:<hash>
    # so we sync the parent /tmp and filter for the kaniko-cache* entries.
    if [[ "$CACHE_ENABLED" == true ]]; then
        echo "Saving layer cache to ${CACHE_DIR}*..."
        sudo rsync -a "${BUILD_ROOTFS}/tmp/" "$(dirname "$CACHE_DIR")/" \
            --include="${CACHE_BASENAME}*" --include="${CACHE_BASENAME}*/**" --exclude='*'
    fi
    sudo rm -rf "$BUILD_ROOTFS"
}
trap cleanup EXIT

echo "Preparing build environment..."
sudo tar xf "$KANIKO_CLEAN_TAR" -C "$BUILD_ROOTFS"

# --- Docker config ---
# Public base images pull anonymously, so empty auth is fine for build-only
# runs. For pushes we copy the user's ~/.docker/config.json
# auths into the chroot (credHelpers are stripped — the helper binary isn't
# reachable from inside the chroot, so we rely on the static base64 tokens).
sudo mkdir -p "${BUILD_ROOTFS}/kaniko/.docker"
HOST_DOCKER_CONFIG="${HOME}/.docker/config.json"
if [[ -f "$HOST_DOCKER_CONFIG" ]] && jq -e '.auths // empty' "$HOST_DOCKER_CONFIG" >/dev/null 2>&1; then
    jq '{auths: (.auths // {})}' "$HOST_DOCKER_CONFIG" \
        | sudo tee "${BUILD_ROOTFS}/kaniko/.docker/config.json" > /dev/null
else
    echo '{"auths":{}}' | sudo tee "${BUILD_ROOTFS}/kaniko/.docker/config.json" > /dev/null
fi

# --- Prepare workspace ---
sudo mkdir -p "${BUILD_ROOTFS}/workspace"
echo "Copying build context..."
sudo rsync -a --delete --exclude='.git' "$CONTEXT/" "${BUILD_ROOTFS}/workspace/"
sudo cp "$DOCKERFILE" "${BUILD_ROOTFS}/workspace/Dockerfile.kaniko"

# --- Setup layer cache (copy from host into chroot) ---
if [[ "$CACHE_ENABLED" == true ]]; then
    CACHE_DIR="${CACHE_DIR:-/tmp/kaniko-cache}"
    CACHE_BASENAME=$(basename "$CACHE_DIR")
    # Restore cached layers from previous builds (kaniko-cache:<hash> dirs)
    if ls "$(dirname "$CACHE_DIR")/${CACHE_BASENAME}:"* &>/dev/null; then
        echo "Restoring layer cache from ${CACHE_DIR}*..."
        sudo rsync -a "$(dirname "$CACHE_DIR")/" "${BUILD_ROOTFS}/tmp/" \
            --include="${CACHE_BASENAME}*" --include="${CACHE_BASENAME}*/**" --exclude='*'
    fi
fi

# --- Build kaniko arguments ---
KANIKO_ARGS=(
    --context=/workspace
    --dockerfile=/workspace/Dockerfile.kaniko
    --verbosity="$VERBOSITY"
    --use-new-run
    --compression=zstd
)
[[ -n "$DOCKER_HUB_MIRROR" ]] && KANIKO_ARGS+=(--registry-mirror="$DOCKER_HUB_MIRROR")

if [[ "$CACHE_ENABLED" == true ]]; then
    KANIKO_ARGS+=(--cache=true)
    # oci: prefix writes cache layers to local filesystem instead of a registry
    KANIKO_ARGS+=(--cache-repo=oci:/tmp/kaniko-cache)
fi

if [[ "$NO_PUSH" == true ]]; then
    KANIKO_ARGS+=(--no-push)
    KANIKO_ARGS+=(--tar-path=/workspace/output.tar)
fi

if [[ -n "$DESTINATION" ]]; then
    KANIKO_ARGS+=(--destination="$DESTINATION")
fi

# --- Print build info ---
echo "Building image with kaniko..."
echo "  Context:    $CONTEXT"
echo "  Dockerfile: $DOCKERFILE"
if [[ "$NO_PUSH" == true ]]; then
    echo "  Output:     $OUTPUT"
else
    echo "  Destination: $DESTINATION"
fi
if [[ "$CACHE_ENABLED" == true ]]; then
    echo "  Cache:      $CACHE_DIR"
fi
echo ""

# --- Setup chroot environment ---
# Create fake /proc/self/mountinfo (kaniko needs it but we can't mount proc)
sudo mkdir -p "${BUILD_ROOTFS}/proc/self"
sudo touch "${BUILD_ROOTFS}/proc/self/mountinfo"

# Create device nodes
sudo mkdir -p "${BUILD_ROOTFS}/dev"
sudo mknod "${BUILD_ROOTFS}/dev/null" c 1 3 2>/dev/null || true
sudo chmod 666 "${BUILD_ROOTFS}/dev/null"
sudo mknod "${BUILD_ROOTFS}/dev/zero" c 1 5 2>/dev/null || true
sudo chmod 666 "${BUILD_ROOTFS}/dev/zero"
sudo mknod "${BUILD_ROOTFS}/dev/random" c 1 8 2>/dev/null || true
sudo chmod 666 "${BUILD_ROOTFS}/dev/random"
sudo mknod "${BUILD_ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
sudo chmod 666 "${BUILD_ROOTFS}/dev/urandom"

# Copy DNS resolver config
sudo mkdir -p "${BUILD_ROOTFS}/etc"
sudo cp /etc/resolv.conf "${BUILD_ROOTFS}/etc/resolv.conf"

# Create /.dockerenv so kaniko thinks it's inside a container.
# This suppresses the "outside of a container" warning and makes
# --force unnecessary (kaniko only needs --force on bare metal).
sudo touch "${BUILD_ROOTFS}/.dockerenv"

# --- Run kaniko via chroot ---
KANIKO_CMD="SSL_CERT_DIR=/kaniko/ssl/certs DOCKER_CONFIG=/kaniko/.docker/ /kaniko/executor"
for arg in "${KANIKO_ARGS[@]}"; do
    KANIKO_CMD+=" '$arg'"
done

sudo chroot "$BUILD_ROOTFS" /bin/sh -c "$KANIKO_CMD"

# --- Copy output ---
if [[ "$NO_PUSH" == true ]]; then
    # sudo cat to read from root-owned chroot, redirect as current user
    # because NFS root_squash prevents root from writing to home directories
    # shellcheck disable=SC2024  # intentional: redirect must run as non-root
    sudo cat "${BUILD_ROOTFS}/workspace/output.tar" > "$OUTPUT"
    echo ""
    echo "Image built successfully: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
fi
