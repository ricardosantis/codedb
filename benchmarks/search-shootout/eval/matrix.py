#!/usr/bin/env python3
"""Aggregate scores + answer metadata into a QD matrix (markdown + JSON).

Reads:
    tasks.json, backends.json, answers/, scores/scores.json
Writes:
    qd_matrix.md         (human-readable matrix)
    qd_matrix.json       (machine-readable)
"""
import json, sys
from pathlib import Path
from collections import defaultdict
NL = chr(10)
from statistics import mean, median, stdev

HERE = Path(__file__).resolve().parent

def load():
    tasks = json.loads((HERE / "tasks.json").read_text())
    backends = json.loads((HERE / "backends.json").read_text())
    scores_p = HERE / "scores" / "scores.json"
    scores = json.loads(scores_p.read_text()) if scores_p.exists() else []
    answers = {}
    for tdir in (HERE / "answers").iterdir():
        if not tdir.is_dir(): continue
        for f in tdir.glob("*-rep*.json"):
            backend, _, repstr = f.stem.rpartition("-rep")
            answers[(tdir.name, backend, int(repstr))] = json.loads(f.read_text())
    return tasks, backends, scores, answers

def stats_of(xs):
    if not xs: return None
    xs = list(xs)
    return {
        "n": len(xs),
        "mean": mean(xs),
        "median": median(xs),
        "stdev": stdev(xs) if len(xs) > 1 else 0.0,
        "min": min(xs), "max": max(xs),
    }

def build_matrix(tasks, backends, scores, answers):
    """Returns dict: cells[(task, backend)] = aggregated stats over reps."""
    by_cell = defaultdict(list)
    for s in scores:
        by_cell[(s["task"], s["backend"])].append(s)
    cells = {}
    for (task, backend), rows in by_cell.items():
        totals = [r["total"] for r in rows]
        # Pull tokens/wall/calls from answer files when present
        toks, walls, calls = [], [], []
        for r in rows:
            a = answers.get((task, backend, r["rep"]))
            if not a: continue
            if "tokens" in a: toks.append(a["tokens"])
            if "wall_seconds" in a: walls.append(a["wall_seconds"])
            if "tool_calls" in a: calls.append(a["tool_calls"])
        cells[(task, backend)] = {
            "quality": stats_of(totals),
            "tokens":  stats_of(toks),
            "wall":    stats_of(walls),
            "calls":   stats_of(calls),
            "reps":    [r["rep"] for r in rows],
        }
    return cells

def fmt_stat(s, fmt="{:.1f}"):
    if not s: return "—"
    if s["n"] == 1: return fmt.format(s["mean"])
    return f"{fmt.format(s['mean'])}±{fmt.format(s['stdev'])} (n={s['n']})"

def render_markdown(tasks, backends, cells):
    out = []
    out.append("# QD Matrix — code-search-shootout")
    out.append("")
    out.append(f"Tasks: {len(tasks)}  ·  Backends: {len(backends)}  ·  Filled cells: {len(cells)}")
    out.append("")
    out.append("## Quality (out of 5) — mean per cell")
    out.append("")
    header = ["task"] + [b["id"] for b in backends]
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for t in tasks:
        row = [f"`{t['id']}`"]
        for b in backends:
            c = cells.get((t["id"], b["id"]))
            row.append(fmt_stat(c["quality"], "{:.2f}") if c else "—")
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("### Per-backend averages (across all tasks where measured)")
    out.append("")
    out.append("| backend | avg quality | avg tokens | avg wall (s) | avg calls | tokens / quality-point |")
    out.append("|---|---|---|---|---|---|")
    for b in backends:
        qs, toks, walls, calls = [], [], [], []
        for t in tasks:
            c = cells.get((t["id"], b["id"]))
            if not c: continue
            if c["quality"]: qs.append(c["quality"]["mean"])
            if c["tokens"]: toks.append(c["tokens"]["mean"])
            if c["wall"]: walls.append(c["wall"]["mean"])
            if c["calls"]: calls.append(c["calls"]["mean"])
        if not qs:
            out.append(f"| {b['id']} | — | — | — | — | — |"); continue
        aq, at_ = mean(qs), mean(toks) if toks else 0
        aw, ac = mean(walls) if walls else 0, mean(calls) if calls else 0
        tpq = (at_ / aq) if aq > 0 else 0
        out.append(f"| **{b['id']}** | {aq:.2f} | {at_:,.0f} | {aw:.1f} | {ac:.1f} | {tpq:,.0f} |")
    out.append("")
    out.append("## Efficiency (tokens) — mean per cell")
    out.append("")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for t in tasks:
        row = [f"`{t['id']}`"]
        for b in backends:
            c = cells.get((t["id"], b["id"]))
            row.append(fmt_stat(c["tokens"], "{:,.0f}") if c else "—")
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## Wall time (seconds) — mean per cell")
    out.append("")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for t in tasks:
        row = [f"`{t['id']}`"]
        for b in backends:
            c = cells.get((t["id"], b["id"]))
            row.append(fmt_stat(c["wall"], "{:.1f}") if c else "—")
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## Pareto frontier")
    out.append("")
    out.append("A backend is **Pareto-dominant** if no other backend beats it on all three axes (quality higher, tokens lower, wall lower).")
    out.append("")
    rows = []
    for b in backends:
        qs, toks, walls = [], [], []
        for t in tasks:
            c = cells.get((t["id"], b["id"]))
            if not c: continue
            if c["quality"]: qs.append(c["quality"]["mean"])
            if c["tokens"]: toks.append(c["tokens"]["mean"])
            if c["wall"]: walls.append(c["wall"]["mean"])
        if not qs: continue
        rows.append({"backend": b["id"], "q": mean(qs), "tok": mean(toks) if toks else 0, "wall": mean(walls) if walls else 0})
    def dominates(a, b):
        return a["q"] >= b["q"] and a["tok"] <= b["tok"] and a["wall"] <= b["wall"] and (a["q"] > b["q"] or a["tok"] < b["tok"] or a["wall"] < b["wall"])
    for r in rows:
        dominators = [o["backend"] for o in rows if o is not r and dominates(o, r)]
        if not dominators:
            r["status"] = "**PARETO-OPTIMAL**"
        else:
            r["status"] = "dominated by: " + ", ".join(dominators)
    out.append("| backend | quality | tokens | wall (s) | status |")
    out.append("|---|---|---|---|---|")
    for r in sorted(rows, key=lambda x: -x["q"]):
        out.append(f"| {r['backend']} | {r['q']:.2f} | {r['tok']:,.0f} | {r['wall']:.1f} | {r['status']} |")
    out.append("")
    return "\n".join(out)

def render_map_elites(tasks, backends, cells):
    """MAP-Elites style grid: rows = behavioral niches (query_type), cols =
    backends. Each cell shows the (quality, tokens, wall) achieved on tasks
    matching that niche, aggregated across reps."""
    # Group tasks by niche (query_type axis); if a task has no `niche` field,
    # bucket under "uncategorized".
    niches = {}
    for t in tasks:
        niche_key = t.get("niche", {}).get("query_type", "uncategorized")
        niches.setdefault(niche_key, []).append(t["id"])

    out = []
    out.append("## MAP-Elites grid")
    out.append("")
    out.append("Rows = behavioral niche (`query_type`). Cols = backend.")
    out.append("Each cell shows aggregated (quality / tokens / wall) over tasks in that niche.")
    out.append("**Bold** = best in row on quality; *italic* = best in row on tokens.")
    out.append("")
    header = ["niche"] + [b["id"] for b in backends]
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for niche, task_ids in niches.items():
        # For each backend, aggregate across all tasks in this niche
        row_stats = {}
        from statistics import median as _med
        def _agg(values):
            # Use median when n>=3 to be robust against single-rep outliers
            # (e.g. pre-fix-build artifacts dragging the mean).
            return _med(values) if len(values) >= 3 else mean(values)
        for b in backends:
            qs, toks, walls = [], [], []
            for tid in task_ids:
                c = cells.get((tid, b["id"]))
                if not c: continue
                # Use median of reps within this cell (n>=3) or mean
                if c.get("quality"):
                    qs.append(c["quality"].get("median", c["quality"]["mean"]))
                if c.get("tokens"):
                    toks.append(c["tokens"].get("median", c["tokens"]["mean"]))
                if c.get("wall"):
                    walls.append(c["wall"].get("median", c["wall"]["mean"]))
            if qs:
                row_stats[b["id"]] = {
                    "q": _agg(qs), "tok": _agg(toks) if toks else 0,
                    "wall": _agg(walls) if walls else 0,
                }
            else:
                row_stats[b["id"]] = None
        # Find best quality + best tokens in row
        valid = [(k,v) for k,v in row_stats.items() if v]
        best_q = max(valid, key=lambda x: x[1]["q"])[0] if valid else None
        best_t = min(valid, key=lambda x: x[1]["tok"] if x[1]["tok"] > 0 else 1e18)[0] if valid else None
        cells_row = [f"`{niche}` ({len(task_ids)} task{'s' if len(task_ids)>1 else ''})"]
        for b in backends:
            s = row_stats[b["id"]]
            if not s:
                cells_row.append("—"); continue
            q_str = f"{s['q']:.2f}"
            t_str = f"{s['tok']:,.0f}"
            w_str = f"{s['wall']:.1f}s"
            if b["id"] == best_q: q_str = f"**{q_str}**"
            if b["id"] == best_t: t_str = f"*{t_str}*"
            cells_row.append(f"{q_str} / {t_str} / {w_str}")
        out.append("| " + " | ".join(cells_row) + " |")
    out.append("")
    # Tally "wins" per backend
    out.append("### Niche wins per backend")
    out.append("")
    win_tally = {b["id"]: {"q": 0, "tok": 0} for b in backends}
    for niche, task_ids in niches.items():
        row_stats = {}
        from statistics import median as _med
        def _agg(values):
            return _med(values) if len(values) >= 3 else mean(values)
        for b in backends:
            qs, toks = [], []
            for tid in task_ids:
                c = cells.get((tid, b["id"]))
                if not c: continue
                if c.get("quality"):
                    qs.append(c["quality"].get("median", c["quality"]["mean"]))
                if c.get("tokens"):
                    toks.append(c["tokens"].get("median", c["tokens"]["mean"]))
            if qs:
                row_stats[b["id"]] = {"q": _agg(qs), "tok": _agg(toks) if toks else 0}
        valid = [(k,v) for k,v in row_stats.items() if v]
        if valid:
            best_q_key = max(valid, key=lambda x: x[1]["q"])[0]
            best_t_key = min(valid, key=lambda x: x[1]["tok"] if x[1]["tok"] > 0 else 1e18)[0]
            win_tally[best_q_key]["q"] += 1
            win_tally[best_t_key]["tok"] += 1
    out.append("| backend | niches won on quality | niches won on tokens |")
    out.append("|---|---|---|")
    for b in backends:
        out.append(f"| {b['id']} | {win_tally[b['id']]['q']} | {win_tally[b['id']]['tok']} |")
    out.append("")
    return NL.join(out)


def main():
    tasks, backends, scores, answers = load()
    cells = build_matrix(tasks, backends, scores, answers)
    md_path = HERE / "qd_matrix.md"
    js_path = HERE / "qd_matrix.json"
    md_content = render_markdown(tasks, backends, cells)
    me_content = render_map_elites(tasks, backends, cells)
    md_path.write_text(md_content + chr(10) + me_content)
    js_path.write_text(json.dumps({
        "tasks": [t["id"] for t in tasks],
        "backends": [b["id"] for b in backends],
        "cells": [{"task": t, "backend": b, **stats} for (t, b), stats in cells.items()],
    }, indent=2, default=str))
    print(f"wrote {md_path}")
    print(f"wrote {js_path}")
    print()
    print(md_path.read_text())

if __name__ == "__main__":
    main()
