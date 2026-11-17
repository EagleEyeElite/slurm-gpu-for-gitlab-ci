# kaniko-build: images without Docker, for restricted environments

`kaniko-build` builds images with
[kaniko](https://github.com/GoogleContainerTools/kaniko) where you **do not
have enough privileges** for Docker, podman or rootless BuildKit: a notebook
or IDE container (JupyterHub, Coder, ...) with no container daemon, no user
namespaces and no `CAP_SYS_ADMIN` -- but with `sudo`. It gives kaniko an
isolated rootfs with `sudo chroot`.

On a SLURM cluster with the permissions in
[admin-requirements.md](../admin-requirements.md), use the runner's
BuildKit (`slurm-build`) instead.

Every build starts from a clean rootfs: simple and reproducible, but base
images are downloaded every time. [buildah-build](buildah.md) keeps a layer
cache.

## Install

With nix: the `restricted-pod` configuration of this flake
(`bootstrap/install.sh restricted-pod`), or
`homeManagerModules.restricted-builders` with
`programs.restrictedBuilders.enable = true` in your own. Without nix:
`builders/kaniko/kaniko-build.sh` directly (it needs `curl`, `python3`, `jq`,
`rsync`, `tar`).

Prerequisite: **sudo**.

On first run the script downloads the kaniko executor (~40 MB) anonymously
from ghcr.io (`ghcr.io/kaniko-build/dist/chainguard-dev-kaniko/executor:v1.25.5-debug`)
and keeps it at `~/.local/share/kaniko/rootfs-clean.tar`.

## Quick start

```bash
kaniko-build -o image.tar                 # build the ./Dockerfile into a tar
kaniko-build -o image.tar -v              # verbose
kaniko-build -f Dockerfile.dev -c ../other-project -o other.tar
kaniko-build -d registry.example.org/my/image:latest --push
```

## Options

```
-f, --dockerfile PATH   Path to Dockerfile (default: ./Dockerfile)
-c, --context PATH      Build context directory (default: current directory)
-o, --output PATH       Output tar path (default: ./image.tar)
-d, --destination TAG   Push to registry (e.g. registry.example.org/my/image:tag)
--no-push               Don't push, just build tar (default)
--push                  Push to registry
--cache                 Enable kaniko layer caching (local filesystem)
--cache-dir PATH        Cache directory (default: /tmp/kaniko-cache, implies --cache)
-v, --verbose           Debug output
```

## Registries

- **Pulls** of public images need no credentials.
- **Docker Hub's rate limit**: set `DOCKER_HUB_MIRROR=host[:port]` (or
  `programs.restrictedBuilders.dockerHubMirror`) to a pull-through cache;
  the script then passes `--registry-mirror` to kaniko.
- **Pushes** use the static `auths` of your `~/.docker/config.json` (e.g.
  after `docker login`-equivalents such as `crane auth login` or a
  hand-written entry). `credHelpers` are not used: the helper binary is not
  reachable inside the chroot.

## Layer caching

`--cache` caches each `RUN` layer as an OCI image on the local filesystem,
which avoids re-downloading dependencies on repeat builds.

```bash
kaniko-build --cache -o image.tar
kaniko-build --cache-dir /path/on/local/disk/kaniko-cache -o image.tar
```

The cache is stored as `kaniko-cache:<hash>` directories alongside the cache
path; between builds the script copies cached layers into and out of the
chroot.

Measured with a 3.8 GB PyTorch/CUDA image:

| Build | Scenario | Wall time | Layers cached | Downloads saved |
|-------|----------|-----------|---------------|-----------------|
| 1 | Baseline (cold cache) | ~4m18s | 0 of 4 | none |
| 2 | Rebuild (nothing changed) | ~4m16s | 4 of 4 | ~3GB |
| 3 | Code change only | ~4m13s | 3 of 4 | ~3GB |

Wall time stays about the same: extracting the 3.8 GB cached layer into the
chroot is as slow as downloading it. The gain is **network**: useful when
bandwidth is limited or the package index is slow. With `--push`, kaniko can
stream cached layers without extracting them, so the speedup is larger.

`/tmp` in a container is usually not persistent; put `--cache-dir` on a
volume that survives restarts if you want the cache to.

## How it works

1. A clean kaniko rootfs is extracted from `rootfs-clean.tar` into a temp
   directory (kaniko overwrites `/` when unpacking base images, so each build
   needs a fresh copy).
2. The build context is copied into `/workspace` inside it.
3. `/kaniko/.docker/config.json` gets your static registry auths (or stays
   empty).
4. The chroot gets a fake `/proc/self/mountinfo`, device nodes (`/dev/null`,
   `/dev/zero`, `/dev/random`, `/dev/urandom`), DNS config, and `/.dockerenv`
   (so kaniko knows it is in a container).
5. Kaniko runs via `sudo chroot <rootfs>` with `--use-new-run` (faster
   snapshots) and `--compression=zstd`.
6. The image is saved as a tar or pushed.

## Troubleshooting

**"sudo access is required"** -- the script needs sudo; in some notebook
images sudo is configured per session and resets on restart.

**Slow builds** -- base images are downloaded on every build; use
[buildah-build](buildah.md) for a persistent layer cache.

**"TOOMANYREQUESTS"** -- Docker Hub's anonymous rate limit; set
`DOCKER_HUB_MIRROR`.

**WARNING: never run kaniko with `--force` outside a chroot or container.**
With `--force` kaniko unpacks base image layers over `/`, destroying the host
filesystem. The script never uses `--force`; it creates `/.dockerenv` inside
the chroot instead.
