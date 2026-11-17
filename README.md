# slurm-gpu-for-gitlab-ci

GitLab CI/CD on a SLURM cluster: build Docker images and run them on GPUs,
as an ordinary user -- no root, no Docker daemon.

```mermaid
flowchart LR
    GL[(GitLab)]

    subgraph FE["SLURM login node"]
        R["gitlab-runner<br/>(shell executor, systemd user service)"]
    end

    %% node 2 first: mermaid stacks sibling subgraphs in reverse order,
    %% so this puts node 1 on top.
    subgraph N2["node 2"]
        J2["CI/CD job<br/>(SLURM_NODE: any)"]
    end
    subgraph BN["node 1 (BuildKit node)"]
        J1["CI/CD job"]
        BK["BuildKit job<br/>(always running, with layer cache)"]:::daemon
    end

    GL -- "CI/CD jobs" --> R
    R -- "salloc per job" --> J1
    R -- "salloc per job" --> J2
    J1 -.- BK

    classDef daemon fill:#555,stroke:#333,color:#fff
    linkStyle 3 stroke:#888,stroke-dasharray:4 4
```

```yaml
# .gitlab-ci.yml
ship:
  tags: [slurm]
  variables:
    SLURM_GPUS: "1"
  script:
    - slurm-build          # build the Dockerfile on BuildKit, cache warm
    - slurm-run            # run the image on a GPU (singularity --nv)
    - slurm-build --push   # push to the project's registry
```

A code-only change builds and runs in about 10 seconds.

## How it works

One CI/CD job, step by step -- each step starts when the one before it is
done:

```mermaid
sequenceDiagram
    participant R as gitlab-runner<br/>(login node)
    participant J as CI/CD job<br/>(node 1)
    participant B as BuildKit job<br/>(node 1, always running)
    participant G as Registry

    R->>J: 1. salloc: reserve the job's GPUs, CPUs, memory
    J->>B: 2. slurm-build: build the Dockerfile
    B-->>J: image layers, on node 1's local disk
    J->>J: 3. slurm-run: mount the layers (fuse-overlayfs),<br/>start the image with singularity --nv
    J->>B: 4. slurm-build --push (all layers cached)
    B->>G: push the image
    J-->>R: job done, allocation released
```

More tools for jobs (`slurm-sif`, `slurm-cache`, `package`,
`slurm-monitor`, `slurm-service`, `slurm-job-local`):
[docs/consumer-api.md](docs/consumer-api.md).

## Requirements

The BuildKit node needs **user namespaces, a subuid/subgid range for your
user, FUSE and Linux ≥ 5.11**. These are often off on HPC clusters. On the
cluster this was built on, the admins had to grant some of them first:
[docs/admin-requirements.md](docs/admin-requirements.md).

## Without enough privileges: kaniko and buildah

For a notebook or IDE container (JupyterHub, Coder, ...) with no container
daemon and no user namespaces, but with `sudo`, [`builders/`](builders) has
`kaniko-build` and `buildah-build`
([kaniko](docs/builders/kaniko.md), [buildah](docs/builders/buildah.md)).
Install with `bootstrap/install.sh restricted-pod`.

## License

[GPL-3.0](LICENSE). The buildah patches in `builders/buildah/` modify
[buildah](https://github.com/containers/buildah) (Apache-2.0).
