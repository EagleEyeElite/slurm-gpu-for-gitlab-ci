#!/usr/bin/env python3
"""samples.jsonl + events.jsonl -> a Chrome/Perfetto trace.

The point of this file: the *viewer* is off the shelf. Drop the output on
https://ui.perfetto.dev (it runs locally in the browser, nothing is uploaded)
and you get utilization counter tracks and the pipeline's own phases as slices
on one shared, zoomable time axis -- which is exactly the "events on the x
axis" ask, without standing up Prometheus and Grafana to get it.
"""
import argparse, json, os

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    rows = [json.loads(l) for l in open(os.path.join(a.dir, "samples.jsonl"))]
    meta = next((r for r in rows if r["type"] == "meta"), {})
    ss = [r for r in rows if r["type"] == "s"]
    evp = os.path.join(a.dir, "events.jsonl")
    evs = [json.loads(l) for l in open(evp)] if os.path.exists(evp) else []
    t0 = min([r["t"] for r in ss] + [e["t"] for e in evs])
    us = lambda t: int((t - t0) * 1e6)

    ev = []
    pid, tid = 1, 1
    ev.append({"ph": "M", "pid": pid, "name": "process_name", "args":
               {"name": "%s job %s" % (meta.get("host", "?"), meta.get("slurm_job") or "local")}})

    def counter(name, series, ts):
        ev.append({"ph": "C", "pid": pid, "name": name, "ts": ts, "args": series})

    for r in ss:
        ts = us(r["t"])
        c = {"mine": r.get("cpu_cores", 0)}
        if "other_cores" in r:
            c["others on node"] = r["other_cores"]
        counter("CPU cores", c, ts)
        counter("Memory GB", {"rss": round((r.get("mem_bytes") or 0) / 2**30, 2)}, ts)
        g = r.get("gpu") or {}
        if g:
            counter("GPU util %%", {"gpu%s" % k: (g[k]["util"] or 0) for k in sorted(g, key=int)}, ts)
            counter("GPU power W", {"total": round(sum(v["power_w"] or 0 for v in g.values()), 1)}, ts)
        counter("Disk MB/s", {"read": round(r.get("read_bps", 0) / 1e6, 1),
                              "write": round(r.get("write_bps", 0) / 1e6, 1)}, ts)
        counter("Stall %% (PSI)", {"cpu": r.get("psi_cpu", {}).get("some10", 0),
                                   "io": r.get("psi_io", {}).get("some10", 0)}, ts)

    # phases -> slices; the pipeline's own marks, on the same axis as the counters
    stack = {}
    for e in sorted(evs, key=lambda e: e["t"]):
        lab, kind = e.get("label", ""), e.get("kind", "point")
        if kind == "phase-start":
            stack.setdefault(lab, []).append(e["t"])
        elif kind == "phase-end" and stack.get(lab):
            st = stack[lab].pop()
            ev.append({"ph": "X", "pid": pid, "tid": tid, "name": lab,
                       "ts": us(st), "dur": us(e["t"]) - us(st)})
        else:
            ev.append({"ph": "i", "pid": pid, "tid": tid, "name": lab, "ts": us(e["t"]), "s": "g"})

    out = a.out or os.path.join(a.dir, "trace.json")
    json.dump({"traceEvents": ev, "displayTimeUnit": "ms"}, open(out, "w"))
    print("wrote %s (%d events, %.1fs span)" % (out, len(ev), (max(r["t"] for r in ss) - t0)))

if __name__ == "__main__":
    main()
