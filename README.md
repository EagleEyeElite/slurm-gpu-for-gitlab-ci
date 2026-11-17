# slurm-gpu-for-gitlab-ci

GitLab CI/CD on a SLURM cluster: a GitLab runner on the login node whose jobs
run on the compute nodes, build Docker images with a rootless BuildKit, and
run them on GPUs -- all as an ordinary user, no root, no Docker daemon.

```yaml
# .gitlab-ci.yml of any project the runner serves
ship:
  tags: [slurm]
  variables:
    SLURM_GPUS: "1"
  script:
    - slurm-build          # BuildKit build on a compute node, layer cache warm
    - slurm-run            # run the image there on a GPU (singularity --nv)
    - slurm-build --push   # push to the project's container registry
```

A code-only change builds and runs in about 10 seconds.

## How

- **The runner** uses the shell executor on the login node, as a systemd user
  service. Before each job, its `pre_build_script` reserves one SLURM
  allocation with the job's resources (`SLURM_GPUS`, `SLURM_CPUS`,
  `SLURM_MEM`, `SLURM_TIME`) and cancels it when the job ends. Every step
  runs in that allocation.
- **BuildKit** runs as a long SLURM job on one compute node, rootless in a
  user namespace with its cache on the node's local disk; cron renews it.
- **Run** mounts the freshly built layers with fuse-overlayfs and starts them
  with Singularity/Apptainer: no SIF conversion, no push needed to test.
- **Tools** for jobs and for your shell:

  | Tool | What it does |
  |---|---|
  | `slurm-sif <image>` | the image as a SIF on the shared home, pulled on a compute node |
  | `slurm-cache put\|fetch\|publish` | large artifacts between jobs without a GitLab round trip |
  | `package put\|get\|exists` | one file in a project's generic package registry |
  | `slurm-monitor start\|stop` | a job's resource profile (CPU, memory, IO, GPUs of its own cgroup) |
  | `slurm-service` | a command with services from images beside it, in the job's allocation |
  | `slurm-job-local <job>` | one job of a `.gitlab-ci.yml`, run by hand from a working tree |

- **Installation** is a [home-manager](https://github.com/nix-community/home-manager)
  configuration. It uses a system nix, or [nix-portable](https://github.com/DavHau/nix-portable)
  where there is none (no root). The scripts are plain bash and python, so
  you can also use them without nix.

## Requirements

The compute node that hosts BuildKit needs **unprivileged user namespaces, a
subuid/subgid range for your user, FUSE and kernel ≥ 5.11**. On many HPC
clusters some of these are off by default. On the cluster this was built
on, the admins had to grant some of them first.
[docs/admin-requirements.md](docs/admin-requirements.md) lists what to ask
for and how to check it.

## Start

```bash
git clone https://github.com/EagleEyeElite/slurm-gpu-for-gitlab-ci.git ~/slurm-gpu-for-gitlab-ci
bash ~/slurm-gpu-for-gitlab-ci/bootstrap/install.sh
```

then [docs/setup.md](docs/setup.md): your settings, registering a runner,
starting it.

## Documentation

- [docs/setup.md](docs/setup.md) -- install, configure, register, start
- [docs/consumer-api.md](docs/consumer-api.md) -- what a project writes in its `.gitlab-ci.yml`: variables, tools, the image-build template ([`templates/image.yml`](templates/image.yml))
- [docs/operator.md](docs/operator.md) -- configuration reference, the daemons, how it works, troubleshooting
- [docs/admin-requirements.md](docs/admin-requirements.md) -- what the cluster must allow

## Restricted environments: kaniko and buildah

[`builders/`](builders) holds two image builders for environments **without
enough privileges** for any of the above, or for Docker or podman: a notebook
or IDE container (JupyterHub, Coder, ...) with no container daemon, no user
namespaces and no `CAP_SYS_ADMIN`, but with `sudo`.

- **kaniko-build** -- every build starts from a clean rootfs. Simple, but base
  images are downloaded every time. [docs/builders/kaniko.md](docs/builders/kaniko.md)
- **buildah-build** -- a patched buildah with a seccomp filter that fakes the
  mounts. It keeps a layer cache across builds.
  [docs/builders/buildah.md](docs/builders/buildah.md)

`bootstrap/install.sh restricted-pod` installs both, together with
`package`, `slurm-cache` and `slurm-monitor`.

## Layout

```
slurm/              the runner side: slurm-allocate, slurm-build, slurm-run, ... (docs/operator.md#source-tree)
builders/           kaniko-build, buildah-build for restricted environments
nix/modules/        home-manager modules: slurm-runner, restricted-builders, hm-switch
flake.nix           the modules, two ready configurations, the checks
bootstrap/          install.sh: nix (or nix-portable), home-manager, first switch
templates/          image.yml to include: from a project's pipeline
images/slurm-cache/ slurm-cache + package as an image (e.g. a Kubernetes init container)
examples/           cuda-smoke: a CUDA check image
```

## License

[GPL-3.0](LICENSE). The buildah patches in `builders/buildah/` modify
[buildah](https://github.com/containers/buildah) (Apache-2.0).
