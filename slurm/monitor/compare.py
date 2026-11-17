#!/usr/bin/env python3
"""Two profiles side by side: which phase moved, and by how much.

The tool for the optimisation loop -- a run is only faster if a named phase got
shorter, and this says which one did.

    slurm-monitor compare --before resmon-out/baseline --after resmon-out/try-3
"""
import argparse, json, os


def load(d):
    rows = [json.loads(l) for l in open(os.path.join(d, "samples.jsonl"))]
    meta = next((r for r in rows if r["type"] == "meta"), {})
    ss = [r for r in rows if r["type"] == "s"]
    evp = os.path.join(d, "events.jsonl")
    evs = [json.loads(l) for l in open(evp)] if os.path.exists(evp) else []
    stack, ph = {}, {}
    for e in sorted(evs, key=lambda e: e["t"]):
        lab, kind = e.get("label", ""), e.get("kind", "point")
        if kind == "phase-start":
            stack.setdefault(lab, []).append(e["t"])
        elif kind == "phase-end" and stack.get(lab):
            ph[lab] = ph.get(lab, 0.0) + (e["t"] - stack[lab].pop())
    total = (ss[-1]["t"] - ss[0]["t"]) if ss else 0.0
    return meta, ph, total, ss


def hms(s):
    s = int(round(abs(s)))
    return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    a = ap.parse_args()

    mb, pb, tb, sb = load(a.before)
    ma, pa, ta, sa = load(a.after)

    # Drop the nested embed marks. A five-model build emits one "embed: <model>"
    # band per model and up to sixteen "embed <model>/<variant>[/<csv>]" marks
    # inside it, and summing the inner ones just reproduces the outer one under a
    # name one character different from it -- two rows saying the same thing.
    def group(ph):
        outer = {k for k in ph if k.startswith("embed: ")}
        models = {k[len("embed: "):] for k in outer}
        out = {}
        for k, v in ph.items():
            if k.startswith("embed ") and k.split("/")[0][len("embed "):] in models:
                continue                     # covered by its "embed: <model>" band
            out[k] = out.get(k, 0.0) + v
        return out

    gb, ga = group(pb), group(pa)
    keys = sorted(set(gb) | set(ga), key=lambda k: -(max(gb.get(k, 0), ga.get(k, 0))))

    print("=" * 88)
    print("%-44s %10s %10s %10s %7s" % ("phase", "before", "after", "delta", ""))
    print("=" * 88)
    for k in keys:
        x, y = gb.get(k, 0.0), ga.get(k, 0.0)
        d = y - x
        ratio = ("%.2fx" % (x / y)) if y > 0.5 and x > 0 else ""
        print("%-44s %10s %10s %10s %7s"
              % (k[:44], hms(x), hms(y), ("-" if d < 0 else "+") + hms(d), ratio))
    print("-" * 88)
    print("%-44s %10s %10s %10s %7s"
          % ("WALL CLOCK", hms(tb), hms(ta),
             ("-" if ta < tb else "+") + hms(ta - tb),
             ("%.2fx" % (tb / ta)) if ta > 0 else ""))

    def util(ss, meta):
        if not ss:
            return 0.0, 0.0
        g = [v["util"] or 0 for r in ss for v in (r.get("gpu") or {}).values()]
        return (sum(r.get("cpu_cores", 0) for r in ss) / len(ss),
                (sum(g) / len(g)) if g else 0.0)
    cb, ub = util(sb, mb)
    ca, ua = util(sa, ma)
    print("%-44s %9.1fc %9.1fc" % ("mean CPU cores", cb, ca))
    print("%-44s %9.0f%% %9.0f%%" % ("mean GPU utilisation", ub, ua))
    print("=" * 88)


if __name__ == "__main__":
    main()
