"""slurm-job-local -- run one job of a project's .gitlab-ci.yml on this cluster
the way the SLURM runner would, from a working tree, without a commit.

    slurm-job-local [--dir <project>] <job> [--var KEY=VALUE]... [--dry-run]

    slurm-job-local build-and-run --var SLURM_GPUS=1 --var SLURM_TIME=30
    slurm-job-local --dir ~/src/my-project benchmark --dry-run

What the runner does for a job, done here:

  - the job as GitLab sees it: `extends` resolved (hidden jobs, `include:` of
    another project's file or a local one), `default:` scripts, the global
    and the job's `variables:` with $VAR references expanded, --var last
  - the runner's environment: PATH, NIX_PORTABLE_SHELL, the site settings
    of ~/.config/slurm-gitlab-ci/config (BUILDKIT_NODE, ...), and the CI_* a
    job reads -- CI_PROJECT_DIR, CI_JOB_ID (local-<pid>),
    CI_JOB_NAME, CI_COMMIT_SHA / SHORT_SHA / BRANCH from the working tree's
    git, CI_DEFAULT_BRANCH, CI_PROJECT_PATH, CI_REGISTRY_IMAGE, CI_SERVER_URL,
    CI_API_V4_URL
  - its pre_build_script: one SLURM allocation for the job (slurm-allocate,
    with the job's SLURM_GPUS / CPUS / MEM / TIME), cancelled when it ends
  - before_script and script in one bash (-eo pipefail), after_script in a
    second one, as the shell executor runs them

What it does NOT do, on purpose: `CI` is not set (a script that distinguishes
a pipeline from a person sees a person), there is no job token (a job that
pushes an image or publishes a package is a pipeline's job: `glab ci run`),
and rules, needs, artifacts and dotenv reports are a pipeline's business --
pass what a previous job's dotenv would have given with --var. Only jobs for
the SLURM runner (tags: [slurm]) run here; a job with an `image:` runs on
another runner.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "slurm-gitlab-ci"


def read_env_file(path: Path) -> dict:
    """KEY=VALUE lines (optionally `export KEY=...`, optionally quoted)."""
    out = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, sep, v = line.removeprefix("export ").partition("=")
            if sep:
                out[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return out


CONFIG = read_env_file(Path(os.environ.get("SLURM_CI_CONFIG") or CONFIG_DIR / "config"))
GITLAB = (os.environ.get("CI_SERVER_URL") or os.environ.get("GITLAB_URL")
          or CONFIG.get("GITLAB_URL") or "https://gitlab.com").rstrip("/")
# The registry of the GitLab above, for CI_REGISTRY_IMAGE. Only a push needs
# it, and a push is a pipeline's job (see below); set CI_REGISTRY to override.
REGISTRY = (os.environ.get("CI_REGISTRY") or CONFIG.get("CI_REGISTRY")
            or "registry." + re.sub(r"^https?://", "", GITLAB).split("/")[0])
NOT_A_JOB = {"stages", "variables", "include", "default", "workflow", "image",
             "services", "cache", "before_script", "after_script"}


def die(msg: str) -> None:
    sys.exit(f"slurm-job-local: {msg}")


def token() -> str | None:
    if os.environ.get("GITLAB_TOKEN"):
        return os.environ["GITLAB_TOKEN"]
    secrets = Path(os.environ.get("SLURM_CI_SECRETS") or CONFIG_DIR / "secrets")
    return read_env_file(secrets).get("GITLAB_TOKEN")


def fetch_project_file(project: str, ref: str, path: str) -> str:
    url = (f"{GITLAB}/api/v4/projects/{urllib.parse.quote(project, safe='')}"
           f"/repository/files/{urllib.parse.quote(path, safe='')}/raw?ref={urllib.parse.quote(ref)}")
    req = urllib.request.Request(url)
    t = token()
    if t:
        req.add_header("PRIVATE-TOKEN", t)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode()
    except Exception as e:  # noqa: BLE001
        die(f"cannot read include {project}:{path}@{ref} ({e}); set GITLAB_TOKEN")


def load(project_dir: Path) -> dict:
    """.gitlab-ci.yml with its includes merged under it (the file wins)."""
    doc = yaml.safe_load((project_dir / ".gitlab-ci.yml").read_text()) or {}
    includes = doc.get("include") or []
    if isinstance(includes, (str, dict)):
        includes = [includes]
    merged: dict = {}
    for inc in includes:
        if isinstance(inc, str):
            inc = {"local": inc}
        if "local" in inc:
            texts = [(project_dir / inc["local"].lstrip("/")).read_text()]
        elif "project" in inc:
            files = inc["file"] if isinstance(inc["file"], list) else [inc["file"]]
            texts = [fetch_project_file(inc["project"], inc.get("ref", "main"), f) for f in files]
        else:
            print(f"slurm-job-local: skipping include {inc} (only project: and local: are read)",
                  file=sys.stderr)
            continue
        for text in texts:
            merged.update(yaml.safe_load(text) or {})
    merged.update(doc)
    return merged


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def resolve(doc: dict, name: str, seen: tuple = ()) -> dict:
    if name in seen:
        die(f"extends loops through {name}")
    if name not in doc or not isinstance(doc[name], dict):
        die(f"no job {name!r} in .gitlab-ci.yml (or its includes)")
    job = doc[name]
    parents = job.get("extends") or []
    if isinstance(parents, str):
        parents = [parents]
    out: dict = {}
    for p in parents:
        out = deep_merge(out, resolve(doc, p, seen + (name,)))
    return deep_merge(out, {k: v for k, v in job.items() if k != "extends"})


def git(project_dir: Path, *args: str) -> str:
    r = subprocess.run(["git", "-C", str(project_dir), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def ci_env(project_dir: Path, job_name: str) -> dict:
    sha = git(project_dir, "rev-parse", "HEAD") or "0" * 40
    remote = git(project_dir, "remote", "get-url", "origin")
    m = re.search(r"[:/]([^:]+?/[^/]+?)(?:\.git)?$", remote.replace(GITLAB, ""))
    path = m.group(1).lstrip("/") if m else project_dir.name
    default = (git(project_dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD") or "origin/main")
    return {
        "CI_PROJECT_DIR": str(project_dir),
        "CI_JOB_ID": f"local-{os.getpid()}",
        "CI_JOB_NAME": job_name,
        "CI_COMMIT_SHA": sha,
        "CI_COMMIT_SHORT_SHA": sha[:8],
        "CI_COMMIT_BRANCH": git(project_dir, "rev-parse", "--abbrev-ref", "HEAD"),
        "CI_DEFAULT_BRANCH": default.split("/", 1)[-1],
        "CI_PROJECT_PATH": path,
        "CI_PROJECT_NAME": path.rsplit("/", 1)[-1],
        "CI_SERVER_URL": GITLAB,
        "CI_API_V4_URL": f"{GITLAB}/api/v4",
        "CI_REGISTRY": REGISTRY,
        "CI_REGISTRY_IMAGE": f"{REGISTRY}/{path}",
    }


def as_lines(v) -> list[str]:
    if v is None:
        return []
    lines = [v] if isinstance(v, str) else list(v)
    for line in lines:
        if not isinstance(line, str):
            # `- echo "a: b"` unquoted is a mapping, not a command; GitLab
            # rejects it too.
            die(f"a script line is not a string (quote it): {line!r}")
    return lines


def main() -> None:
    ap = argparse.ArgumentParser(prog="slurm-job-local", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("job")
    ap.add_argument("--dir", default=".", help="the project's working tree (default: here)")
    ap.add_argument("--var", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument("--dry-run", action="store_true", help="print the job and its environment, run nothing")
    args = ap.parse_args()

    project_dir = Path(args.dir).resolve()
    if not (project_dir / ".gitlab-ci.yml").is_file():
        die(f"no .gitlab-ci.yml in {project_dir}")
    doc = load(project_dir)
    if args.job in NOT_A_JOB or args.job.startswith("."):
        die(f"{args.job!r} is not a job")
    job = resolve(doc, args.job)
    if "trigger" in job:
        die(f"{args.job} triggers another pipeline; that is a pipeline's job")
    if "slurm" not in (job.get("tags") or []):
        where = f"image {job['image']}" if job.get("image") else f"tags {job.get('tags')}"
        die(f"{args.job} is not a SLURM runner job ({where}); run it in a pipeline")

    env = dict(os.environ)
    env.pop("CI", None)
    home = str(Path.home())
    env["PATH"] = f"{home}/.nix-profile/bin:{home}/bin:" + env.get("PATH", "")
    env["NIX_PORTABLE_SHELL"] = "1"
    for k, v in CONFIG.items():
        env.setdefault(k, v)
    env.update(ci_env(project_dir, args.job))
    variables = deep_merge(doc.get("variables") or {}, job.get("variables") or {})
    for kv in args.var:
        k, sep, v = kv.partition("=")
        if not sep:
            die(f"--var {kv!r} is not KEY=VALUE")
        variables[k] = v
    # $VAR in a value is expanded against what is set so far -- the CI_*
    # above and earlier variables -- as GitLab does.
    os.environ.update(env)
    for k, v in variables.items():
        if isinstance(v, dict):  # {value: ..., description: ...}
            v = v.get("value", "")
        env[k] = os.environ[k] = os.path.expandvars(str(v))

    default = doc.get("default") or {}
    before = as_lines(job.get("before_script", default.get("before_script", doc.get("before_script"))))
    script = as_lines(job.get("script"))
    after = as_lines(job.get("after_script", default.get("after_script", doc.get("after_script"))))
    if not script:
        die(f"{args.job} has no script")

    def body(lines: list[str]) -> str:
        return "\n".join(f"echo {shlex.quote('$ ' + l.splitlines()[0] + (' ...' if chr(10) in l else ''))}\n{l}"
                         for l in lines)

    main_shell = ("set -eo pipefail\ncd \"$CI_PROJECT_DIR\"\n"
                  'eval "$(slurm-allocate)"\n' + body(before + script))
    after_shell = "cd \"$CI_PROJECT_DIR\"\n" + body(after)

    shown = {k: env[k] for k in sorted(set(variables) | {"CI_JOB_ID", "CI_COMMIT_SHORT_SHA", "CI_PROJECT_DIR"})}
    print(f"slurm-job-local: {args.job} from {project_dir}", file=sys.stderr)
    print(json.dumps(shown, indent=2), file=sys.stderr)
    for kind in ("rules", "needs", "artifacts", "dependencies", "resource_group"):
        if kind in job:
            print(f"slurm-job-local: ignoring {kind} (a pipeline's business)", file=sys.stderr)
    if args.dry_run:
        print("--- script ---\n" + main_shell + ("\n--- after_script ---\n" + after_shell if after else ""))
        return

    rc = subprocess.run(["bash", "-c", main_shell], env=env).returncode
    if after:
        subprocess.run(["bash", "-c", after_shell], env={**env, "CI_JOB_STATUS": "success" if rc == 0 else "failed"})
    print(f"slurm-job-local: {args.job} {'succeeded' if rc == 0 else f'failed (exit {rc})'}", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
