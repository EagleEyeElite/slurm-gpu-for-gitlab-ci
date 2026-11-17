#!/bin/bash
# registry.sh — GitLab's generic package registry, for bin/package and
# bin/slurm-cache. Sourced, not run.
#
#   registry_url <project> <package> <version> [<file>]
#       https://<gitlab>/api/v4/projects/<project>/packages/generic/<package>/<version>[/<file>]
#       <project> is an id or a path (group/project).
#       The GitLab is $CI_SERVER_URL in a job, else $GITLAB_URL (lib/config.sh).
#
#   registry_read_header
#       The header a READ sends: GITLAB_TOKEN (PRIVATE-TOKEN), else
#       GITLAB_TOKEN from $SLURM_CI_SECRETS (~/.config/slurm-gitlab-ci/secrets),
#       else the CI job token. The personal token first because a job token
#       reads another project's packages only if that project allows the
#       calling one (its job-token allowlist); without that a cross-project
#       read is a 404.
#
#   registry_write_header
#       The header a WRITE sends: the CI job token inside CI -- a job writes
#       into its own project as itself, never as the person whose secrets
#       file the runner can read -- else GITLAB_TOKEN.
#
#   registry_put <file> <url>
#       Upload, fail loudly on anything but 201.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: registry.sh is a library; source it, don't run it." >&2
    exit 1
fi

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

REGISTRY_GITLAB="${CI_SERVER_URL:-${GITLAB_URL:-}}"

registry_url() {
    local project="$1" package="$2" version="$3" file="${4:-}"
    [ -n "$REGISTRY_GITLAB" ] || {
        echo "registry: which GitLab? Set GITLAB_URL (lib/config.sh) or run in CI" >&2
        return 1
    }
    # A path is URL-encoded as a project id: group%2Fproject.
    project="${project//\//%2F}"
    echo "$REGISTRY_GITLAB/api/v4/projects/$project/packages/generic/$package/$version${file:+/$file}"
}

_registry_personal_token() {
    local f="${SLURM_CI_SECRETS:-$(slurm_ci_config_dir)/secrets}"
    if [ -z "${GITLAB_TOKEN:-}" ] && [ -f "$f" ]; then
        # shellcheck source=/dev/null
        GITLAB_TOKEN="$(set -a; . "$f"; echo "${GITLAB_TOKEN:-}")"
    fi
    echo "${GITLAB_TOKEN:-}"
}

registry_read_header() {
    local t
    t="$(_registry_personal_token)"
    if [ -n "$t" ]; then echo "PRIVATE-TOKEN: $t"
    elif [ -n "${CI_JOB_TOKEN:-}" ]; then echo "JOB-TOKEN: $CI_JOB_TOKEN"
    else echo "registry: no token -- set GITLAB_TOKEN, run in CI, or put GITLAB_TOKEN=... in ${SLURM_CI_SECRETS:-$(slurm_ci_config_dir)/secrets}" >&2; return 1
    fi
}

registry_write_header() {
    if [ -n "${CI_JOB_TOKEN:-}" ]; then echo "JOB-TOKEN: $CI_JOB_TOKEN"; return; fi
    local t
    t="$(_registry_personal_token)"
    [ -n "$t" ] || { echo "registry: outside CI an upload needs GITLAB_TOKEN (scope api)" >&2; return 1; }
    echo "PRIVATE-TOKEN: $t"
}

registry_put() {
    local file="$1" url="$2" hdr code
    hdr="$(registry_write_header)" || return 1
    code=$(curl -sS --max-time 3600 -H "$hdr" --upload-file "$file" \
        -w '%{http_code}' -o /dev/null "$url") || code="curl failed"
    [ "$code" = "201" ] || { echo "registry: upload of $(basename "$file") to $url returned HTTP $code" >&2; return 1; }
}
