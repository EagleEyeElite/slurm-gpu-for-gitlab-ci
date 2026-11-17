#!/usr/bin/env python3
"""Per-phase table: how long, how much of the machine was used, and -- the
number that actually drives optimisation -- how much was wasted.

Printed into the CI log so a pipeline says where its time went without anyone
opening an artifact.

``--json`` writes the same facts as a machine-readable record instead, which is
what gets published alongside the artifact. The table is for the person reading
the pipeline now; the JSON is for the person six months from now asking why a
build that used to take 60 minutes takes 90, with two artifacts in front of
them and no CI log for either.
"""
import argparse, json, os, sys


def phases(evs):
    stack, out = {}, []
    for e in sorted(evs, key=lambda e: e["t"]):
        lab, kind = e.get("label", ""), e.get("kind", "point")
        if kind == "phase-start":
            stack.setdefault(lab, []).append(e["t"])
        elif kind == "phase-end" and stack.get(lab):
            out.append((lab, stack[lab].pop(), e["t"]))
    return sorted(out, key=lambda p: p[1])


def hms(s):
    s = int(round(s))
    return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60) if s >= 3600 \
        else "%d:%02d" % (s // 60, s % 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--json", metavar="PATH",
                    help="write the machine-readable record here instead of a table "
                         "(- for stdout)")
    a = ap.parse_args()

    samples_path = os.path.join(a.dir, "samples.jsonl")
    if not os.path.exists(samples_path):
        # Instrumentation must never be the reason a good build is marked bad.
        if a.json:
            _write(a.json, {"available": False, "reason": "no samples.jsonl"})
        else:
            print("resmon: no samples.jsonl")
        return

    rows = [json.loads(l) for l in open(samples_path)]
    meta = next((r for r in rows if r["type"] == "meta"), {})
    ss = [r for r in rows if r["type"] == "s"]
    if not ss:
        if a.json:
            _write(a.json, {"available": False, "reason": "no samples"})
        else:
            print("resmon: no samples")
        return
    evp = os.path.join(a.dir, "events.jsonl")
    evs = [json.loads(l) for l in open(evp)] if os.path.exists(evp) else []
    ph = phases(evs)

    ncpu = meta.get("ncpu_alloc") or 1
    ngpu = len({k for r in ss for k in (r.get("gpu") or {})})
    t0, t1 = ss[0]["t"], ss[-1]["t"]
    span = t1 - t0

    def window(s, e):
        return [r for r in ss if s <= r["t"] <= e]

    def stats(w):
        if not w:
            return None
        cpu = sum(r.get("cpu_cores", 0) for r in w) / len(w)
        g = [v["util"] or 0 for r in w for v in (r.get("gpu") or {}).values()]
        gpu = sum(g) / len(g) if g else None
        mem = max((r.get("mem_bytes") or 0) for r in w) / 2**30
        io = max(r.get("write_bps", 0) + r.get("read_bps", 0) for r in w) / 1e6
        return cpu, gpu, mem, io

    if a.json:
        _write(a.json, _record(meta, ss, ph, ncpu, ngpu, span, window, stats))
        return

    print()
    print("=" * 92)
    print("resource summary  %s  %s  (%d CPU, %d GPU allocated)"
          % (meta.get("host", "?"),
             "SLURM job %s" % meta["slurm_job"] if meta.get("slurm_job") else "local",
             ncpu, ngpu))
    print("=" * 92)
    hdr = "%-42s %8s %7s %7s %8s %9s" % ("phase", "wall", "cpu", "gpu%", "peak RSS", "peak MB/s")
    print(hdr)
    print("-" * 92)

    covered = 0.0
    for lab, s, e in ph:
        st = stats(window(s, e))
        covered += e - s
        if not st:
            continue
        cpu, gpu, mem, io = st
        print("%-42s %8s %6.1fc %6s %7.1fG %9.0f"
              % (lab[:42], hms(e - s), cpu,
                 ("%.0f" % gpu) if gpu is not None else "-", mem, io))
    print("-" * 92)
    st = stats(ss)
    cpu, gpu, mem, io = st
    print("%-42s %8s %6.1fc %6s %7.1fG %9.0f"
          % ("TOTAL", hms(span), cpu, ("%.0f" % gpu) if gpu is not None else "-", mem, io))
    if ph:
        print("%-42s %8s" % ("unattributed (between phases)", hms(max(0.0, span - covered))))

    # The headline: what fraction of the allocation went unused, and where.
    print()
    idle_gpu = [r for r in ss
                if (r.get("gpu") and max((v["util"] or 0) for v in r["gpu"].values()) < 5)]
    idle_cpu = [r for r in ss if r.get("cpu_cores", 0) < 0.5 * ncpu]
    if ngpu:
        print("GPUs idle (<5%%) for %s of %s -- %.0f%% of the run"
              % (hms(len(idle_gpu) * span / len(ss)), hms(span), 100.0 * len(idle_gpu) / len(ss)))
    print("CPU below half the allocation for %s -- %.0f%% of the run"
          % (hms(len(idle_cpu) * span / len(ss)), 100.0 * len(idle_cpu) / len(ss)))
    if ngpu:
        gsec = sum((v["util"] or 0) / 100.0 for r in ss for v in (r.get("gpu") or {}).values())
        gsec *= span / len(ss)
        print("GPU-seconds delivered: %.0f of %.0f allocated (%.0f%%)"
              % (gsec, ngpu * span, 100.0 * gsec / max(1e-9, ngpu * span)))
    csec = sum(r.get("cpu_cores", 0) for r in ss) * span / len(ss)
    print("core-seconds delivered: %.0f of %.0f allocated (%.0f%%)"
          % (csec, ncpu * span, 100.0 * csec / max(1e-9, ncpu * span)))

    # Which commands actually burned the CPU -- names the hotspot without a profiler.
    by_cmd = {}
    for r in ss:
        for t in r.get("top", []):
            by_cmd[t["cmd"]] = by_cmd.get(t["cmd"], 0.0) + t["cores"]
    if by_cmd:
        scale = span / len(ss)
        print("\ntop CPU consumers (core-seconds):")
        for cmd, v in sorted(by_cmd.items(), key=lambda kv: -kv[1])[:8]:
            print("  %-28s %9.0f" % (cmd, v * scale))
    print("=" * 92)


def _record(meta, ss, ph, ncpu, ngpu, span, window, stats):
    """The same facts the table shows, shaped for storage.

    Deliberately flat and self-describing: this is read years later by someone
    comparing two builds, so every number carries its unit in its name and
    nothing has to be cross-referenced against the code that wrote it.
    """
    def phase_record(lab, s, e):
        st = stats(window(s, e))
        out = {"phase": lab, "seconds": round(e - s, 1)}
        if st:
            cpu, gpu, mem, io = st
            out.update({
                "mean_cpu_cores": round(cpu, 2),
                "mean_gpu_percent": round(gpu, 1) if gpu is not None else None,
                "peak_rss_gib": round(mem, 2),
                "peak_io_mb_per_s": round(io, 1),
            })
        return out

    cpu, gpu, mem, io = stats(ss)
    covered = sum(e - s for _, s, e in ph)

    gpu_seconds = None
    if ngpu:
        gpu_seconds = sum(
            (v["util"] or 0) / 100.0 for r in ss for v in (r.get("gpu") or {}).values()
        ) * span / len(ss)
    core_seconds = sum(r.get("cpu_cores", 0) for r in ss) * span / len(ss)

    by_cmd = {}
    for r in ss:
        for t in r.get("top", []):
            by_cmd[t["cmd"]] = by_cmd.get(t["cmd"], 0.0) + t["cores"]
    scale = span / len(ss)

    return {
        "available": True,
        "schema": 1,
        "machine": {
            "host": meta.get("host"),
            "slurm_job": meta.get("slurm_job"),
            "cpus_allocated": ncpu,
            "gpus_allocated": ngpu,
            "gpu_names": sorted({
                v.get("name") for r in ss for v in (r.get("gpu") or {}).values()
                if v.get("name")
            }) or None,
        },
        "wall_seconds": round(span, 1),
        "phases": [phase_record(lab, s, e) for lab, s, e in ph],
        "unattributed_seconds": round(max(0.0, span - covered), 1),
        "totals": {
            "mean_cpu_cores": round(cpu, 2),
            "mean_gpu_percent": round(gpu, 1) if gpu is not None else None,
            "peak_rss_gib": round(mem, 2),
            "peak_io_mb_per_s": round(io, 1),
        },
        # The number that actually drives optimisation: how much of what was
        # reserved was delivered.
        "delivered": {
            "gpu_seconds": round(gpu_seconds, 1) if gpu_seconds is not None else None,
            "gpu_seconds_allocated": round(ngpu * span, 1) if ngpu else None,
            "gpu_percent_of_allocation": (
                round(100.0 * gpu_seconds / max(1e-9, ngpu * span), 1)
                if gpu_seconds is not None else None
            ),
            "core_seconds": round(core_seconds, 1),
            "core_seconds_allocated": round(ncpu * span, 1),
            "core_percent_of_allocation": round(
                100.0 * core_seconds / max(1e-9, ncpu * span), 1
            ),
        },
        "top_cpu_consumers": [
            {"command": cmd, "core_seconds": round(v * scale, 1)}
            for cmd, v in sorted(by_cmd.items(), key=lambda kv: -kv[1])[:8]
        ],
    }


def _write(path, record):
    text = json.dumps(record, indent=2, sort_keys=False)
    if path == "-":
        print(text)
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(text + "\n")
    print("resmon: wrote %s" % path, file=sys.stderr)


if __name__ == "__main__":
    main()
