#!/bin/bash
# config.sh — the per-user settings every tool reads. Sourced, not run.
#
# The settings come from three places, first one wins:
#
#   1. the environment (a CI job's `variables:`, the runner's `environment`
#      block, an `export` by hand)
#   2. $SLURM_CI_CONFIG, default ~/.config/slurm-gitlab-ci/config -- KEY=VALUE
#      lines, written by the home-manager module (services.gitlabRunnerSlurm /
#      services.buildkitSlurm) or by hand. It lives on the shared home, so the
#      login node, cron, `ssh frontend cmd` and every compute node read the
#      same file. Values are shell words: `$USER` and `$HOME` expand.
#   3. the defaults below.
#
# Secrets (GITLAB_TOKEN) do NOT go into that file: it is generated, and may be
# world-readable. They go into $SLURM_CI_SECRETS (default
# ~/.config/slurm-gitlab-ci/secrets, mode 600), read by lib/registry.sh only.
#
# Settings:
#
#   BUILDKIT_NODE     the compute node that hosts the BuildKit daemon. Jobs
#                     that build or run images are placed on it, because the
#                     image layers live on its local disk. No default.
#   NODE_LOCAL_DIR    a per-user directory on a node's LOCAL disk, the same
#                     path on every node (default /tmp/$USER). The BuildKit
#                     state, the runner cache and singularity's layer cache
#                     live under it. Prefer a disk that survives reboots.
#   BUILDKIT_ROOT     the BuildKit rootfs + state (default $NODE_LOCAL_DIR/buildkit)
#   SLURM_PARTITION, SLURM_ACCOUNT, SLURM_QOS
#                     passed to salloc/srun/sbatch when set
#   SLURM_EXTRA_ARGS  more salloc arguments for every CI job, word-split
#   GITLAB_URL        the GitLab instance, for tools used outside CI
#                     (CI_SERVER_URL wins inside a job)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: config.sh is a library; source it, don't run it." >&2
    exit 1
fi

slurm_ci_config_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/slurm-gitlab-ci"; }

slurm_ci_load_config() {
    local f="${SLURM_CI_CONFIG:-$(slurm_ci_config_dir)/config}" line key
    [ -r "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # The environment wins: a job's own variables override the file.
        [ -n "${!key+x}" ] && continue
        eval "export $line"
    done < "$f"
}

if [ -z "${_SLURM_CI_CONFIG_LOADED:-}" ]; then
    slurm_ci_load_config
    : "${NODE_LOCAL_DIR:=/tmp/${USER:-$(id -un)}}"
    : "${BUILDKIT_ROOT:=$NODE_LOCAL_DIR/buildkit}"
    export NODE_LOCAL_DIR BUILDKIT_ROOT
    _SLURM_CI_CONFIG_LOADED=1
fi

# require_buildkit_node: exit with a clear message unless BUILDKIT_NODE is set.
require_buildkit_node() {
    if [ -z "${BUILDKIT_NODE:-}" ]; then
        echo "ERROR: BUILDKIT_NODE is not set -- which compute node hosts the BuildKit daemon?" >&2
        echo "       Set services.buildkitSlurm.node (home-manager), or BUILDKIT_NODE=<node> in" >&2
        echo "       ${SLURM_CI_CONFIG:-$(slurm_ci_config_dir)/config}" >&2
        exit 1
    fi
}

# slurm_sched_args: the scheduling arguments every salloc/srun/sbatch of these
# tools passes, one per line (read them with mapfile).
slurm_sched_args() {
    [ -n "${SLURM_PARTITION:-}" ] && printf '%s\n' "--partition=$SLURM_PARTITION"
    [ -n "${SLURM_ACCOUNT:-}" ] && printf '%s\n' "--account=$SLURM_ACCOUNT"
    [ -n "${SLURM_QOS:-}" ] && printf '%s\n' "--qos=$SLURM_QOS"
    return 0
}
