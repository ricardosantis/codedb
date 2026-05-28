"""Regenerate summary.json from per-task validator result JSONs.

A patch is 'applied' if its validator ran (status == validated); 'tried' if a
non-empty patch existed (anything other than no_patch / MISSING). checks_pass /
checks_total sum the per-check booleans across validated tasks only.

'*_err' keys are error-marker companions emitted by the validators — they pass
exactly when the real check raised an exception, so they are excluded from the
score (this matches the methodology in VALIDATION.md).
"""
import json, os

RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")
TASKS = [
    "langchain-request-coalescing",
    "fastapi-implicit-head-options",
    "fastapi-deprecation-response-headers",
    "textual-richlog-follow-state",
    "numba-stencil-boundary-modes",
]
VARIANTS = ["codedb", "graphify", "codegraph", "leanctx", "baseline"]


def load(task, variant):
    path = os.path.join(RESULTS_DIR, f"{task}_{variant}.json")
    if not os.path.exists(path):
        return {"status": "MISSING"}
    return json.load(open(path))


def real_checks(d):
    return {k: v for k, v in d.get("checks", {}).items() if not k.endswith("_err")}


per_task = {}
variant_summary = {
    v: {"checks_pass": 0, "checks_total": 0, "patches_applied": 0,
        "patches_tried": 0, "non_empty_patches": 0}
    for v in VARIANTS
}

for task in TASKS:
    per_task[task] = {}
    for v in VARIANTS:
        d = load(task, v)
        status = d.get("status", "MISSING")
        if status == "MISSING":
            per_task[task][v] = {"status": "MISSING"}
            continue
        if status == "validated":
            checks = real_checks(d)
            p = sum(1 for x in checks.values() if x)
            t = len(checks)
            s = variant_summary[v]
            s["checks_pass"] += p
            s["checks_total"] += t
            s["patches_applied"] += 1
            s["patches_tried"] += 1
            s["non_empty_patches"] += 1
            per_task[task][v] = {"status": status, "pass": p, "total": t}
        elif status == "patch_failed":
            variant_summary[v]["patches_tried"] += 1
            variant_summary[v]["non_empty_patches"] += 1
            per_task[task][v] = {"status": status, "pass": 0, "total": 0}
        else:  # no_patch and anything else with no usable checks
            per_task[task][v] = {"status": status, "pass": 0, "total": 0}

out = {"variant_summary": variant_summary, "per_task": per_task}
with open(os.path.join(os.path.dirname(__file__), "summary.json"), "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")

for v in VARIANTS:
    s = variant_summary[v]
    pct = 100 * s["checks_pass"] / s["checks_total"] if s["checks_total"] else 0
    print(f"{v:10} {s['checks_pass']:>3}/{s['checks_total']:<3} ({pct:4.1f}%)  "
          f"applied {s['patches_applied']}/5  tried {s['patches_tried']}/5")
