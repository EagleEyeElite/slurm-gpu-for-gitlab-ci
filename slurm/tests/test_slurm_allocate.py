"""slurm-allocate's resource asks, against a fake scontrol and salloc.

What is pinned: SLURM_GPUS=max turns into a number of GPUs from the node's own
Gres= / GresUsed= (scontrol -d show node -o, the shape Slurm 23.11 prints),
that number reaches salloc and the job shell, and a numeric SLURM_GPUS is
passed through untouched, with nothing new exported. Also: where the job is
placed (BUILDKIT_NODE, SLURM_NODE, the site's partition/account) and that no
--gres is asked for without GPUs.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

# The fakes' shebang: the bash on PATH. A nix build sandbox has no /bin/bash.
SHEBANG = f"#!{shutil.which('bash') or '/bin/bash'}\n"

ALLOCATE = Path(__file__).resolve().parents[1] / "bin" / "slurm-allocate"

# The shape of `scontrol -d show node <node> -o`, trimmed.
NODE = ("NodeName=node1 Arch=x86_64 CoresPerSocket=18 CPUAlloc=4 CPUEfctv=72 CPUTot=72 "
        "Gres={gres} NodeAddr=node1 NodeHostName=node1 Version=23.11.6 "
        "GresDrain=N/A GresUsed={used} State=MIXED Partitions=gpu "
        "CfgTRES=cpu=72,mem=515848M,billing=72 AllocTRES=cpu=4,mem=64G")
TYPED = "gpu:nvidia_geforce_gtx_1080_ti"


def _run(tmp_path: Path, gpus=None, gres=f"{TYPED}:8(S:0)", used=f"{TYPED}:1(IDX:0)",
         scontrol_fails=False, extra_env=None, buildkit_node="node1"):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "scontrol").write_text(
        SHEBANG
        + f'echo "$*" >> {tmp_path}/scontrol.args\n'
        + ("exit 1\n" if scontrol_fails else f"echo '{NODE.format(gres=gres, used=used)}'\n"))
    (bin_dir / "salloc").write_text(
        SHEBANG
        + f'printf "%s\\n" "$@" > {tmp_path}/salloc.args\n'
        'echo "salloc: Granted job allocation 4242" >&2\n')
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SLURM_", "RUNNER_CACHE", "BUILDKIT_", "NODE_LOCAL_DIR"))}
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    # Never the caller's own ~/.config/slurm-gitlab-ci/config.
    env["SLURM_CI_CONFIG"] = str(tmp_path / "no-config")
    if buildkit_node is not None:
        env["BUILDKIT_NODE"] = buildkit_node
    if gpus is not None:
        env["SLURM_GPUS"] = gpus
    env.update(extra_env or {})
    p = subprocess.run(["bash", str(ALLOCATE)], env=env, capture_output=True, text=True)
    salloc = tmp_path / "salloc.args"
    args = salloc.read_text().splitlines() if salloc.exists() else None
    return p, args


def _gres(args):
    return [a for a in args if a.startswith("--gres=")]


def _shell(tmp_path: Path, emitted: str) -> str:
    """What the runner's shell sees after the eval: SLURM_GPUS and the log line."""
    bin_dir = tmp_path / "bin"
    (bin_dir / "scancel").write_text(SHEBANG)
    (bin_dir / "scancel").chmod(0o755)
    script = emitted + '\necho "SLURM_GPUS=${SLURM_GPUS-unset}"\n'
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "SLURM_GPUS": "max"}
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True,
                          text=True, check=True).stdout


def test_max_asks_for_every_free_gpu_and_exports_the_number(tmp_path):
    p, args = _run(tmp_path, "max")
    assert p.returncode == 0, p.stderr
    assert _gres(args) == ["--gres=gpu:7"]
    assert "-d show node node1 -o" in (tmp_path / "scontrol.args").read_text()
    out = _shell(tmp_path, p.stdout)
    assert "SLURM_GPUS=7" in out
    assert "held (gpu=7 of 8, max cpus=2" in out


def test_max_on_an_idle_node_takes_all_of_it(tmp_path):
    p, args = _run(tmp_path, "max", used="gpu:0")
    assert p.returncode == 0, p.stderr
    assert _gres(args) == ["--gres=gpu:8"]


def test_max_reads_index_lists_with_commas(tmp_path):
    # IDX:0,2-3 is three GPUs in use; the comma inside it is not an entry separator.
    p, args = _run(tmp_path, "max", used=f"{TYPED}:3(IDX:0,2-3)")
    assert _gres(args) == ["--gres=gpu:5"]


def test_max_sums_several_gpu_types(tmp_path):
    p, args = _run(tmp_path, "max", gres="gpu:a:4(S:0),gpu:b:4(S:1)",
                   used="gpu:a:1(IDX:0),gpu:b:2(IDX:4-5)")
    assert _gres(args) == ["--gres=gpu:5"]


def test_max_with_none_free_queues_for_one(tmp_path):
    p, args = _run(tmp_path, "max", used=f"{TYPED}:8(IDX:0-7)")
    assert p.returncode == 0, p.stderr
    assert _gres(args) == ["--gres=gpu:1"]
    assert "all 8 GPUs of node1 are taken" in p.stderr
    assert "SLURM_GPUS=1" in _shell(tmp_path, p.stdout)


def test_max_on_a_node_without_gpus_fails(tmp_path):
    p, args = _run(tmp_path, "max", gres="(null)", used="gpu:0")
    assert p.returncode != 0
    assert args is None
    assert "has no GPUs" in p.stderr


def test_max_when_scontrol_fails_fails(tmp_path):
    p, args = _run(tmp_path, "max", scontrol_fails=True)
    assert p.returncode != 0
    assert args is None


@pytest.mark.parametrize("gpus,want", [(None, "0"), ("0", "0"), ("2", "2"), ("6", "6")])
def test_numbers_pass_through_unchanged(tmp_path, gpus, want):
    p, args = _run(tmp_path, gpus)
    assert p.returncode == 0, p.stderr
    assert _gres(args) == ([] if want == "0" else [f"--gres=gpu:{want}"])
    assert not (tmp_path / "scontrol.args").exists()
    assert "SLURM_GPUS" not in p.stdout.split("echo", 1)[0]
    assert f"held (gpu={want} cpus=2 time=120min)" in p.stdout


def test_the_job_is_placed_on_the_buildkit_node(tmp_path):
    p, args = _run(tmp_path, "1")
    assert p.returncode == 0, p.stderr
    assert args[args.index("-w") + 1] == "node1"


def test_slurm_node_any_lets_slurm_choose(tmp_path):
    p, args = _run(tmp_path, "1", extra_env={"SLURM_NODE": "any"})
    assert p.returncode == 0, p.stderr
    assert "-w" not in args


def test_without_a_buildkit_node_slurm_chooses(tmp_path):
    p, args = _run(tmp_path, "1", buildkit_node=None)
    assert p.returncode == 0, p.stderr
    assert "-w" not in args


def test_max_without_a_node_fails(tmp_path):
    p, args = _run(tmp_path, "max", buildkit_node=None)
    assert p.returncode != 0
    assert args is None


def test_site_settings_reach_salloc(tmp_path):
    p, args = _run(tmp_path, "2", extra_env={
        "SLURM_PARTITION": "gpu", "SLURM_ACCOUNT": "proj42",
        "SLURM_GRES_NAME": "shard", "SLURM_EXTRA_ARGS": "--constraint=a100 --exclusive"})
    assert p.returncode == 0, p.stderr
    assert "--partition=gpu" in args and "--account=proj42" in args
    assert _gres(args) == ["--gres=shard:2"]
    assert "--constraint=a100" in args and "--exclusive" in args


def test_settings_come_from_the_config_file(tmp_path):
    cfg = tmp_path / "config"
    cfg.write_text('BUILDKIT_NODE="node7"\nSLURM_PARTITION="batch"\n')
    p, args = _run(tmp_path, "1", buildkit_node=None, extra_env={"SLURM_CI_CONFIG": str(cfg)})
    assert p.returncode == 0, p.stderr
    assert args[args.index("-w") + 1] == "node7"
    assert "--partition=batch" in args


def test_the_environment_wins_over_the_config_file(tmp_path):
    cfg = tmp_path / "config"
    cfg.write_text('BUILDKIT_NODE="node7"\n')
    p, args = _run(tmp_path, "1", extra_env={"SLURM_CI_CONFIG": str(cfg)})
    assert args[args.index("-w") + 1] == "node1"


def test_a_failing_salloc_shows_its_error(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "salloc").write_text(SHEBANG + "echo 'salloc: error: Invalid partition name specified' >&2\nexit 1\n")
    (bin_dir / "salloc").chmod(0o755)
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "SLURM_CI_CONFIG": str(tmp_path / "none"),
           "HOME": str(tmp_path), "SLURM_GPUS": "1"}
    p = subprocess.run(["bash", str(ALLOCATE)], env=env, capture_output=True, text=True)
    assert p.returncode != 0
    assert "Invalid partition name" in p.stderr


def test_a_gpu_count_that_is_not_a_number_fails(tmp_path):
    p, args = _run(tmp_path, "two")
    assert p.returncode != 0
    assert args is None
