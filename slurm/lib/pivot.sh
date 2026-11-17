#!/bin/bash
# lib/pivot.sh — namespaces + pivot_root helper used by both the build
# path (buildkit-slurm-common.sh sources this; buildkit-slurm-build.sh
# calls pivot_and_exec for the per-job inner script) and the daemon
# path (buildkitd-sbatch.sh sources this directly).
#
# Caller contract:
#   - $BUILDKIT_ROOT points at a populated rootfs to pivot into.
#   - $FAKEMOUNT_BIN points at an executable seccomp wrapper that fakes
#     MS_PRIVATE|MS_REC mount calls so unshare can complete. Callers place it
#     under a per-user dir (default below) — /tmp is usually shared 1777
#     across users, so a fixed /tmp/fakemount would collide.
#   - The user has a subordinate uid/gid range (/etc/subuid, /etc/subgid, or
#     whatever `getsubids` reads), and newuidmap/newgidmap are installed.
#     The image's uids 1..N are mapped onto that range. This is the part that
#     needs an administrator once (docs/admin-requirements.md).
#
# Provides:
#   subid_range uid|gid
#       Prints "<start> <count>" of the caller's subordinate range, from
#       $SUBUID_START/$SUBUID_COUNT ($SUBGID_...) if set, else getsubids, else
#       /etc/subuid (/etc/subgid). Prints nothing if there is none.
#
#   id_maps <pid>
#       newuidmap/newgidmap for the user namespace of <pid>: 0 -> the caller,
#       1.. -> the subordinate range. Fails loudly without a range.
#
#   pivot_and_exec [--exec] <post-pivot-bash>
#       Enters user+mount+pid namespaces, pivot_roots into $BUILDKIT_ROOT,
#       mounts /proc /sys cgroup /dev/* /dev/pts /dev/shm, then evaluates
#       the post-pivot bash inside that environment. The argument can be
#       a path to a script that exists inside the pivoted rootfs (which
#       bash will exec), or an inline bash command string.
#
#       --exec wraps the nsenter call in exec, so SIGTERM from the
#       outer shell (e.g. SLURM time-limit on the daemon's sbatch)
#       propagates straight to the leaf process. Use this for the
#       persistent buildkitd; omit for one-shot inner scripts that
#       should let pivot_and_exec clean up the unshare sleeper PID.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: pivot.sh is a library; source it, don't run it." >&2
    exit 1
fi

subid_range() {
    local kind="$1" user uid file flag override_start override_count
    user="${USER:-$(id -un)}"; uid="$(id -u)"
    if [[ "$kind" == uid ]]; then
        file=/etc/subuid flag="" override_start="${SUBUID_START:-}" override_count="${SUBUID_COUNT:-}"
    else
        file=/etc/subgid flag=-g override_start="${SUBGID_START:-}" override_count="${SUBGID_COUNT:-}"
    fi
    if [[ -n "$override_start" && -n "$override_count" ]]; then
        echo "$override_start $override_count"; return 0
    fi
    # getsubids (shadow >= 4.11) also answers for ranges from LDAP/sssd.
    if command -v getsubids >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        getsubids $flag "$user" 2>/dev/null | awk 'NR == 1 && NF >= 4 { print $3, $4; found = 1 } END { exit !found }' && return 0
    fi
    awk -F: -v u="$user" -v id="$uid" '($1 == u || $1 == id) { print $2, $3; exit }' "$file" 2>/dev/null
}

id_maps() {
    local pid="$1" us uc gs gc
    read -r us uc < <(subid_range uid) || true
    read -r gs gc < <(subid_range gid) || true
    if [[ -z "${us:-}" || -z "${gs:-}" ]]; then
        echo "ERROR: no subordinate uid/gid range for ${USER:-$(id -un)} on $(hostname)." >&2
        echo "       An administrator has to add one to /etc/subuid and /etc/subgid" >&2
        echo "       (docs/admin-requirements.md), or set SUBUID_START/SUBUID_COUNT and" >&2
        echo "       SUBGID_START/SUBGID_COUNT to an existing one." >&2
        return 1
    fi
    newuidmap "$pid" 0 "$(id -u)" 1 1 "$us" "$uc"
    newgidmap "$pid" 0 "$(id -g)" 1 1 "$gs" "$gc"
}

pivot_and_exec() {
    local exec_mode=0
    if [[ "${1:-}" == "--exec" ]]; then exec_mode=1; shift; fi
    local post_pivot="$1"

    : "${BUILDKIT_ROOT:?pivot_and_exec: BUILDKIT_ROOT not set}"
    # Per-user fakemount path (shared /tmp → must not be a fixed /tmp/fakemount).
    : "${FAKEMOUNT_BIN:=/tmp/${USER:-$(id -un)}/buildkit/fakemount}"

    unshare --user sleep infinity &
    local NS_PID=$!
    sleep 0.2
    id_maps "$NS_PID" || { kill "$NS_PID" 2>/dev/null; return 1; }

    # Prologue is shared between build and daemon paths; $post_pivot is
    # appended verbatim and runs after /proc /sys /dev are wired up.
    local script="
        export PATH=/bin:/sbin:/usr/bin:/usr/sbin:\$PATH
        mount --bind $BUILDKIT_ROOT $BUILDKIT_ROOT
        cd $BUILDKIT_ROOT
        mkdir -p .oldroot dev
        pivot_root . .oldroot
        export PATH=/bin:/sbin:/usr/bin:/usr/sbin
        mount -t proc proc /proc
        mount -t sysfs sysfs /sys 2>/dev/null || true
        mkdir -p /sys/fs/cgroup
        mount --bind /.oldroot/sys/fs/cgroup /sys/fs/cgroup 2>/dev/null || \\
            mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null || true
        for dev in null zero full random urandom tty fuse; do
            touch /dev/\$dev 2>/dev/null
            mount --bind /.oldroot/dev/\$dev /dev/\$dev 2>/dev/null || true
        done
        mkdir -p /dev/pts /dev/shm /dev/mqueue
        mount -t devpts devpts /dev/pts 2>/dev/null || true
        mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
        umount -l /.oldroot
        $post_pivot
    "

    if (( exec_mode )); then
        exec nsenter -t "$NS_PID" --user \
            unshare --mount --pid --fork \
            "$FAKEMOUNT_BIN" bash -c "$script"
    fi

    nsenter -t "$NS_PID" --user \
        unshare --mount --pid --fork \
        "$FAKEMOUNT_BIN" bash -c "$script" 2>&1

    kill "$NS_PID" 2>/dev/null || true
    wait "$NS_PID" 2>/dev/null || true
}
