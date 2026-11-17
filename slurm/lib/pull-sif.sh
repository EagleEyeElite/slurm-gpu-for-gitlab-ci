#!/bin/bash
# pull-sif.sh <out.sif> <docker://image:tag> -- `singularity pull` that leaves
# no temp dirs behind on the compute node.
#
# Runs ON a compute node; bin/slurm-sif decides where and calls it, so no
# service repository has to carry cluster mechanics.
#
# singularity unpacks the image into $SINGULARITY_TMPDIR/build-temp-* and
# bundle-temp-* and removes them itself -- unless the job is cancelled or hits
# its time limit. Then they stay, many GB of them, for good. So:
#
#   * a temp dir per SLURM job, /tmp/$USER/singularity/job-<id>, removed on exit;
#   * on TERM (scancel, time limit) the pull's whole process group is stopped
#     and waited for BEFORE the rm -- deleting while singularity still extracts
#     fails with "Directory not empty";
#   * mksquashfs ignores TERM for longer than SLURM's KillWait (30 s), so the
#     group gets KILL after 10 s; were the script itself SIGKILLed, no trap
#     runs -- the next pull on the node removes dirs of jobs SLURM no longer knows.
#
# Tested by cancelling while fetching, while extracting and while creating
# the SIF, plus a full pull -- no leftovers in any case.
#
# The layer cache is ON, and cleans itself with singularity's own
# `cache clean` on every pull (no cron needed: the cache
# only grows when something pulls):
#
#   * it lives on the node's local disk, $NODE_LOCAL_DIR/singularity-cache
#     (singularity itself appends /cache to SINGULARITY_CACHEDIR) --
#     with a cache, singularity writes every SIF twice (cache, then $out), and
#     on an NFS home that is the slow part; a node re-pulls only the layers
#     it has not seen;
#   * entries older than $SIF_CACHE_DAYS (default 14) days go, all types;
#   * oci-tmp -- a full copy of every SIF, the same bytes as $out, which this
#     script reuses anyway -- goes after one day (not at once: a concurrent
#     pull of the same image may still be copying from it);
#   * the same rules run over singularity's default cache on the home,
#     ~/.singularity/cache, which otherwise only ever grows.
#
# The file is reused if it exists (singularity refuses to overwrite one).
# Registry credentials come from the environment (SINGULARITY_DOCKER_USERNAME /
# _PASSWORD), as before.
set -uo pipefail
# shellcheck source=config.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/config.sh"
out="${1:?usage: pull-sif.sh <out.sif> <docker://image:tag>}"
ref="${2:?usage: pull-sif.sh <out.sif> <docker://image:tag>}"

if [ -f "$out" ]; then
  echo "==> $(basename "$out") already present"
  exit 0
fi

base="/tmp/${USER:-$(id -un)}/singularity"
if [ -n "${SLURM_JOB_ID:-}" ]; then tmp="$base/job-$SLURM_JOB_ID"; else tmp="$base/pid-$$"; fi
mkdir -p "$base"

# Dirs of jobs SLURM no longer knows were left by a hard kill.
for d in "$base"/job-*/; do
  [ -d "$d" ] || continue
  j="$(basename "$d")"; j="${j#job-}"
  [ "$j" = "${SLURM_JOB_ID:-}" ] && continue
  squeue -h -j "$j" -o %i 2>/dev/null | grep -q . || rm -rf "$d"
done
# Leftovers of the shared-TMPDIR layout used before this script, a day old.
find "$base" -maxdepth 1 -mindepth 1 \( -name 'build-temp-*' -o -name 'bundle-temp-*' \) \
  -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

export SINGULARITY_TMPDIR="$tmp"
if [ -z "${SINGULARITY_CACHEDIR:-}" ]; then
  if mkdir -p "$NODE_LOCAL_DIR" 2>/dev/null; then SINGULARITY_CACHEDIR="$NODE_LOCAL_DIR/singularity-cache"
  else SINGULARITY_CACHEDIR="$HOME/.singularity"; fi
fi
export SINGULARITY_CACHEDIR
mkdir -p "$SINGULARITY_TMPDIR" "$SINGULARITY_CACHEDIR" "$(dirname "$out")"

days="${SIF_CACHE_DAYS:-14}"
for c in "$SINGULARITY_CACHEDIR" "$HOME/.singularity"; do
  [ -d "$c" ] || continue
  SINGULARITY_CACHEDIR="$c" singularity cache clean --force --days "$days" >/dev/null 2>&1 || true
  SINGULARITY_CACHEDIR="$c" singularity cache clean --force --type oci-tmp --days 1 >/dev/null 2>&1 || true
done

pgid=
cleanup() {
  if [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null
    for _ in $(seq 10); do kill -0 -- "-$pgid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$pgid" 2>/dev/null
    wait 2>/dev/null
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

echo "==> pulling $(basename "$out") from ${ref#docker://}"
# setsid: its own process group, so cleanup() reaches mksquashfs as well.
# </dev/null: under `bash -s` stdin is this script itself.
setsid singularity pull "$out" "$ref" </dev/null &
pgid=$!
wait "$pgid"; rc=$?
pgid=
exit "$rc"
