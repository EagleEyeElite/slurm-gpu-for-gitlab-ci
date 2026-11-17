"""The machine-readable performance record.

`summarize.py --json` is what turns a CI log nobody keeps into a fact stored
next to the artifact. These pin its shape, because the whole point is that
someone reads it years later, next to a second artifact, and compares — which
only works if the two records mean the same thing.

The sample shapes below are resmon.py's own writer output.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

SUMMARIZE = Path(__file__).resolve().parents[1] / "summarize.py"


def _samples(tmp_path: Path, *, gpus=2, ncpu=32) -> Path:
    """Two phases: a GPU-bound one, then a single-threaded one.

    That is the real shape of this build — embedding saturates the cards, and
    the Lucene write afterwards runs on about one core of thirty-two. A record
    that cannot show that difference is not worth storing.
    """
    rows = [{"type": "meta", "host": "node1", "slurm_job": "10042", "ncpu_alloc": ncpu}]
    for i in range(120):
        embedding = i < 60
        rows.append({
            "type": "s",
            "t": 1000.0 + i * 2,
            "cpu_cores": 28.0 if embedding else 1.0,
            "mem_bytes": int((40 if embedding else 12) * 2**30),
            "read_bps": 1e7,
            "write_bps": 2e7,
            "gpu": {
                str(g): {"util": 90 if embedding else 0, "name": "NVIDIA GeForce GTX 1080 Ti"}
                for g in range(gpus)
            },
            "top": [{"cmd": "python3", "cores": 27.0 if embedding else 1.0}],
        })
    (tmp_path / "samples.jsonl").write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n"
    )
    (tmp_path / "events.jsonl").write_text("\n".join(json.dumps(e) for e in [
        {"t": 1000.0, "kind": "phase-start", "label": "embedding"},
        {"t": 1120.0, "kind": "phase-end", "label": "embedding"},
        {"t": 1120.0, "kind": "phase-start", "label": "build the Lucene index"},
        {"t": 1238.0, "kind": "phase-end", "label": "build the Lucene index"},
    ]) + "\n")
    return tmp_path


def _record(tmp_path: Path) -> dict:
    out = subprocess.run(
        [sys.executable, str(SUMMARIZE), "--dir", str(tmp_path), "--json", "-"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def test_records_the_machine_it_ran_on(tmp_path):
    """Which machine is half of why a build took as long as it did."""
    rec = _record(_samples(tmp_path))
    assert rec["available"] is True
    assert rec["machine"] == {
        "host": "node1",
        "slurm_job": "10042",
        "cpus_allocated": 32,
        "gpus_allocated": 2,
        "gpu_names": ["NVIDIA GeForce GTX 1080 Ti"],
    }


def test_phases_carry_their_own_utilisation(tmp_path):
    """The finding this exists to preserve: the GPU phase and the
    single-threaded phase after it look completely different, and only a
    per-phase record shows that."""
    rec = _record(_samples(tmp_path))
    phases = {p["phase"]: p for p in rec["phases"]}
    assert set(phases) == {"embedding", "build the Lucene index"}

    embed = phases["embedding"]
    assert embed["seconds"] == 120.0
    # Not exactly 90: a phase window is inclusive at both ends, so the sample
    # on the boundary belongs to this phase and the next one. That is the right
    # trade for a 2-second sampler — the alternative is a gap between phases —
    # and it means the mean is "about", never "exactly".
    assert 85 <= embed["mean_gpu_percent"] <= 90
    assert embed["mean_cpu_cores"] > 20

    lucene = phases["build the Lucene index"]
    assert lucene["mean_gpu_percent"] == 0.0
    # ~1 core of 32 — the number that says where to optimise next.
    assert lucene["mean_cpu_cores"] < 2


def test_delivered_is_the_number_that_drives_optimisation(tmp_path):
    """Allocated vs delivered, for both resources. A build can look busy and
    still waste most of what it reserved."""
    rec = _record(_samples(tmp_path))
    d = rec["delivered"]
    # Half the run is GPU-idle by construction, so about half is delivered.
    assert 40 <= d["gpu_percent_of_allocation"] <= 50
    assert d["gpu_seconds"] < d["gpu_seconds_allocated"]
    assert 0 < d["core_percent_of_allocation"] < 100
    assert d["core_seconds"] < d["core_seconds_allocated"]


def test_names_the_processes_that_burned_the_cpu(tmp_path):
    rec = _record(_samples(tmp_path))
    top = rec["top_cpu_consumers"]
    assert top and top[0]["command"] == "python3"
    assert top[0]["core_seconds"] > 0


def test_a_cpu_only_run_reports_no_gpu_rather_than_zero(tmp_path):
    """A build with no GPU allocated must not claim 0% utilisation of nothing —
    that reads as a wasted GPU rather than an absent one."""
    rec = _record(_samples(tmp_path, gpus=0))
    assert rec["machine"]["gpus_allocated"] == 0
    assert rec["machine"]["gpu_names"] is None
    assert rec["totals"]["mean_gpu_percent"] is None
    assert rec["delivered"]["gpu_seconds"] is None
    assert rec["delivered"]["core_seconds"] > 0


def test_missing_samples_is_reported_not_raised(tmp_path):
    """Instrumentation must never be why a good build is marked bad."""
    out = subprocess.run(
        [sys.executable, str(SUMMARIZE), "--dir", str(tmp_path), "--json", "-"],
        capture_output=True, text=True, check=True,
    )
    rec = json.loads(out.stdout)
    assert rec["available"] is False
    assert "reason" in rec


def test_the_table_still_prints(tmp_path):
    """The JSON mode is an addition, not a replacement — the CI log still says
    where the time went without anyone opening an artifact."""
    out = subprocess.run(
        [sys.executable, str(SUMMARIZE), "--dir", str(_samples(tmp_path))],
        capture_output=True, text=True, check=True,
    )
    assert "resource summary" in out.stdout
    assert "embedding" in out.stdout
    assert "core-seconds delivered" in out.stdout


def test_written_to_a_file_is_the_same_record(tmp_path):
    d = _samples(tmp_path)
    target = tmp_path / "nested" / "performance.json"
    subprocess.run(
        [sys.executable, str(SUMMARIZE), "--dir", str(d), "--json", str(target)],
        capture_output=True, text=True, check=True,
    )
    assert json.loads(target.read_text()) == _record(d)


@pytest.mark.parametrize("key", ["schema", "wall_seconds", "phases", "totals", "delivered"])
def test_the_shape_is_stable(tmp_path, key):
    """Two artifacts are only comparable if their records agree on structure."""
    assert key in _record(_samples(tmp_path))
