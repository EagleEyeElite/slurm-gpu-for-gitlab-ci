#!/usr/bin/env python3
"""Parse a Dockerfile's final stage and emit a Singularity runscript + env files.

Exists so the overlay-run path honors the Dockerfile's CMD/ENTRYPOINT/ENV/WORKDIR
instead of requiring consumer projects to set RUN_CMD in .gitlab-ci.yml. Writing
these files into the overlay upperdir means `singularity run` picks them up the
same way it would from a native `singularity build --sandbox`.

Only the final stage's directives are consulted — multi-stage builders are
ignored. ENV inherited from the base image is NOT resolved; the user's
Dockerfiles use absolute paths for everything runtime-relevant.
"""

import argparse
import json
import os
import re
import shlex
import stat
import sys
from pathlib import Path


def read_logical_lines(path):
    """Yield Dockerfile logical lines (joined across backslash continuations)."""
    with open(path, "r") as f:
        raw = f.read()
    buf = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not buf and (not stripped or stripped.startswith("#")):
            continue
        if stripped.endswith("\\"):
            buf.append(stripped[:-1])
            continue
        buf.append(stripped)
        yield " ".join(buf).strip()
        buf = []
    if buf:
        yield " ".join(buf).strip()


def split_stages(lines):
    stages = []
    current = []
    for line in lines:
        if re.match(r"(?i)^FROM\b", line):
            if current:
                stages.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        stages.append(current)
    return stages


def parse_exec_or_shell(value):
    """Parse a CMD/ENTRYPOINT value. Returns (argv, is_exec_form)."""
    value = value.strip()
    if value.startswith("["):
        try:
            argv = json.loads(value)
            return argv, True
        except json.JSONDecodeError:
            pass
    return shlex.split(value), False


def parse_env(value):
    """Parse an ENV directive into a list of (key, value) pairs.

    Handles both `ENV K=V K2=V2` and the legacy `ENV K V` forms.
    """
    value = value.strip()
    if "=" in value and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s+[^=]", value):
        pairs = []
        lex = shlex.shlex(value, posix=True)
        lex.whitespace_split = True
        lex.commenters = ""
        tokens = list(lex)
        for tok in tokens:
            if "=" in tok:
                k, v = tok.split("=", 1)
                pairs.append((k, v))
        return pairs
    parts = value.split(None, 1)
    if len(parts) == 2:
        return [(parts[0], parts[1])]
    return []


def parse_stage(stage_lines):
    config = {"cmd": None, "entrypoint": None, "env": [], "workdir": None, "user": None}
    for line in stage_lines:
        m = re.match(r"(?i)^(CMD|ENTRYPOINT|ENV|WORKDIR|USER)\s+(.+)$", line)
        if not m:
            continue
        directive = m.group(1).upper()
        value = m.group(2).strip()
        if directive == "CMD":
            argv, is_exec = parse_exec_or_shell(value)
            config["cmd"] = (argv, is_exec)
        elif directive == "ENTRYPOINT":
            argv, is_exec = parse_exec_or_shell(value)
            config["entrypoint"] = (argv, is_exec)
        elif directive == "ENV":
            config["env"].extend(parse_env(value))
        elif directive == "WORKDIR":
            config["workdir"] = value.strip().strip('"').strip("'")
        elif directive == "USER":
            config["user"] = value.strip().strip('"').strip("'")
    return config


def build_runscript(config):
    entrypoint = config["entrypoint"]
    cmd = config["cmd"]
    workdir = config["workdir"]

    if entrypoint is None and cmd is None:
        return None

    parts = []
    if entrypoint is not None:
        ep_argv, ep_exec = entrypoint
        if ep_exec:
            parts.extend(ep_argv)
        else:
            parts = ["/bin/sh", "-c", " ".join(ep_argv)]

    if cmd is not None:
        cmd_argv, cmd_exec = cmd
        if entrypoint is None:
            if cmd_exec:
                parts = list(cmd_argv)
            else:
                parts = ["/bin/sh", "-c", " ".join(cmd_argv)]
        else:
            if entrypoint[1]:
                parts.extend(cmd_argv)

    quoted = " ".join(shlex.quote(p) for p in parts)
    lines = ["#!/bin/sh", "# Synthesized from the Dockerfile by synthesize-singularity-runscript.py"]
    if workdir:
        lines.append(f'cd {shlex.quote(workdir)}')
    lines.append(f'exec {quoted} "$@"')
    return "\n".join(lines) + "\n"


def build_env_script(env_pairs):
    if not env_pairs:
        return None
    lines = ["#!/bin/sh", "# Synthesized from the Dockerfile's ENV directives"]
    for k, v in env_pairs:
        lines.append(f'export {k}={shlex.quote(v)}')
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dockerfile", required=True)
    ap.add_argument("--output-dir", required=True, help=".singularity.d/ directory to populate")
    args = ap.parse_args()

    stages = split_stages(list(read_logical_lines(args.dockerfile)))
    if not stages:
        print("ERROR: no FROM stage found in Dockerfile", file=sys.stderr)
        sys.exit(1)

    config = parse_stage(stages[-1])
    runscript = build_runscript(config)
    env_script = build_env_script(config["env"])

    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "env").mkdir(exist_ok=True)

    if runscript is None:
        print("ERROR: Dockerfile final stage has no CMD or ENTRYPOINT", file=sys.stderr)
        sys.exit(2)

    rs = out / "runscript"
    rs.write_text(runscript)
    rs.chmod(rs.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    if env_script:
        (out / "env" / "10-docker2singularity.sh").write_text(env_script)

    print(f"runscript: {rs}")
    if config["workdir"]:
        print(f"workdir: {config['workdir']}")
    if env_script:
        print(f"env: {len(config['env'])} variables")


if __name__ == "__main__":
    main()
