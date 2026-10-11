"""Win rate / reward per driver and instance from the arena's result files."""
import glob
import json
import os
from collections import defaultdict


def read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf8") as f:
            for ln in f:
                ln = ln.strip()
                if ln:
                    try:
                        out.append(json.loads(ln))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def summarize(run_dir, last=0):
    """-> list of dict rows: one per (inst, driver) with games / wins / win rate / mean reward per match."""
    per = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(run_dir, "results", "inst*.jsonl"))):
        for r in read_jsonl(path):
            if r.get("result") in ("win", "loss"):
                per[(r.get("inst"), r.get("driver"))].append(r)
    out = []
    for (inst, drv), rows in sorted(per.items(), key=lambda kv: (kv[0][0] or 0)):
        rows = sorted(rows, key=lambda r: r.get("t", 0))
        if last:
            rows = rows[-last:]
        wins = sum(1 for r in rows if r["result"] == "win")
        rt = [r["reward_total"] for r in rows if isinstance(r.get("reward_total"), (int, float))]
        out.append({"inst": inst, "driver": drv, "games": len(rows), "wins": wins,
                    "win_rate": wins / len(rows) if rows else 0.0,
                    "mean_reward": sum(rt) / len(rt) if rt else None,
                    "mean_ante": sum(r.get("ante") or 0 for r in rows) / len(rows) if rows else 0.0})
    return out


def decisions_by_src(run_dir):
    c = defaultdict(int)
    for path in glob.glob(os.path.join(run_dir, "decisions", "inst*.jsonl")):
        for r in read_jsonl(path):
            c["%s:%s" % (r.get("kind"), r.get("src"))] += 1
    return dict(c)


def format_table(rows):
    lines = ["inst  driver      games  wins  win%   mean reward/match  mean ante"]
    for r in rows:
        mr = "%.1f" % r["mean_reward"] if r["mean_reward"] is not None else "-"
        lines.append("%-5s %-11s %5d %5d %5.1f%%  %16s  %8.2f" % (r["inst"], r["driver"], r["games"], r["wins"], 100 * r["win_rate"], mr, r["mean_ante"]))
    return "\n".join(lines)
