#!/usr/bin/env python3
"""samples.jsonl + events.jsonl -> one figure. A shared time axis, the
pipeline's own phases shaded across every panel.

An application may add its own curves: <dir>/series.jsonl, one JSON line per
moment and panel,

    {"t": <unix seconds>, "panel": "<name>", "unit": "<unit>",
     "values": {"<label>": <number>, ...}}

Panel "cpu" (cores) and panel "memory" (bytes) are drawn into the figure's own
CPU and memory panels, beside the job's; any other name is a panel of its own,
above the disk, its unit on the axis. A label "GPU <n>" takes card n's colour.
What the curves mean is the application's; the monitor only draws them.

SVG by default. The figure is published beside the index and rendered in the
frontend, where a raster of a chart is a chart nobody can read at the size
their screen happens to be — and the axis labels are text, so they should stay
text. `--out something.png` still works for a quick local look."""
import argparse, json, os
import matplotlib
matplotlib.use("Agg")
# matplotlib's default ("path") makes a figure that cannot be selected, copied
# or searched in a browser -- the labels look like text and behave like a
# drawing. "none" emits <text> elements naming the font family, so a reader can
# select a phase label or a value off the published figure, and a screen reader
# can read it.
matplotlib.rcParams["svg.fonttype"] = "none"
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

BLUE, ORANGE, AQUA, YELLOW, MAGENTA = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#8a8880"
GRID = "#e6e5e1"

#: One colour per GPU, up to eight. The previous version drew every card in the same
#: aqua at alpha 0.55, so "individual GPU" was a single indistinguishable smear and the
#: question the panel exists to answer -- is the work spread across the cards, or is one
#: of them doing all of it? -- could not be read off it.
GPU_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#b8860b", "#7d4fa3",
              "#c2185b", "#0097a7", "#5d4037"]


def hms(seconds):
    """Elapsed time as h:mm:ss, or mm:ss for a run under an hour.

    The axis used to be bare seconds since start -- "2500" on a chart of a build whose
    phases are quoted everywhere else in minutes and seconds, so every reading needed
    mental arithmetic against the summary beside it.
    """
    seconds = int(round(seconds))
    h, rem = divmod(seconds, 3600)
    m, sec = divmod(rem, 60)
    return "%d:%02d:%02d" % (h, m, sec) if h else "%d:%02d" % (m, sec)


def time_axis(ax, span):
    """Ticks on a round number of minutes, chosen so there are six to ten of them."""
    for step in (30, 60, 120, 300, 600, 900, 1800, 3600, 7200):
        if span / step <= 10:
            break
    ticks = [t for t in range(0, int(span) + step, step) if t <= span]
    ax.set_xticks(ticks)
    ax.set_xticklabels([hms(t) for t in ticks])
    ax.set_xlim(0, span)


def phases(evs):
    stack, out = {}, []
    for e in sorted(evs, key=lambda e: e["t"]):
        lab, kind = e.get("label", ""), e.get("kind", "point")
        if kind == "phase-start":
            stack.setdefault(lab, []).append(e["t"])
        elif kind == "phase-end" and stack.get(lab):
            out.append((lab, stack[lab].pop(), e["t"]))
    return sorted(out, key=lambda p: p[1])


#: Panels of series.jsonl drawn into the figure's own, and the scale that turns
#: their values into the panel's unit.
OVERLAY = {"cpu", "memory"}
SERIES_COLORS = [AQUA, MAGENTA, YELLOW, BLUE, ORANGE, "#7d4fa3", "#0097a7", "#5d4037"]


def read_series(path):
    """series.jsonl -> {panel: {"unit": str, "lines": {label: [(t, value)]}}}, in
    the order panels first appear. Lines that do not parse are skipped: an
    application's curves must not cost the job its figure."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        try:
            r = json.loads(line)
            t, name = float(r["t"]), str(r["panel"])
            values = r.get("values") or {}
        except (ValueError, KeyError, TypeError):
            continue
        panel = out.setdefault(name, {"unit": r.get("unit") or "", "lines": {}})
        for label, v in values.items():
            if isinstance(v, (int, float)):
                panel["lines"].setdefault(str(label), []).append((t, float(v)))
    for panel in out.values():
        for pts in panel["lines"].values():
            pts.sort()
    return out


def overlay(ax, panel, t0, scale):
    """An application's lines in one of the figure's own panels (dashed, so the
    job's measurement stays the solid line)."""
    if not panel:
        return
    for i, (label, pts) in enumerate(sorted(panel["lines"].items())):
        ax.plot([t - t0 for t, _ in pts], [v / scale for _, v in pts],
                color=SERIES_COLORS[i % len(SERIES_COLORS)], lw=1.3, ls=(0, (4, 2)),
                label=label)


def style(ax, ylabel):
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)
    ax.grid(True, axis="y", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=8, length=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--title", default=None)
    a = ap.parse_args()

    rows = [json.loads(l) for l in open(os.path.join(a.dir, "samples.jsonl"))]
    meta = next((r for r in rows if r["type"] == "meta"), {})
    ss = [r for r in rows if r["type"] == "s"]
    evp = os.path.join(a.dir, "events.jsonl")
    evs = [json.loads(l) for l in open(evp)] if os.path.exists(evp) else []
    ph = phases(evs)
    t0 = min([r["t"] for r in ss] + [p[1] for p in ph])
    x = [r["t"] - t0 for r in ss]

    series = read_series(os.path.join(a.dir, "series.jsonl"))
    extra = [name for name in series if name not in OVERLAY]

    # Five panels, not four. The old figure had one GPU panel showing a mean and eight
    # identically coloured lines, and no GPU MEMORY at all -- so "did we fill the cards"
    # and "did we nearly run out of VRAM" were both unanswerable from it, and the second
    # is what a build fails on. The application's own panels go between GPU memory and
    # the disk, which stays last: it carries the time axis.
    fig, axes = plt.subplots(5 + len(extra), 1, figsize=(13, 12.5 + 2.0 * len(extra)), sharex=True,
                             gridspec_kw={"height_ratios": [2.0, 1.6, 2.0, 1.7] + [1.6] * len(extra) + [1.3],
                                          "hspace": 0.30})
    fig.patch.set_facecolor("#fcfcfb")
    for ax in axes:
        ax.set_facecolor("#fcfcfb")

    # ---- phase bands.
    #
    # Only the outer phases are shaded and labelled. A five-model build emits ~90
    # marks, most of them one CSV of one variant of one model, and shading all of
    # them turns the background into noise and the labels into a smear. The inner
    # ones are drawn as tick marks along the top instead: still visible as
    # structure, not competing for the same strip of text. The full list with
    # durations is in summary.txt, which is the right place to read numbers.
    span_total = max(1e-9, max(e for _, _, e in ph) - t0) if ph else 1.0
    outer = [(lab, s, e) for lab, s, e in ph if "/" not in lab]
    inner = [(lab, s, e) for lab, s, e in ph if "/" in lab]
    if not outer:                              # no nesting in this run: shade what there is
        outer, inner = ph, []

    # Bands must not overlap, or the alternating shading stops meaning anything and
    # two labels land on the same centimetre. They can overlap now: with
    # --embed-concurrency several `embed: <model>` phases run at once inside one
    # enclosing phase. Greedy by start time keeps the enclosing band and drops what
    # runs inside it -- which is the right band to keep, because the whole point of
    # the picture is that those models shared the cards.
    nonoverlapping, until = [], None
    for lab, s_, e_ in sorted(outer, key=lambda p_: (p_[1], -p_[2])):
        if until is not None and s_ < until:
            inner.append((lab, s_, e_))
            continue
        nonoverlapping.append((lab, s_, e_))
        until = e_
    outer = nonoverlapping

    for i, (lab, s, e) in enumerate(outer):
        for ax in axes:
            ax.axvspan(s - t0, e - t0, color=GRID if i % 2 == 0 else "#f2f1ee",
                       zorder=0, lw=0)
            ax.axvline(s - t0, color="#cfcec9", lw=0.8, zorder=0)
    for _, s, e in inner:
        axes[0].axvline(s - t0, color="#d9d8d3", lw=0.5, zorder=0,
                        ymin=0.965, ymax=1.0)

    # Label only what there is room for; a band under ~4% of the run cannot hold
    # its own name without overlapping its neighbour.
    shown = [(lab, s, e) for lab, s, e in outer if (e - s) / span_total >= 0.04]
    for i, (lab, s, e) in enumerate(shown):
        # Model names run to 50 characters; the band they name is a tenth of the
        # axis. Trim to the distinctive part and stagger two rows so adjacent
        # labels cannot collide.
        short = lab.split(": ", 1)[-1]
        short = short[:24] + "\u2026" if len(short) > 25 else short
        axes[0].annotate(short, xy=((s + e) / 2 - t0, 1.015 + 0.045 * (i % 2)),
                         xycoords=("data", "axes fraction"),
                         ha="center", va="bottom", fontsize=8, color=INK2)

    # ---- 1. CPU: ours, the neighbours, and what we were given
    ncpu = meta.get("ncpu_alloc")
    axes[0].fill_between(x, [r["cpu_cores"] for r in ss], color=BLUE, alpha=0.18, lw=0)
    axes[0].plot(x, [r["cpu_cores"] for r in ss], color=BLUE, lw=1.8, label="this job")
    if any("other_jobs_cores" in r for r in ss):
        # Measured, not inferred: the other SLURM jobs' cgroups. The rest of the
        # node's busy time -- interrupts and kernel threads, which no cgroup is
        # charged for -- is mostly this job's own kernel side when it is alone
        # on the node (it rises with the embedding phases and vanishes between
        # them), and is drawn as such rather than as a neighbour.
        axes[0].plot(x, [r.get("other_jobs_cores", 0) for r in ss], color=ORANGE, lw=1.4,
                     label="other jobs on the node")
        axes[0].plot(x, [r.get("node_irq_cores", 0) + r.get("unattributed_cores", 0) for r in ss],
                     color=MUTED, lw=1.0, ls=(0, (2, 2)),
                     label="outside every job cgroup: interrupts, driver and kernel threads (or "
                           "tenants, on a node SLURM does not partition)")
    elif any("other_cores" in r for r in ss):
        axes[0].plot(x, [r.get("other_cores", 0) for r in ss], color=ORANGE, lw=1.4,
                     label="the node minus this job (neighbours AND kernel time)")
    # The allocation line is only meaningful where there IS an allocation. In
    # --subtree mode (a dev container with no cpuset) "384 cores allocated" is
    # the size of the machine, not a budget, and drawing it flattens the series
    # against the axis for no information.
    if ncpu and not meta.get("subtree_of"):
        axes[0].axhline(ncpu, color=MUTED, lw=1.2, ls=(0, (4, 3)))
        axes[0].annotate("%d cores allocated" % ncpu, xy=(0.998, ncpu),
                         xycoords=("axes fraction", "data"),
                         ha="right", va="bottom", fontsize=8, color=MUTED)
        axes[0].set_ylim(0, ncpu * 1.12)
    overlay(axes[0], series.get("cpu"), t0, 1.0)
    style(axes[0], "CPU cores busy")
    # Outside the axes. Inside, it sat on top of the allocation line and its label.
    # Above the phase labels, which take the strip right over the panel: with an
    # application's line in it the legend's second row ran through them.
    axes[0].legend(frameon=False, fontsize=8, loc="lower left", labelcolor=INK2,
                   bbox_to_anchor=(0, 1.11), ncol=2)

    # ---- 2. host memory: ours, split by what it is
    #
    # anon is what the job allocated; file is page cache it caused. They behave
    # differently under pressure -- cache is reclaimable, anon is not -- so a single
    # "job memory" line cannot say whether a run is near its limit or merely warm.
    anon = [(r.get("mem_anon") or 0) / 2**30 for r in ss]
    total = [(r.get("mem_bytes") or 0) / 2**30 for r in ss]
    axes[1].fill_between(x, anon, color=YELLOW, alpha=0.35, lw=0, label="anonymous (allocated)")
    axes[1].fill_between(x, anon, total, color=YELLOW, alpha=0.14, lw=0, label="page cache")
    axes[1].plot(x, total, color=YELLOW, lw=1.6)
    node_total = next((r.get("node_mem_total") for r in ss if r.get("node_mem_total")), None)
    if any(r.get("node_mem_used") for r in ss):
        axes[1].plot(x, [(r.get("node_mem_used") or 0) / 2**30 for r in ss],
                     color=MUTED, lw=1.2, ls=(0, (4, 3)), label="whole node")
    if node_total:
        axes[1].annotate("node has %.0f GB" % (node_total / 2**30), xy=(0.998, 0.92),
                         xycoords="axes fraction", ha="right", va="top",
                         fontsize=8, color=MUTED)
    overlay(axes[1], series.get("memory"), t0, 2**30)
    style(axes[1], "memory GB")
    axes[1].legend(frameon=False, fontsize=8, loc="upper left", labelcolor=INK2, ncol=3)

    # ---- 3. GPU compute, one line per card
    g_keys = sorted({k for r in ss for k in (r.get("gpu") or {})}, key=int)
    for i, k in enumerate(g_keys):
        axes[2].plot(x, [(r.get("gpu") or {}).get(k, {}).get("util") or 0 for r in ss],
                     color=GPU_COLORS[i % len(GPU_COLORS)], lw=1.0, alpha=0.85,
                     label="GPU %s" % k)
    if g_keys:
        mean = [sum((r.get("gpu") or {}).get(k, {}).get("util") or 0 for k in g_keys)
                / len(g_keys) for r in ss]
        axes[2].fill_between(x, mean, color=INK2, alpha=0.10, lw=0)
        axes[2].plot(x, mean, color=INK, lw=2.0, label="mean of %d" % len(g_keys))
    axes[2].set_ylim(0, 104)
    style(axes[2], "GPU compute %")
    if g_keys:
        # Above the panel, not in it: at the foot the entries sat on the series
        # themselves wherever a card was idle, which is most of a build. One legend
        # serves both GPU panels -- they share the colours by construction.
        axes[2].legend(frameon=False, fontsize=7.5, loc="lower left", labelcolor=INK2,
                       bbox_to_anchor=(0, 1.02), ncol=min(9, len(g_keys) + 1),
                       columnspacing=1.1, handlelength=1.4)

    # ---- 4. GPU memory, one line per card
    #
    # The panel that would have named the ceiling. A build with three models embedding
    # at once died with "CUDA out of memory" on cuda:6, and the figure published beside
    # it had nothing to show for that: memory per card was sampled and never drawn.
    cap = next((v.get("mem_total_mb") for r in ss for v in (r.get("gpu") or {}).values()
                if v.get("mem_total_mb")), None)
    for i, k in enumerate(g_keys):
        axes[3].plot(x, [((r.get("gpu") or {}).get(k, {}).get("mem_mb") or 0) / 1024
                         for r in ss],
                     color=GPU_COLORS[i % len(GPU_COLORS)], lw=1.0, alpha=0.85)
    if cap:
        axes[3].axhline(cap / 1024, color=MUTED, lw=1.2, ls=(0, (4, 3)))
        axes[3].annotate("%.1f GB per card" % (cap / 1024), xy=(0.998, cap / 1024),
                         xycoords=("axes fraction", "data"), ha="right", va="top",
                         fontsize=8, color=MUTED)
        axes[3].set_ylim(0, cap / 1024 * 1.08)
    style(axes[3], "GPU memory GB")
    axes[3].annotate("one line per card, coloured as above", xy=(0.002, 0.04),
                     xycoords="axes fraction", ha="left", va="bottom", fontsize=8,
                     color=MUTED)

    # ---- the application's own panels
    gpu_colour = {"GPU %s" % k: GPU_COLORS[i % len(GPU_COLORS)] for i, k in enumerate(g_keys)}
    for ax, name in zip(axes[4:-1], extra):
        lines = series[name]["lines"]
        for i, (label, pts) in enumerate(sorted(lines.items())):
            ax.plot([t - t0 for t, _ in pts], [v for _, v in pts],
                    color=gpu_colour.get(label, SERIES_COLORS[i % len(SERIES_COLORS)]),
                    lw=1.3, label=label)
        unit = series[name]["unit"]
        style(ax, "%s\n(%s)" % (name, unit) if unit else name)
        ax.set_ylim(bottom=0)
        if len(lines) > 1:
            ax.legend(frameon=False, fontsize=7.6, loc="lower left", labelcolor=INK2,
                      bbox_to_anchor=(0, 1.005), ncol=min(9, len(lines)),
                      columnspacing=2.4, handlelength=1.4)

    # ---- 5. disk, and how much of the run was spent waiting for it
    disk = axes[-1]
    disk.plot(x, [r.get("write_bps", 0) / 1e6 for r in ss], color=MAGENTA, lw=1.6,
                 label="write MB/s")
    disk.plot(x, [r.get("read_bps", 0) / 1e6 for r in ss], color=MAGENTA, lw=1.2,
                 ls=(0, (3, 2)), label="read MB/s")
    style(disk, "disk MB/s")
    # Its own axis: a stall percentage on a scale that reaches 4,000 MB/s is a flat
    # line on the floor, which is how it read before.
    stall = disk.twinx()
    stall.plot(x, [r.get("psi_io", {}).get("some10", 0) for r in ss], color=INK2, lw=1.3,
               label="stalled on I/O %")
    stall.set_ylim(0, 104)
    stall.set_ylabel("stalled %", color=INK2, fontsize=9)
    stall.tick_params(colors=MUTED, labelsize=8, length=0)
    for side in ("top", "left"):
        stall.spines[side].set_visible(False)
    stall.spines["right"].set_color(GRID)
    # Built by hand. get_lines() also returns the artists matplotlib creates for the
    # grid, which arrived in the legend as "_child1", "_child3", "_child5".
    handles = [plt.Line2D([], [], color=MAGENTA, lw=1.6, label="write MB/s"),
               plt.Line2D([], [], color=MAGENTA, lw=1.2, ls=(0, (3, 2)), label="read MB/s"),
               plt.Line2D([], [], color=INK2, lw=1.3, label="stalled on I/O %")]
    disk.legend(handles=handles, frameon=False, fontsize=8, loc="upper left",
                   labelcolor=INK2, ncol=3)
    disk.set_xlabel("elapsed", color=INK2, fontsize=9)

    time_axis(disk, max(x) if x else 1)

    t = a.title or "%s · %s" % (meta.get("host", "?"),
                                "SLURM job %s" % meta["slurm_job"] if meta.get("slurm_job") else "local")
    fig.subplots_adjust(top=0.90)
    fig.suptitle(t, x=0.005, y=0.995, ha="left", va="top", fontsize=13, color=INK, weight="bold")
    sub = ("sampled from this job's own process tree — a neighbour's work is excluded by construction"
           if meta.get("subtree_of") else
           "sampled from this job's own cgroup — a neighbour's work is excluded by construction")
    fig.text(0.005, 0.967, sub, ha="left", va="top", fontsize=9, color=INK2)

    out = a.out or os.path.join(a.dir, "utilisation.svg")
    # dpi still matters for an SVG: matplotlib uses it to convert point sizes
    # to user units, so a wrong one gives correct-but-oddly-scaled text.
    fig.savefig(out, dpi=100, bbox_inches="tight", facecolor=fig.get_facecolor())
    print("wrote", out)


if __name__ == "__main__":
    main()
