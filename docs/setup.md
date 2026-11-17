# Setup

From nothing to a GitLab runner on your SLURM login node whose jobs build
images and run them on a GPU. Everything runs as **your** user; nothing needs
root -- but the compute node that hosts BuildKit needs a few things only an
admin can enable. Check [admin-requirements.md](admin-requirements.md) first.

## 1. Install

On the login node:

```bash
git clone https://github.com/EagleEyeElite/slurm-gpu-for-gitlab-ci.git ~/slurm-gpu-for-gitlab-ci
bash ~/slurm-gpu-for-gitlab-ci/bootstrap/install.sh
```

[`bootstrap/install.sh`](../bootstrap/install.sh) uses the system nix if
there is one, and otherwise installs
[nix-portable](https://github.com/DavHau/nix-portable) into `~/bin` (no root,
the store lives in `~/.nix-portable`). It then installs home-manager and
switches to the `slurm-frontend` configuration of this flake, for `$USER` and
`$HOME` as they are at switch time.

That installs `gitlab-runner`, the `slurm-*` tools with their `~/bin` shims,
and `~/bin/hm-switch`, and **starts nothing**.

Under nix-portable, the programs in `~/.nix-profile/bin` run only inside its
wrap: `~/bin/np-shell` opens a shell there (for `gitlab-runner register`,
`glab`, ...). The `~/bin/slurm-*` shims and the runner do not need it.

## 2. Your settings

The install created `~/.config/slurm-gitlab-ci/local.nix` from
[`local.example.nix`](../local.example.nix). It is a home-manager module, kept
outside the checkout. Set at least:

```nix
{
  services.slurmCi = {
    gitlabUrl = "https://gitlab.example.org";
    nodeLocalDir = "/scratch/local/$USER";   # a node-local disk, not NFS
    partition = "gpu";                       # if your cluster needs one
  };
  services.buildkitSlurm = {
    enable = true;
    node = "gpu-node-01";                    # the node that hosts BuildKit
  };
}
```

and run `hm-switch`. With `services.buildkitSlurm.enable` the switch seeds
the BuildKit rootfs on that node (`~/bin/bootstrap-buildkit-rootfs`, a few
minutes the first time) and submits the daemon's sbatch. Check it:

```bash
squeue --me -n buildkitd-gpu-node-01     # one RUNNING job
```

The switch writes the settings to `~/.config/slurm-gitlab-ci/config`, which
every tool reads; [operator.md](operator.md#configuration) lists them all.

## 3. Register a runner

In GitLab: the group's or project's **Settings → CI/CD → Runners → New
runner**. Tags: `slurm` (what jobs select with `tags: [slurm]`); leave "run
untagged jobs" off. Copy the `glrt-…` token (it is shown once), then:

```bash
np-shell        # under nix-portable; with a system nix, just a shell
gitlab-runner register --url https://gitlab.example.org --token glrt-...
# executor: shell
```

and `hm-switch` again: it patches `~/.gitlab-runner/config.toml` -- the job
environment (PATH), the `pre_build_script` that reserves the SLURM
allocation, `concurrent` and `request_concurrency`. Without that patch the
jobs fail with "SLURM_PIPELINE_ALLOC is not set".

More registrations (other groups, other projects) go into the same daemon:
[operator.md](operator.md#registering-runners).

## 4. Start the runner

```nix
services.gitlabRunnerSlurm.enable = true;
```

in `local.nix`, `hm-switch`. It writes the systemd **user** unit
`gitlab-runner.service`, enables and starts it, and enables linger so it
comes back after a reboot without a login.

```bash
systemctl --user status gitlab-runner
```

## 5. Cron

`/usr/bin/crontab` is setuid and fails inside nix-portable's wrap, so this is
the one step home-manager cannot do. In a plain shell on the login node:

```bash
crontab -e
# add:
*/5 * * * * $HOME/bin/buildkitd-keepalive >>$HOME/.local/share/buildkitd-sbatch/cron.log 2>&1
*/5 * * * * $HOME/bin/gitlab-runner-keepalive >>$HOME/logs/gitlab-runner/keepalive-cron.log 2>&1
```

The first renews the BuildKit daemon (a SLURM job with a time limit, so
linger cannot keep it); the second is the reboot backstop of the runner. The
shims always run the current generation, so the lines never change.

## 6. First pipeline

In a project the runner serves, a `.gitlab-ci.yml`:

```yaml
ship:
  tags: [slurm]
  variables:
    SLURM_GPUS: "1"
  script:
    - slurm-build          # BuildKit solve on the daemon
    - slurm-run            # run the image on a GPU (singularity --nv)
    - slurm-build --push   # push to the project's registry
```

with a Dockerfile next to it; [`examples/cuda-smoke`](../examples/cuda-smoke)
is a CUDA check. The variables, the tools and the image-build template are in
[consumer-api.md](consumer-api.md).

## Without nix

The tools are bash and python over system tools; nix only installs and wires
them. By hand: copy `slurm/` to the shared home, write
`~/.config/slurm-gitlab-ci/config` ([operator.md](operator.md#configuration)),
set `SLURM_CI_NIX_PORTABLE=0`, compile `slurm/fakemount.c` statically (`cc
-static -O2 -o slurm/fakemount slurm/fakemount.c`), put a `buildkitd.toml`
next to `buildkitd-sbatch.sh`, and set the runner's `pre_build_script` to
`eval "$(<copy>/bin/slurm-allocate)"` and its `environment` PATH to include
`<copy>/bin`. The home-manager module
([`nix/modules/slurm-runner.nix`](../nix/modules/slurm-runner.nix)) is the
reference for each step.

## In your own flake

The modules are exported, so an existing home-manager configuration can
import them instead of using this flake's `homeConfigurations`:

```nix
{
  inputs.slurm-ci.url = "github:EagleEyeElite/slurm-gpu-for-gitlab-ci";
  # ...
  modules = [
    inputs.slurm-ci.homeManagerModules.slurm-runner
    { services.slurmCi.gitlabUrl = "https://gitlab.example.org"; }
  ];
}
```

`homeManagerModules.restricted-builders` is the kaniko/buildah side
([builders/kaniko.md](builders/kaniko.md)).
