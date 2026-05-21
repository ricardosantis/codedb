# reader.md — experimental codebase-map for codedb

Experiment branch: `experiment/reader-md`. **No codedb runtime changes.** Spec + prototype + eval only.

## TL;DR

A hash-stable, ≤200-LOC, agent-authored markdown file at `.codedb/reader.md` that codedb can prepend to `codedb_context` responses so a fresh agent gets one-shot orientation. Measured against codedb v0.2.5816:

- **−31% tool calls** vs control (avg of 3 tasks)
- **−40% wall time**
- **−25% tokens consumed**
- **0/6 quality regressions**

T2 regex saw a **70%** call reduction because the multi-crate workspace structure is exactly what a map disambiguates. T3 react saw only 0% / 9% / 8% because the map didn't cover the specific subsystem the task targeted — a useful negative data point about source-file selection.

## Contents

- [`SPEC.md`](SPEC.md) — file format, frontmatter, hash protocol, lifecycle, open questions
- [`readers/`](readers/) — generated `reader.md` for 3 corpora:
  - [`flask.md`](readers/flask.md) — 107 LOC, 10 source files
  - [`regex.md`](readers/regex.md) — 80 LOC, 10 source files
  - [`react.md`](readers/react.md) — 95 LOC, 8 source files
- [`eval/TASKS.md`](eval/TASKS.md) — task definitions + conditions
- [`eval/RESULTS.md`](eval/RESULTS.md) — raw numbers, deltas, threats to validity

## Cost to generate reader.md

| Corpus | LOC | Tool calls | Wall (s) |
|---|---:|---:|---:|
| flask | 107 | 22 | 147 |
| regex | 80 | 18 | 183 |
| react | 95 | 22 | 204 |

~31k tokens per generation (one-time per source_hash drift). Pays for itself after ~3 tasks.

## Hash protocol

```python
import hashlib
def source_hash(files: list[str]) -> str:
    h = hashlib.blake2b(digest_size=16)
    for f in sorted(files):
        h.update(f.encode()); h.update(b"\0")
        with open(f, "rb") as fp: h.update(fp.read())
        h.update(b"\0\0")
    return "blake2b:" + h.hexdigest()
```

Deterministic. Codedb can verify on every scan; mismatch ⇒ stale ⇒ regenerate.

## Side-finding

All 3 sub-agents flagged the same UX gap during reader generation: `codedb read` doesn't handle absolute paths cleanly (silent exit 1). Worth a small follow-up fix.

## What this experiment does NOT do

- Wire reader.md into the codedb runtime
- Implement the regeneration policy (when to mark stale, who selects source_files)
- Compare against `codedb_context` (only against raw codedb CLI)
- Run at scale (3×3 only)

## If this gets prioritized

See [`SPEC.md` § Sequencing](SPEC.md#sequencing-if-this-gets-prioritized) and [`eval/RESULTS.md` § Recommended next steps](eval/RESULTS.md#recommended-next-steps-if-this-gets-prioritized).
