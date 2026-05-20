# search-shootout — Results

**Corpus:** facebook/react (shallow clone), 6,619 indexable files, 26.5 MB code
**Machine:** Apple Silicon, macOS 25.4
**Date:** 2026-05-20
**SQLite:** 3.51.0 (FTS5 trigram tokenizer available)
**codedb:** local build, current branch `issue-447-failing-test`
**lean-ctx:** 3.6.9 from crates.io

Raw latency table: [results/react-2026-05-20.md](results/react-2026-05-20.md).
This file is the human-readable synthesis.

---

## 1. Build phase (cold index from scratch)

| Backend | Time | On-disk |
|---|---|---|
| **fts5_unicode61** | **0.45s** | 36 MB |
| fts5_trigram | 1.87s | 94 MB |
| lean-ctx (BM25 + JSON graph + SQLite graph) | 8.3s | n/a — stored outside expected paths |
| codedb (snapshot + trigram + word index + dep graph + outlines) | 12.1s | 41 MB |

**Takeaway:** Word-tokenized FTS5 is ~27x faster to build than codedb and uses
comparable disk. Trigram FTS5 takes ~4x its space (expected — 3-shingles
explode the postings list) but is still ~6x faster than codedb to build.
codedb's extra build time pays for the structural outline, word-index, and
reverse dep graph that the FTS5 backends don't have.

---

## 2. Query latency — warm p50 (ms)

Select rows from the per-query table:

| Query | kind | fts5_uni | fts5_tri | codedb | lean-ctx |
|---|---|---|---|---|---|
| `useState` | common-identifier | **0.03** | 1.63 | 3.97 | 683 |
| `Fiber` | substring-identifier | 0.01 | 0.14 | 3.62 | 756 |
| `flushPassiveEffects` | rare-camelcase | 0.01 | 0.23 | 167.68 | 842 |
| `function` | lang-keyword | 0.10 | 2.10 | 4.66 | 789 |
| `set` | short-trigram-exact | 0.02 | 0.04 | 3.00 | 763 |
| `xyzzy_react_does_not_exist` | negative | 0.04 | 0.21 | 113.39 | 865 |

Full 15-query table in [results/react-2026-05-20.md](results/react-2026-05-20.md).

**Latency takeaways:**

1. **fts5_unicode61** is the fastest by a wide margin (sub-100µs almost always)
   because it hits an inverted-word index directly. **Trade-off:** it misses
   substring matches — `Fiber` finds 180 files (whole-word "Fiber"), whereas
   trigram finds 303 (substring inside `ReactFiber*`, `getRootForUpdatedFiber`, etc).
2. **fts5_trigram** is sub-millisecond on common queries, low single-digit ms
   on stress queries. **Trade-off:** 2.5x bigger index, no BM25 ranking
   advantage on substring queries.
3. **codedb** is in the low-millisecond range for most queries, with two
   outliers worth investigating:
   - `flushPassiveEffects` → 167ms p50 (rare-camelcase)
   - `xyzzy_react_does_not_exist` → 113ms p50 (negative)
   The negative-query slowness is the more concerning of the two — looks like
   a missed early-exit when no trigram exists.
4. **lean-ctx grep** is ~700–1700ms **per call** because every invocation
   pays Rust binary startup + jemalloc init. The lean-ctx daemon helps with
   index queries but doesn't help binary startup. From an MCP/HTTP front-end
   it would be much faster, but from a script or shell it's painful.

---

## 3. Recall (hit-count, with caveats)

Hit counts are **not directly comparable** — codedb caps display at 50 lines,
lean-ctx caps at 20 displayed (header reports true count via "N matches in M
files"), FTS5 counts files. Use these to check for missing recall, not for
ranking.

| Query | fts5_tri | fts5_uni | codedb (capped) | lean-ctx |
|---|---|---|---|---|
| `useState` | 674 files | 674 files | 42 (display cap) | 20 (display cap) |
| `Fiber` | 303 files | 180 files | 50 (cap) | 20 |
| `flushPassiveEffects` | 8 files | 7 files | 21 lines | 20 |
| `enableTransitionTracing` | 25 files | 25 files | 12 lines | 20 |
| `xyzzy_react_does_not_exist` | 0 | 0 | 0 | 0 |

`fts5_uni` underreports on substring queries (`Fiber`: 180 vs 303) because the
word-boundary tokenizer can't see substrings inside identifiers. This is the
single biggest functional difference between unicode61 and trigram in a code
context.

---

## 4. Agentic traversal eval

Three Sonnet 4.6 sub-agents were given the same exploration task:

> Find the function in React's reconciler that decides **which lanes to render
> next** when the scheduler picks up work. Report file, function, snippet, and
> eligibility rule.

Each agent was restricted to **one backend's CLI** (no Read, no grep, no
ripgrep, no peeking with other tools).

| Backend | Tool calls | Wall seconds | Found correct answer? |
|---|---|---|---|
| **fts5_trigram (sqlite3)** | **5** | **25** | ✅ getNextLanes, with snippet from FTS5 `snippet()` + body substring extraction |
| codedb (search/find/outline) | 10 | 44 | ✅ getNextLanes, with snippet from outline + targeted searches |
| lean-ctx (grep/read) | 16 | 123 | ✅ getNextLanes, but **had to reconstruct snippet from multiple grep probes** |

### Notes from each agent

**fts5_trigram** (winner):
> "FTS5 trigram search located the file instantly; `snippet()` function was too
> narrow (60 tokens) to show full function body, so substr+instr was needed to
> extract the relevant section directly from the stored body column —
> effective workaround but slightly awkward."

**codedb**:
> "codedb search was highly effective: a single `search getNextLanes` call
> pinpointed the exact file and line, and the outline tool showed all variable
> declarations inside the function body at a glance. Multi-word phrase search
> sometimes returned no results when terms were not adjacent in source,
> requiring decomposition into single key terms."

**lean-ctx** (slowest by 5x):
> "lean-ctx grep output is highly compressed via alpha-symbol substitution
> (α1, α2…) with a §MAP footer — useful for cross-file deduplication but
> obscures exact source lines; `lean-ctx read` returns only a 3-line metadata
> summary for large files making it **unusable for reading function bodies
> directly**; had to reconstruct the snippet from multiple grep probes rather
> than a direct read."

This is the most damning finding for lean-ctx: its compression aggressively
strips information the agent needs, and its `read` mode wasn't usable on
real-world file sizes. The token savings come at a real **task-completion
latency cost** in this scenario. *(Caveat: when lean-ctx is consumed via its
MCP server inside a Claude-Code-style chat, the compression interacts
differently with the LLM's context window — this eval measures CLI use only.)*

---

## 5. Where codedb is genuinely ahead

- **Structural outline + dep graph + word index** in one snapshot — none of
  the FTS5 setups give you `outline` or callers/deps. The 12s build time pays
  for these.
- **File watcher** keeps the snapshot live; FTS5 here was rebuilt from
  scratch, lean-ctx requires manual `index build` invocation.
- **MCP-native warm queries**: ~3ms for typical queries vs lean-ctx's ~700ms
  CLI-spawn cost. (Not a fair fight in CLI-vs-CLI, but it is a fair fight in
  the agent UX.)

## Where codedb has room to close gaps

- **Negative-query slowness** (113ms p50 for `xyzzy_react_does_not_exist`)
  suggests a missed early-exit when no trigram in the query exists in the
  index. Cheap fix.
- **`flushPassiveEffects` outlier** (167ms p50) — rare camelcase queries seem
  to fall through to a slow tier. Worth profiling.
- **Hit-display cap** of 50 is conservative; for agentic use, the cap matters
  more than for human use because the agent doesn't paginate.

## Where FTS5 alone is not enough

- No outline / signatures view → agent has to read whole files to get
  structure.
- No call graph / reverse-dep graph.
- No watcher; index goes stale after every commit.

These are the things lean-ctx and codedb add on top of an inverted-index
substrate.

---

## 6. Negative-query short-circuit — shipped

The bench surfaced a slow path that turned out to be a 6-line fix.

`searchContent` had a Tier 5 full-scan fallback that fired whenever every
earlier tier returned 0 results. For a query whose trigrams don't exist
anywhere in the corpus (a definitively-negative query), Tiers 0–4 all
no-op and Tier 5 still scanned every file in `outlines` — measurable as
113ms p50 on the React corpus.

The fix: when `trigram_index.candidates(query)` returns a non-null but
empty candidate set and `query.len >= 3`, every trigram-indexed file is
provably free of the query. The only files that could still contain a
match are `skip_trigram_files`, which Tier 3 already scanned. Tier 5 can
be skipped.

| Query | Before | After | Speedup |
|---|---|---|---|
| `xyzzy_react_does_not_exist` | 113.39ms p50 | **0.29ms** p50 | **390x** |

A test-only counter `Explorer.search_tier5_count` was added so the
regression is observable in a deterministic unit test (no time-based
flakes). Before the fix, the counter goes to 1 for the failing test;
after, it stays at 0.

See commits on branch `issue-negq-shortcircuit-failing-test`:

- `test(explore): failing test for negative-query Tier 5 short-circuit`
- `fix(explore): short-circuit Tier 5 full scan when trigram rules out match`

## 6. Recommendations

1. **For codedb:** the FTS5 trigram numbers are the most relevant competitor
   for the substring-search path. They suggest a `unicode61`-style word-index
   could shave 100x off the *common-identifier* path — but you already have
   the Tier-0 word index from v0.2.58, so the gap is smaller than it looks.
   The real wins are: (a) fix the negative-query slow path, (b) profile
   `flushPassiveEffects`-shaped queries, (c) consider exposing a configurable
   result cap higher than 50 for agent consumers.
2. **For benchmark methodology:** add a "warm CLI" mode for lean-ctx that
   avoids the per-call binary startup (e.g., via its `serve` HTTP endpoint or
   MCP stdio) — otherwise lean-ctx looks ~700x slower than it really is when
   used MCP-resident inside an agent.
3. **What FTS5+BM25 cannot replace:** if you swap to FTS5 you lose
   outline/find/deps/word-index. The "swap to FTS5" plan only works as a
   complement to a structural index, not a replacement.

---

## Reproducing

See [README.md](README.md). Short version:

```bash
mkdir -p ~/codedb-bench
git clone --depth 1 https://github.com/facebook/react ~/codedb-bench/react
python3 shootout.py --corpus ~/codedb-bench/react \
                    --out results/react-$(date +%Y-%m-%d).md \
                    --clean-codedb
```
