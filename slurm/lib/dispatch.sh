#!/bin/bash
# dispatch.sh — shared helpers sourced by the bin/slurm-* wrappers and
# bin/ensure-buildkitd-sbatch. Three things, all factored out of what
# used to be 4 near-identical 5-line bodies.
#
# Not directly invokable.
#
#   require_alloc
#       Aborts unless $SLURM_PIPELINE_ALLOC is set. The runner's
#       pre_build_script (eval "$(~/bin/slurm-allocate)") sets it; if
#       it's missing the runner is mis-registered or the wrapper was
#       run outside CI.
#
#   translated_buildkit_dir
#       Echoes the directory the wrapper lives under (parent of bin/),
#       with /nix/store/... rewritten to $HOME/.nix-portable/nix/store/...
#       when nix runs through nix-portable (no /nix/store outside its
#       wrap, so a compute node resolves the inner script via the copy on
#       the shared home). With a real /nix/store that the nodes see too
#       (a system-wide nix install), set SLURM_CI_NIX_PORTABLE=0 and the
#       path is used as it is. Reads $0 of the calling wrapper.
#
#   run_in_alloc <inner-relative-path> "$@"
#       exec srun --jobid=$SLURM_PIPELINE_ALLOC --overlap bash
#       <translated-buildkit-dir>/<inner> "$@". The standard build
#       and run wrappers reduce to "require_alloc; run_in_alloc <s>".
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: dispatch.sh is a library; source it, don't run it." >&2
    exit 1
fi

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

require_alloc() {
    if [[ -z "${SLURM_PIPELINE_ALLOC:-}" ]]; then
        echo "ERROR: SLURM_PIPELINE_ALLOC is not set." >&2
        echo "       The runner pre_build_script must run:  eval \"\$(slurm-allocate)\"" >&2
        exit 1
    fi
}

translated_buildkit_dir() {
    local here dir
    here="$(dirname "$(readlink -f "$0")")"
    dir="$(dirname "$here")"
    case "$dir" in
        /nix/store/*)
            if [[ "${SLURM_CI_NIX_PORTABLE:-1}" != 0 ]]; then
                dir="$HOME/.nix-portable$dir"
            fi
            ;;
    esac
    printf '%s\n' "$dir"
}

run_in_alloc() {
    local inner="$1"; shift
    local dir
    dir="$(translated_buildkit_dir)"
    exec srun --jobid="$SLURM_PIPELINE_ALLOC" --overlap \
        bash "$dir/$inner" "$@"
}
