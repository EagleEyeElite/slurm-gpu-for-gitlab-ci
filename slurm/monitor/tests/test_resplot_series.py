"""An application's own curves in the figure (resplot.py, series.jsonl).

The figure renders without matplotlib in these tests only up to the reader;
drawing is checked when matplotlib is installed."""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

RESPLOT = Path(__file__).resolve().parents[1] / "resplot.py"


def _reader():
    pytest.importorskip("matplotlib")
    spec = importlib.util.spec_from_file_location("resplot", RESPLOT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _profile(d: Path, series_rows):
    rows = [{"type": "meta", "host": "n1", "ncpu_alloc": 8}]
    for i in range(5):
        rows.append({"type": "s", "t": 100.0 + 2 * i, "cpu_cores": 1.0, "mem_bytes": 2**30,
                     "mem_anon": 2**29, "gpu": {"0": {"util": 50, "mem_mb": 1024, "mem_total_mb": 4096}}})
    (d / "samples.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (d / "events.jsonl").write_text(json.dumps({"t": 100.0, "label": "a", "kind": "phase-start"}) + "\n"
                                    + json.dumps({"t": 108.0, "label": "a", "kind": "phase-end"}) + "\n")
    (d / "series.jsonl").write_text("".join(json.dumps(r) + "\n" for r in series_rows) + "not json\n")


def test_reader_groups_by_panel_and_label_and_skips_garbage(tmp_path):
    mod = _reader()
    _profile(tmp_path, [
        {"t": 102, "panel": "services", "unit": "s/s", "values": {"embed": 0.5, "rank": 1}},
        {"t": 101, "panel": "services", "unit": "s/s", "values": {"embed": 0.2, "bad": "x"}},
        {"t": 101, "panel": "cpu", "values": {"mine": 0.1}},
        {"panel": "no time"},
    ])
    s = mod.read_series(str(tmp_path / "series.jsonl"))
    assert list(s) == ["services", "cpu"]
    assert s["services"]["unit"] == "s/s"
    assert s["services"]["lines"]["embed"] == [(101.0, 0.2), (102.0, 0.5)]
    assert "bad" not in s["services"]["lines"]


def test_figure_gets_one_panel_per_application_panel(tmp_path):
    _reader()
    _profile(tmp_path, [
        {"t": 102, "panel": "services", "unit": "s/s", "values": {"embed": 0.5}},
        {"t": 102, "panel": "cpu", "values": {"the app": 0.3}},
        {"t": 102, "panel": "memory", "values": {"the app": 2**28}},
    ])
    out = tmp_path / "u.svg"
    subprocess.run([sys.executable, str(RESPLOT), "--dir", str(tmp_path), "--out", str(out)], check=True)
    svg = out.read_text()
    assert "services" in svg and "the app" in svg and "disk MB/s" in svg
