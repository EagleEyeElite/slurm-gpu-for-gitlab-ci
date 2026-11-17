# buildah-build: cached image builds for restricted environments

Build OCI/Docker images where you **do not have enough privileges** for
Docker, podman or rootless BuildKit: a pod on Kubernetes/OpenShift (a
JupyterHub notebook, an IDE container) without `CAP_SYS_ADMIN`, user
namespaces, `/dev/fuse` or real mount support -- but with `sudo`. Unlike
[kaniko-build](kaniko.md) it keeps a layer cache between builds.

On a SLURM cluster with the permissions in
[admin-requirements.md](../admin-requirements.md), use the runner's
BuildKit (`slurm-build`) instead: it is much faster.

## Install

Through nix: the `restricted-pod` configuration of this flake
(`bootstrap/install.sh restricted-pod`), or
`homeManagerModules.restricted-builders` with
`programs.restrictedBuilders.enable = true`, puts `buildah-build` on PATH.
It builds the patched buildah from source on the first switch (pure Go, about
2 minutes; no binary cache has it) and the two static C helpers next to it,
and fetches the buildah rootfs from quay.io with `crane` on the first build.
Nothing to compile or download by hand.

`buildah-build` is `builders/buildah/buildah-build.sh` with those paths
filled in; the options below are the same.

## Quick Start

```bash
# Full build (deps changed, ~10min — VFS storage is slow for 6GB+ images):
buildah-build -f Dockerfile -c .

# Build and push:
buildah-build -f Dockerfile -c . \
    -d registry.example.org/my-group/my-image:latest --push

# Export to udocker after build:
buildah-build -f Dockerfile -c .
# then inside chroot: buildah push my-image:latest docker-archive:/tmp/image.tar
udocker load -i /tmp/image.tar
udocker create --name=myapp docker.io/library/my-image:latest
udocker setup --nvidia myapp
udocker run --workdir=/usr/src/app myapp /usr/src/app/.venv/bin/python -m example_package.main

# Verbose mode:
buildah-build -f Dockerfile -c . -v
```

## Architecture Overview

```
restricted pod (no CAP_SYS_ADMIN, no userns, AppArmor blocks mount)
  |
  sudo chroot /tmp/buildah-restricted-persistent
    |
    fakemount-simple (seccomp BPF filter)
      |
      env _CONTAINERS_USERNS_CONFIGURED=1 ...
        |
        buildah bud --isolation chroot --storage-driver vfs
```

Two components make this work:

1. **fakemount-simple** -- a ~30-line seccomp BPF filter that fakes 4 syscalls
2. **Patched buildah v1.41.5** -- compiled from source with 5 patches in 4 files

Together they let buildah run `bud` (build-using-dockerfile) with chroot isolation
and VFS storage, which needs no kernel mount support at all.

## Component 1: fakemount-simple Seccomp Filter

Source: `builders/buildah/fakemount-simple.c` (compiled to `builders/buildah/fakemount-simple`).

A minimal BPF filter installed via `prctl(PR_SET_SECCOMP)`. It intercepts 4
syscalls before they reach the kernel:

| Syscall | Number | Action | Why |
|---------|--------|--------|-----|
| `mount()` | 165 | Returns 0 (fake success) | Buildah calls mount for propagation, bind mounts, tmpfs, proc -- all faked |
| `umount2()` | 166 | Returns 0 (fake success) | Cleanup calls that would fail without prior real mounts |
| `pivot_root()` | 155 | Returns ENOSYS | Triggers buildah's chroot fallback path (chroot instead of pivot_root) |
| `unshare()` | 272 | Returns 0 (fake success) | Buildah tries to create mount/PID namespaces -- faked to no-op |

The filter runs as a wrapper: `fakemount-simple buildah bud ...`. It applies to
the process and all descendants (seccomp filters are inherited across fork/exec).

## Component 2: Patched Buildah v1.41.5

Stored at: `~/.local/share/buildah-builder/buildah-patched`

Standard buildah assumes it can actually mount things and then verify the mounts
succeeded. Since fakemount returns success without doing anything, buildah's
verification steps would fail. Five patches fix this:

### Patch 1: `chroot/run_linux.go` -- makeReadOnly() non-fatal

```go
// Before: fatal error when mount verification fails
// After:  debug warning, continues execution
```

The `makeReadOnly()` function tries to remount paths as read-only and then
verifies via `/proc/self/mountinfo`. With faked mounts, mountinfo is empty, so
verification always fails. Changed from fatal to debug warning.

### Patch 2: `chroot/run_linux.go` -- readonlyPaths/maskedPaths non-fatal

```go
// Before: fatal error when readonly/masked path setup fails
// After:  debug warning, continues execution
```

Similar to patch 1. Buildah tries to set up readonly and masked paths for
container security, then verifies. Verification fails with faked mounts.

### Patch 3: `chroot/run_linux.go` -- setCapabilities() non-fatal

```go
// Before: returns error when reading /proc/self/status fails
// After:  returns nil, continues with default capabilities
```

`setCapabilities()` reads `/proc/self/status` to determine the current capability
set. In the VFS chroot, the fake `/proc/self/status` may not have all fields.
Changed to return nil on error instead of failing.

### Patch 4: `bind/mount.go` -- VFS layer path preservation

```go
// Before: after "bind mount" to staging dir, uses staging dir path
// After:  detects empty staging dir (faked mount), keeps original VFS layer path
```

When buildah prepares a container's rootfs, it bind-mounts VFS layer directories
into a staging area. With faked mounts, the staging area remains empty. This patch
detects the empty staging directory and falls back to using the original VFS layer
path directly.

### Patch 5: `vendor/.../unshare/unshare.c` -- disable containers_reexec()

```go
// Before: calls fexecve() on memfd to re-exec in new user namespace
// After:  returns immediately (reexec disabled)
```

The containers/storage library tries to re-exec the process inside a new user
namespace using `fexecve()` on a memfd. This fails without CAP_SYS_ADMIN.
Disabled entirely since we set `_CONTAINERS_USERNS_CONFIGURED=1` to skip the
userns path.

### Patch 6: `chroot/run_common.go` -- minimal /proc and /dev in chroot

```go
// After chrooting into the VFS layer for RUN steps, creates:
//   /proc/self/maps  (empty -- satisfies glibc's dl_iterate_phdr)
//   /dev/null, /dev/zero, /dev/urandom, /dev/random (device nodes)
```

When buildah chroots into the VFS layer to execute RUN steps, there is no /proc
or /dev. Glibc's dynamic linker reads `/proc/self/maps` during startup. This
patch creates the minimal set of files/devices needed.

## Build Flow

The script (`builders/buildah/buildah-build.sh`) does the following:

1. **Extract buildah chroot** from `~/.local/share/buildah-builder/chroot-clean.tar`
   to `/tmp/buildah-restricted-persistent` (Fedora-based, ~546MB) -- once; later
   builds reuse it, and with it the VFS layer cache

2. **Install patched buildah** binary to `/usr/bin/buildah` inside chroot

3. **Install fakemount-simple** binary to `/usr/local/bin/fakemount-simple` inside chroot

4. **Configure container tooling**:
   - `storage.conf` -- VFS driver, standard graph/run roots
   - `registries.conf` -- docker.io, through `DOCKER_HUB_MIRROR` if set
   - `policy.json` -- accept all images
   - `containers.conf` -- disable capabilities, cgroupfs manager
   - Empty `subuid`/`subgid` -- prevent userns lookups

5. **Create fake /proc entries** (buildah reads these during initialization):
   - `/proc/self/mountinfo` -- empty (no mounts)
   - `/proc/self/uid_map` -- full mapping `0 0 4294967295`
   - `/proc/self/gid_map` -- full mapping `0 0 4294967295`
   - `/proc/self/status` -- `CapEff: ffffffffffffffff` (all capabilities)
   - `/proc/self/exe` -- symlink to `/usr/bin/buildah`
   - `/proc/self/cmdline` -- `buildah\0`
   - `/proc/sys/kernel/cap_last_cap` -- `40`
   - `/proc/filesystems` -- empty
   - `/proc/mounts` -- empty

6. **Create device nodes**: `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`

7. **Copy build context** into chroot at `/build-context/`

8. **Run the build**:
   ```
   sudo chroot <chroot> fakemount-simple env \
       _CONTAINERS_USERNS_CONFIGURED=1 \
       _CONTAINERS_ROOTLESS_UID=1000 \
       _CONTAINERS_ROOTLESS_GID=1000 \
       BUILDAH_ISOLATION=chroot \
       REGISTRY_AUTH_FILE=/run/containers/0/auth.json \
       HOME=/root \
       /bin/sh /build.sh
   ```

9. **Keep the chroot** for the next build. `sudo rm -rf
   /tmp/buildah-restricted-persistent` starts from scratch (and drops the cache).

## Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `_CONTAINERS_USERNS_CONFIGURED=1` | `1` | Prevents buildah from trying to create user namespaces |
| `_CONTAINERS_ROOTLESS_UID=1000` | `1000` | Tells buildah to use rootless storage paths |
| `_CONTAINERS_ROOTLESS_GID=1000` | `1000` | Tells buildah to use rootless GID paths |
| `BUILDAH_ISOLATION=chroot` | `chroot` | Uses chroot isolation (not OCI/runc) |
| `REGISTRY_AUTH_FILE` | `/run/containers/0/auth.json` | Registry credentials location |
| `HOME=/root` | `/root` | Home directory inside chroot |

## Files

| File | Purpose |
|------|---------|
| `builders/buildah/buildah-build.sh` | The build script |
| `builders/buildah/fakemount-simple.c` | Seccomp BPF filter source (~30 lines) |
| `builders/buildah/buildah-wrap.c` | HOME for buildah's re-exec |
| `builders/buildah/buildah-restricted.patch`, `buildah-restricted-nocgo.patch` | The patches to buildah v1.41.5 |
| `nix/modules/restricted-builders.nix` | Builds the patched buildah and the helpers, installs `buildah-build` |
| `~/.local/share/buildah-builder/chroot-clean.tar` | Fedora buildah rootfs (546MB), fetched on first build |
| `~/.local/share/buildah-builder/buildah-patched` | Hand-built binary, used only by the bare script without nix |

## Prerequisites

### Required capabilities (via sudo)

- `CAP_SYS_CHROOT` -- for `sudo chroot`
- `CAP_MKNOD` -- for creating `/dev/null` etc. in the chroot

The pod itself does NOT need CAP_SYS_ADMIN. All privileged operations
go through sudo, which provides chroot and mknod. The seccomp filter handles
everything else by faking the syscalls.

### Software

- **gcc** -- compiles `fakemount-simple.c` and `buildah-wrap.c` on first run (static binaries, done once)
- **sudo** -- passwordless (`sudo -n true` must succeed)
- **crane** -- anonymous pulls of `quay.io/buildah/stable` for the one-time chroot tarball

Public images pull without credentials. `DOCKER_HUB_MIRROR=host[:port]`
(`programs.restrictedBuilders.dockerHubMirror`) routes Docker Hub pulls
through a pull-through cache, against its rate limit.

### Without nix: one-time manual setup

The two sections below are what the nix module does for you. They are only
needed to run `buildah-build.sh` directly.

### One-time setup: buildah chroot tarball

The chroot tarball (`~/.local/share/buildah-builder/chroot-clean.tar`) contains a
Fedora-based rootfs with buildah v1.41.5 and all its C library dependencies
(libgpgme, libseccomp, libsqlite3, etc.). It provides the runtime environment
for the patched buildah binary.

The image is public on Quay, so `crane` can extract it anonymously — no
credentials required:

```bash
mkdir -p ~/.local/share/buildah-builder
TMPDIR=$(mktemp -d)

crane export quay.io/buildah/stable:v1.41.5 - | tar xf - -C "$TMPDIR"

# Add host SSL certs so pulls inside the chroot validate TLS
cp /etc/ssl/certs/ca-certificates.crt "$TMPDIR/etc/pki/tls/certs/" 2>/dev/null || \
    cp /etc/ssl/certs/ca-certificates.crt "$TMPDIR/etc/ssl/certs/" 2>/dev/null || true

sudo tar cf ~/.local/share/buildah-builder/chroot-clean.tar -C "$TMPDIR" .
rm -rf "$TMPDIR"
```

`skopeo copy docker://quay.io/buildah/stable:v1.41.5 dir:$TMPDIR` is an
equivalent alternative if `crane` is unavailable.

### One-time setup: patched buildah binary

The patched binary (`~/.local/share/buildah-builder/buildah-patched`) must be
compiled from the buildah v1.41.5 source with the patches in `buildah-restricted.patch`.
Requires a Go toolchain (go 1.21+).

```bash
# Install Go (if not available):
curl -sSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz | tar xz -C /tmp
export PATH=/tmp/go/bin:$PATH

# Clone buildah source:
git clone --branch v1.41.5 --depth 1 https://github.com/containers/buildah /tmp/buildah-src
cd /tmp/buildah-src

# Apply all patches at once:
git apply /path/to/builders/buildah/buildah-restricted.patch

# Compile (build tags avoid C library dependencies for gpgme/btrfs/devicemapper):
make buildah BUILDTAGS="containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper"

# Install:
mkdir -p ~/.local/share/buildah-builder
cp bin/buildah ~/.local/share/buildah-builder/buildah-patched
```

## Comparison with the SLURM runner's BuildKit

| Aspect | buildah-build (this) | SLURM CI (BuildKit) |
|--------|-------------------|---------------------|
| User namespaces | Not available | Required on the BuildKit node (`newuidmap`, subuid range) |
| Mount syscall | Blocked (AppArmor) | Real inside the user namespace; propagation changes faked |
| Storage driver | VFS | overlayfs snapshotter |
| Seccomp filter | fakemount-simple (fakes ALL mounts) | fakemount (fakes propagation only) |
| Builder binary | Patched buildah (non-fatal errors) | Stock `buildkitd` (`moby/buildkit`), one shared daemon |
| Isolation | `sudo chroot` | user + mount namespace + `pivot_root` into the BuildKit rootfs |
| Build cache | VFS in `/tmp/buildah-restricted-persistent` (lost on pod restart) | `$NODE_LOCAL_DIR/buildkit` on the node (survives reboots, GC-limited) |
| Warm cache build | ~10 min (VFS hashes all 6GB) | ~9s (code-only change) |
| Full rebuild | ~10 min | ~100s build + ~72s push |

## Development Workflow

### Why is VFS slow?

VFS storage copies the **entire layer tree** for each Dockerfile step — even
cached ones require a full hash comparison. For a 6.5GB PyTorch+CUDA image,
this means ~65GB of I/O per warm-cache build. Overlay storage (BuildKit's
overlayfs snapshotter on SLURM) only tracks diffs, making cache checks instant.

We can't use overlay storage in such a pod because:
- Real overlayfs needs `mount()` → blocked by AppArmor
- fuse-overlayfs needs `/dev/fuse` → blocked by device cgroup

### Recommended workflow

**For code-only changes (the common case):** Use udocker volume mounts — no
rebuild needed at all:

```bash
# Run with local code mounted directly (23s, GPU works):
udocker run \
    --workdir=/usr/src/app \
    --volume="$(pwd)/src/example_package:/usr/src/app/example_package" \
    myapp \
    /usr/src/app/.venv/bin/python -m example_package.main
```

**For dependency changes (pyproject.toml, uv.lock):** Full rebuild required:

```bash
buildah-build -f Dockerfile -c .
# Export and reload udocker container (see Quick Start)
```

**For CI/CD:** Use the SLURM runner's BuildKit (`slurm-build`,
[consumer-api.md](../consumer-api.md)), which has ~10s warm-cache builds via
overlay storage.

### Performance summary

| Scenario | Approach | Time |
|---|---|---|
| Code change (daily dev) | `udocker run --volume=src:/app/src` | **23s** (no rebuild) |
| Dependency change | `buildah bud` (full rebuild) | **~10 min** |
| CI/CD (SLURM) | BuildKit (overlayfs cache) | **~9s** code-only, **~23s** dependency change (+ push) |

## Troubleshooting

### "Error: buildah-patched not found"

Compile the patched buildah binary and place it at
`~/.local/share/buildah-builder/buildah-patched`. See the one-time setup section.

### "Error: chroot-clean.tar not found"

Extract the buildah rootfs. On a machine with user namespaces:
```bash
crane export quay.io/buildah/stable:v1.41.5 - | \
    gzip > ~/.local/share/buildah-builder/chroot-clean.tar
```

### Build hangs or crashes with goroutine dump

Likely a corrupted VFS storage in the persistent chroot: remove it
(`sudo rm -rf /tmp/buildah-restricted-persistent`) and build again. If it
persists, check that the Dockerfile commands succeed in a normal Docker build
first.

### "EPERM" or "Operation not permitted" during RUN steps

The patched buildah's chroot fallback may be failing. Check:
1. Is the fakemount-simple binary installed in the chroot?
2. Is the patched buildah binary (not stock) being used?
3. Run with `-v` for debug output.

### "glibc: cannot open /proc/self/maps"

Patch 6 (run_common.go) should create this file. If you see this error, the
patched buildah binary may not include all patches. Rebuild it.

### Push fails with authentication error

Pushes use the static `auths` of `$REGISTRY_AUTH_FILE` or
`~/.docker/config.json`, copied into the chroot as
`/run/containers/0/auth.json`. `credHelpers` are not used (the helper binary
is not reachable inside the chroot): add a static entry for the registry.

### NFS root_squash issues

The build chroot is on `/tmp` (overlay filesystem, local storage), not NFS.
However, the `buildah-patched` binary is stored on NFS (`~/.local/share/`).
The script copies it into the chroot before running, so root_squash does not
affect execution.
