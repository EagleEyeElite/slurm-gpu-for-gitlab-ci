#!/usr/bin/env python3
"""resmon - sample *this job's* resource usage, not the node's.

Writes one JSON object per line to --out. Stdlib only; works on python3.6+.

Attribution: everything CPU/memory/IO comes from the cgroup that owns this
process (under SLURM: /sys/fs/cgroup/.../job_<id>), so a neighbour's job on the
same node never shows up. GPU numbers come from nvidia-smi, which inside a SLURM
allocation only sees the GPUs that were allocated to it.

Events: append lines to $RESMON_EVENTS (see `slurm-monitor mark`) and they land in the
same directory for the plotter to overlay.
"""
import argparse, json, os, re, signal, subprocess, sys, threading, time

CLK = os.sysconf("SC_CLK_TCK")


def find_cgroup():
    """Directory to attribute usage to: the SLURM job cgroup if we are in one,
    else the outermost cgroup we can still read (a container's own root)."""
    try:
        with open("/proc/self/cgroup") as f:
            rel = [l.split(":", 2)[2].strip() for l in f if l.startswith("0::")][0]
    except Exception:
        rel = "/"
    full = os.path.join("/sys/fs/cgroup", rel.lstrip("/"))
    m = re.match(r"(.*/job_\d+)", full)          # SLURM: stop at the job, not the step
    if m and os.path.isdir(m.group(1)):
        return m.group(1)
    while full != "/sys/fs/cgroup" and not os.path.exists(os.path.join(full, "cpu.stat")):
        full = os.path.dirname(full)
    return full


def read_kv(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) >= 2:
                    try:
                        out[p[0]] = int(p[1])
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def read_psi(path):
    """cpu.pressure etc -> {'some10':.., 'full10':..} percent of time stalled."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                d = dict(kv.split("=") for kv in p[1:] if "=" in kv)
                if "avg10" in d:
                    out[p[0] + "10"] = float(d["avg10"])
    except OSError:
        pass
    return out


def cpuset_count(cg):
    try:
        with open(os.path.join(cg, "cpuset.cpus.effective")) as f:
            spec = f.read().strip()
    except OSError:
        return os.cpu_count()
    n = 0
    for part in spec.split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-")
            n += int(b) - int(a) + 1
        else:
            n += 1
    return n or os.cpu_count()


def subtree_pids(root_pid):
    """Every PID descended from root_pid, including it.

    The escape hatch for a machine where the cgroup is bigger than the thing
    being measured -- e.g. a notebook container that also holds an IDE and a
    shell. Under SLURM the cgroup is already exactly the job, so this is unused
    there.
    """
    children = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as f:
                rest = f.read()
            ppid = int(rest[rest.rfind(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        children.setdefault(ppid, []).append(int(entry))
    out, stack = [], [int(root_pid)]
    while stack:
        pid = stack.pop()
        out.append(pid)
        stack.extend(children.get(pid, ()))
    return out


def cgroup_pids(cg):
    pids = []
    for root, dirs, _ in os.walk(cg):
        try:
            with open(os.path.join(root, "cgroup.procs")) as f:
                pids.extend(int(x) for x in f.read().split())
        except OSError:
            pass
    return pids


def proc_snapshot(pids):
    """Per-PID cpu ticks + rss + io, keyed by pid. Cheap: 3 small reads per pid."""
    snap = {}
    for pid in pids:
        try:
            with open("/proc/%d/stat" % pid) as f:
                s = f.read()
            comm = s[s.find("(") + 1:s.rfind(")")]
            rest = s[s.rfind(")") + 2:].split()
            ticks = int(rest[11]) + int(rest[12])          # utime + stime
            rss = int(rest[21]) * 4096                      # pages -> bytes
            threads = int(rest[17])
        except (OSError, ValueError, IndexError):
            continue
        rd = wr = 0
        try:
            with open("/proc/%d/io" % pid) as f:
                for line in f:
                    if line.startswith("read_bytes:"):
                        rd = int(line.split()[1])
                    elif line.startswith("write_bytes:"):
                        wr = int(line.split()[1])
        except OSError:
            pass
        snap[pid] = (comm, ticks, rss, threads, rd, wr)
    return snap


def node_cpu_busy():
    """Node-wide busy jiffies from /proc/stat, and the kernel-side part of them.

    Subtracting our own cgroup from the busy total used to be the whole story of
    "other". It is not: a cgroup is charged the user and system time of ITS
    tasks, and the node's busy jiffies also hold interrupt and softirq time and
    the kernel's own threads (the NVIDIA driver's, NFS writeback, ...), which no
    job cgroup is charged for. On a GPU index build "other" ran at 1.4-3.4
    cores during EVERY embedding phase and ~0 during the CSV write and the index
    phase, on a node with no other job -- and correlated 0.57-0.75 with the
    job's own cores. That is the job's kernel-side cost of driving eight cards
    wearing a neighbour's label. The split below lets the plot say which it is;
    other_jobs_cores (sibling job cgroups, read directly) is the neighbours.

    Returns (busy, total, irq) where irq is the hardirq+softirq jiffies."""
    try:
        with open("/proc/stat") as f:
            p = f.readline().split()
        vals = [int(x) for x in p[1:11]]
        idle = vals[3] + vals[4]                 # idle + iowait
        return sum(vals) - idle, sum(vals), vals[5] + vals[6]
    except (OSError, ValueError, IndexError):
        return None, None, None


def sibling_job_cgroups(cg):
    """The other SLURM jobs' cgroups on this node, or [] outside SLURM."""
    m = re.match(r"(.*)/job_\d+$", cg)
    if not m:
        return []
    parent = m.group(1)
    try:
        return [os.path.join(parent, d) for d in os.listdir(parent)
                if d.startswith("job_") and os.path.join(parent, d) != cg
                and os.path.isdir(os.path.join(parent, d))]
    except OSError:
        return []


def jobs_cpu_usec(cgroups):
    """Summed cpu.stat usage of the given cgroups, in microseconds."""
    total = 0
    for c in cgroups:
        total += read_kv(os.path.join(c, "cpu.stat")).get("usage_usec", 0)
    return total


def node_mem():
    out = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                if k in ("MemTotal", "MemAvailable"):
                    out[k] = int(v.split()[0]) * 1024
    except (OSError, ValueError):
        pass
    return out


GPU_FIELDS = ("index,utilization.gpu,utilization.memory,memory.used,memory.total,"
              "power.draw,clocks.sm,temperature.gpu")


class GpuPoller(threading.Thread):
    """Streams `nvidia-smi -l 1` so we never pay a fork per sample."""
    daemon = True

    def __init__(self, interval):
        super().__init__()
        self.latest = {}
        self.lock = threading.Lock()
        self.interval = max(1, int(round(interval)))
        self.proc = None

    def run(self):
        cmd = ["nvidia-smi", "--query-gpu=" + GPU_FIELDS,
               "--format=csv,noheader,nounits", "-l", str(self.interval)]
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return
        batch = {}
        for line in self.proc.stdout:
            p = [x.strip() for x in line.split(",")]
            if len(p) < 8:
                continue
            def num(x):
                try:
                    return float(x)
                except ValueError:
                    return None
            idx = p[0]
            if idx in batch:                                # wrapped -> new round
                with self.lock:
                    self.latest = batch
                batch = {}
            batch[idx] = {"util": num(p[1]), "memutil": num(p[2]),
                          "mem_mb": num(p[3]), "mem_total_mb": num(p[4]),
                          "power_w": num(p[5]), "sm_mhz": num(p[6]), "temp_c": num(p[7])}
            with self.lock:
                merged = dict(self.latest)
                merged.update(batch)
                self.latest = merged

    def snapshot(self):
        with self.lock:
            return dict(self.latest)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()



class PmonPoller(threading.Thread):
    """Streams `nvidia-smi pmon`, which reports sm%% and GPU memory *per PID*.

    This is what separates "the GPU is busy" from "the GPU is busy with MY work"
    on a box where the card is shared (a shared notebook node). Inside a SLURM
    allocation the GPUs are ours exclusively and this merely confirms it.
    """
    daemon = True

    def __init__(self, interval):
        super().__init__()
        self.latest = {}          # (gpu_idx, pid) -> {"sm":, "mem":, "cmd":}
        self.lock = threading.Lock()
        self.interval = max(1, int(round(interval)))
        self.proc = None

    def run(self):
        cmd = ["nvidia-smi", "pmon", "-d", str(self.interval), "-s", "um"]
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return
        batch, seen = {}, set()
        for line in self.proc.stdout:
            if line.startswith("#"):
                continue
            p = line.split()
            if len(p) < 4:
                continue
            gpu, pid = p[0], p[1]
            if pid == "-":                       # idle GPU row
                if gpu in seen:
                    with self.lock:
                        self.latest = batch
                    batch, seen = {}, set()
                seen.add(gpu)
                continue
            if (gpu, pid) in batch:              # wrapped -> new round
                with self.lock:
                    self.latest = batch
                batch, seen = {}, set()
            seen.add(gpu)
            def num(x):
                try:
                    return float(x)
                except ValueError:
                    return 0.0
            batch[(gpu, pid)] = {"sm": num(p[3]), "mem": num(p[4]) if len(p) > 4 else 0.0,
                                 "cmd": p[-1]}
            with self.lock:
                merged = dict(self.latest)
                merged.update(batch)
                self.latest = merged

    def snapshot(self):
        with self.lock:
            return dict(self.latest)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--top", type=int, default=8, help="per-sample top-N processes by CPU")
    ap.add_argument("--no-gpu", action="store_true")
    ap.add_argument("--subtree", type=int, default=None,
                    help="Attribute to this PID and its descendants instead of the "
                         "whole cgroup. For machines where the cgroup holds more "
                         "than the job (a dev container); unnecessary under SLURM.")
    args = ap.parse_args()

    cg = find_cgroup()
    ncpu = cpuset_count(cg)
    pids_of = (lambda: subtree_pids(args.subtree)) if args.subtree else (lambda: cgroup_pids(cg))
    gpu = pmon = None
    if not args.no_gpu:
        gpu = GpuPoller(args.interval)
        gpu.start()
        pmon = PmonPoller(args.interval)
        pmon.start()

    # One sampler per output file. Two of them appending to the same file
    # interleave their samples, and the result looks like a plausible profile
    # with twice the sample rate and nonsensical deltas -- which is exactly what
    # a retry loop around `srun --overlap` produced once. Better to refuse.
    lock = args.out + ".lock"
    try:
        with open(lock) as fh:
            other = int(fh.read().strip() or 0)
        os.kill(other, 0)
    except (OSError, ValueError):
        pass
    else:
        sys.stderr.write(
            "resmon: %s is already being sampled by pid %d; refusing to interleave.\n"
            % (args.out, other))
        return 1
    with open(lock, "w") as fh:
        fh.write(str(os.getpid()))

    out = open(args.out, "a", buffering=1)
    meta = {"type": "meta", "t": time.time(), "cgroup": cg, "ncpu_alloc": ncpu,
            "host": os.uname().nodename, "pid": os.getpid(),
            "slurm_job": os.environ.get("SLURM_JOB_ID"),
            "slurm_step": os.environ.get("SLURM_STEP_ID"),
            "ci_job": os.environ.get("CI_JOB_ID"),
            "ci_job_name": os.environ.get("CI_JOB_NAME"),
            "mem_max": read_int(os.path.join(cg, "memory.max")),
            "cuda_visible": os.environ.get("CUDA_VISIBLE_DEVICES"),
            "subtree_of": args.subtree}
    out.write(json.dumps(meta) + "\n")

    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    node_ncpu = os.cpu_count()
    prev_nbusy, prev_ntot, prev_nirq = node_cpu_busy()
    prev_others = jobs_cpu_usec(sibling_job_cgroups(cg))
    prev_t = time.time()
    prev_cpu = read_kv(os.path.join(cg, "cpu.stat")).get("usage_usec", 0)
    prev_procs = proc_snapshot(pids_of())

    while not stop.is_set():
        stop.wait(args.interval)
        now = time.time()
        dt = now - prev_t
        if dt <= 0:
            continue

        cpu = read_kv(os.path.join(cg, "cpu.stat"))
        cur_cpu = cpu.get("usage_usec", 0)
        cores = (cur_cpu - prev_cpu) / 1e6 / dt

        pids = pids_of()
        procs = proc_snapshot(pids)

        # per-command CPU cores + IO deltas, so a chart can show *who* was busy
        by_cmd = {}
        rd_tot = wr_tot = 0
        for pid, (comm, ticks, rss, thr, rd, wr) in procs.items():
            p = prev_procs.get(pid)
            d_ticks = ticks - p[1] if p else ticks
            d_rd = rd - p[4] if p else 0
            d_wr = wr - p[5] if p else 0
            e = by_cmd.setdefault(comm, [0.0, 0, 0, 0])
            e[0] += max(0.0, d_ticks / CLK / dt)
            e[1] += rss
            e[2] += thr
            e[3] += 1
            rd_tot += max(0, d_rd)
            wr_tot += max(0, d_wr)
        top = sorted(by_cmd.items(), key=lambda kv: -kv[1][0])[:args.top]
        if args.subtree:
            # cpu.stat covers the whole cgroup, which is more than we were asked
            # to measure; the per-process deltas above are the subtree exactly.
            cores = sum(v[0] for v in by_cmd.values())

        mstat = read_kv(os.path.join(cg, "memory.stat"))
        rec = {
            "type": "s", "t": now,
            "cpu_cores": round(cores, 3),
            "cpu_pct_alloc": round(100.0 * cores / ncpu, 2) if ncpu else None,
            "mem_bytes": (sum(v[1] for v in by_cmd.values()) if args.subtree
                          else read_int(os.path.join(cg, "memory.current"))),
            "mem_anon": mstat.get("anon"), "mem_file": mstat.get("file"),
            "psi_cpu": read_psi(os.path.join(cg, "cpu.pressure")),
            "psi_io": read_psi(os.path.join(cg, "io.pressure")),
            "psi_mem": read_psi(os.path.join(cg, "memory.pressure")),
            "read_bps": round(rd_tot / dt), "write_bps": round(wr_tot / dt),
            "nproc": len(procs), "nthread": sum(v[2] for v in by_cmd.values()),
            "top": [{"cmd": c, "cores": round(v[0], 3), "rss": v[1], "n": v[3]} for c, v in top],
        }
        nbusy, ntot, nirq = node_cpu_busy()
        others_usec = jobs_cpu_usec(sibling_job_cgroups(cg))
        if nbusy is not None and prev_nbusy is not None and ntot > prev_ntot:
            node_cores = node_ncpu * (nbusy - prev_nbusy) / float(ntot - prev_ntot)
            rec["node_cores"] = round(node_cores, 2)
            rec["node_ncpu"] = node_ncpu
            # The node minus us. Kept under its old name so older plots read it,
            # but it is NOT the neighbours: see node_cpu_busy.
            rec["other_cores"] = round(max(0.0, node_cores - cores), 2)
            # The neighbours, measured rather than inferred: the other SLURM
            # jobs' cgroups on this node.
            rec["other_jobs_cores"] = round(max(0.0, (others_usec - prev_others) / 1e6 / dt), 2)
            # Interrupt and softirq time, which no cgroup is charged for.
            rec["node_irq_cores"] = round(node_ncpu * (nirq - prev_nirq) / float(ntot - prev_ntot), 2)
            # What is left: kernel threads and anything else outside every job
            # cgroup -- on a node where the job is alone, the job's own kernel
            # side.
            rec["unattributed_cores"] = round(
                max(0.0, node_cores - cores - rec["other_jobs_cores"] - rec["node_irq_cores"]), 2)
        prev_nbusy, prev_ntot, prev_nirq = nbusy, ntot, nirq
        prev_others = others_usec
        nm = node_mem()
        if nm:
            rec["node_mem_used"] = nm.get("MemTotal", 0) - nm.get("MemAvailable", 0)
            rec["node_mem_total"] = nm.get("MemTotal")

        if gpu:
            rec["gpu"] = gpu.snapshot()
        if pmon:
            mine = set(str(p) for p in pids)
            per, others = {}, {}
            for (g, pid), v in pmon.snapshot().items():
                tgt = per if pid in mine else others
                e = tgt.setdefault(g, {"sm": 0.0, "mem_mb": 0.0, "procs": []})
                e["sm"] += v["sm"]
                e["mem_mb"] += v["mem"]
                e["procs"].append(v["cmd"])
            rec["gpu_mine"] = per          # our share of each GPU
            rec["gpu_others"] = others     # a neighbour on the same card
        out.write(json.dumps(rec) + "\n")

        prev_t, prev_cpu, prev_procs = now, cur_cpu, procs

    if gpu:
        gpu.stop()
    if pmon:
        pmon.stop()
    out.write(json.dumps({"type": "meta", "t": time.time(), "event": "resmon_stop"}) + "\n")
    out.close()
    try:
        os.unlink(lock)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
