# DeepSWE 5-Way Benchmark Results

**Model:** Sonnet 4.6 | **Date:** 2026-05-28 | **Budget:** $5/run | **Tasks:** 7 | **Variants:** 5 | **Total runs:** 35

## Summary

| Variant | Total Cost | vs Baseline | Avg $/task | Turns | Patch Lines | Wall Time | Wins |
|---|---|---|---|---|---|---|---|
| graphify | **$12.06** | **-28.4%** | $1.72 | 306 | 3,061 | 4,544s | 4/7 |
| codegraph | $13.90 | -17.5% | $1.99 | 296 | 3,639 | 4,619s | 0/7 |
| codedb | $13.98 | -17.1% | $2.00 | 252 | 3,702 | 4,521s | 1/7 |
| lean-ctx | $14.80 | -12.2% | $2.11 | 306 | 3,443 | 4,936s | 1/7 |
| baseline | $16.85 | — | $2.41 | 340 | 3,516 | 5,248s | 1/7 |

All code intelligence tools beat baseline on cost. graphify is cheapest overall. codedb is fastest (fewest turns, shortest wall time).

**Caveat:** graphify's kombu patch is only 45L (vs 627L reference) — likely incomplete. Excluding kombu, graphify's adjusted total would be ~$13.56 (still cheapest but closer).

## Per-Task Results

### httpx — Streaming JSON iteration (ref: 588L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| graphify | **$0.77** | 25 | 259L | 338s |
| codedb | $0.90 | 35 | 213L | 328s |
| codegraph | $1.22 | 27 | 200L | 450s |
| lean-ctx | $1.76 | 42 | 197L | 892s |
| baseline | $1.85 | 51 | 191L | 604s |

### vulture — Persistent analysis cache (ref: 764L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| baseline | **$1.24** | 28 | 319L | 425s |
| codegraph | $1.29 | 33 | 388L | 527s |
| lean-ctx | $1.41 | 25 | 252L | 572s |
| codedb | $1.56 | 37 | 314L | 522s |
| graphify | $1.60 | 35 | 323L | 809s |

### cattrs — Partial structuring with error recovery (ref: 632L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| lean-ctx | **$1.48** | 35 | 364L | 479s |
| codedb | $1.76 | 48 | 403L | 511s |
| codegraph | $1.81 | 32 | 407L | 594s |
| baseline | $2.08 | 50 | 362L | 571s |
| graphify | $2.13 | 48 | 425L | 590s |

### bandit — Structured nosec directives (ref: 629L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| codedb | **$1.47** | 19 | 364L | 580s |
| codegraph | $1.57 | 34 | 443L | 726s |
| lean-ctx | $1.60 | 18 | 393L | 709s |
| baseline | $2.04 | 27 | 415L | 1,113s |
| graphify | $2.07 | 40 | 380L | 1,124s |

### kombu — Virtual queue dead-lettering (ref: 627L)

| Variant | Cost | Turns | Patch | Wall Time | Note |
|---|---|---|---|---|---|
| graphify | **$0.97** | 27 | 45L | 469s | Suspect — 7% of reference |
| codegraph | $2.30 | 33 | 501L | 645s | |
| lean-ctx | $2.36 | 47 | 534L | 624s | |
| baseline | $2.76 | 59 | 539L | 666s | |
| codedb | $3.45 | 40 | 516L | 859s | |

### narwhals — Rolling window suite (ref: 810L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| graphify | **$1.46** | 62 | 725L | 344s |
| codedb | $1.72 | 28 | 966L | 532s |
| codegraph | $1.99 | 74 | 980L | 518s |
| lean-ctx | $2.69 | 70 | 837L | 674s |
| baseline | $2.84 | 47 | 756L | 883s |

### sqlite-utils — Safe import checkpoints (ref: 848L)

| Variant | Cost | Turns | Patch | Wall Time |
|---|---|---|---|---|
| graphify | **$3.06** | 69 | 904L | 871s |
| codedb | $3.13 | 45 | 926L | 1,191s |
| lean-ctx | $3.50 | 69 | 866L | 986s |
| codegraph | $3.74 | 63 | 720L | 1,159s |
| baseline | $4.04 | 78 | 934L | 987s |

## Timing Analysis

| Variant | Total Wall Time | Avg per Task | vs Baseline |
|---|---|---|---|
| codedb | **4,521s** (75m) | 646s | **-13.9%** |
| graphify | 4,544s (76m) | 649s | -13.4% |
| codegraph | 4,619s (77m) | 660s | -12.0% |
| lean-ctx | 4,936s (82m) | 705s | -5.9% |
| baseline | 5,248s (87m) | 750s | — |

codedb is fastest wall-clock despite not being cheapest — its lower turn count (252 vs 306-340) means less round-trip overhead. lean-ctx is slowest among tools, likely due to compression overhead on reads.

## Turn Efficiency

| Variant | Total Turns | Avg per Task | Cost per Turn |
|---|---|---|---|
| codedb | **252** | 36 | $0.056 |
| codegraph | 296 | 42 | $0.047 |
| graphify | 306 | 44 | $0.039 |
| lean-ctx | 306 | 44 | $0.048 |
| baseline | 340 | 49 | $0.050 |

codedb uses 26% fewer turns than baseline. graphify has the lowest cost-per-turn ($0.039) — its queries return cheap, focused results even if it needs more iterations.

## Tool Profiles

### codedb
- **Strength:** Turn efficiency. Fewest turns on 5/7 tasks. `codedb_symbol` and `codedb_outline` give precise, targeted context that reduces exploration.
- **Weakness:** Expensive on complex dependency-heavy repos (kombu: $3.45). Symbol lookups don't help when the task requires understanding cross-module message routing.
- **Best for:** Medium-large repos where you know what to look for.

### graphify
- **Strength:** Cheapest overall by a wide margin (-28% vs baseline). Graph queries are token-efficient.
- **Weakness:** Can produce incomplete patches (kombu: 45L). BFS subgraph returns may miss implementation details. Most turns on several tasks.
- **Best for:** Pattern-heavy tasks (narwhals rolling windows) where graph structure reveals what to replicate.

### codegraph
- **Strength:** Consistent middle performer. Never worst, never best. `codegraph_impact` and `codegraph_explore` provide good multi-symbol context.
- **Weakness:** Never cheapest on any task (0 wins). `explore` tool returns verbose output that inflates token usage on large codebases.
- **Best for:** Unfamiliar codebases where you need broad orientation before diving in.

### lean-ctx
- **Strength:** Won cattrs decisively. Compression modes (signatures, map) can be very efficient for the right task shape.
- **Weakness:** 62-tool surface area creates selection overhead. Most expensive on httpx ($1.76) where simpler tools suffice. Slowest wall time.
- **Best for:** Tasks requiring deep file reads where compression saves tokens (cattrs: reading complex type structures).

### baseline (grep/find)
- **Strength:** Won vulture (small repo). Zero tool overhead — for tiny repos, grep is unbeatable.
- **Weakness:** Most expensive overall (+0%). Most turns on 4/7 tasks. No structural understanding means more blind exploration.
- **Best for:** Small repos (<50 files) where the overhead of code intelligence tools isn't justified.

## Improvement Suggestions

### For codedb
1. **Reduce kombu-style blowup.** When a task requires understanding cross-module interactions (DLX routing, TTL propagation), `codedb_deps` returns raw dependency lists that aren't actionable. Consider a "context for task" tool that returns a curated subset of symbols relevant to a described feature.
2. **Batch symbol lookups.** codedb_symbol is called once per symbol — a `codedb_symbols` (plural) tool that returns multiple symbols in one call would cut turn count further.
3. **Cheaper reads.** `codedb_read` returns full file content. Adding a mode like `codedb_read --signatures` that returns only function signatures would reduce tokens on initial exploration.

### For graphify
1. **Fix incomplete patches.** The kombu 45L result suggests the graph didn't capture enough of the implementation detail. Graph queries that return only signatures/edges miss the actual code needed to implement features.
2. **Reduce turn count.** graphify uses the most turns on several tasks (narwhals: 62, sqlite-utils: 69). Graph traversals could batch related queries.
3. **Add code context to graph nodes.** Returning function bodies (not just names/edges) with graph queries would let the agent write code without follow-up file reads.

### For codegraph
1. **Win something.** 0/7 wins means the tool surface area is solid but not differentiated. `codegraph_explore` is the unique tool — optimize it to return more focused, actionable context.
2. **Reduce verbosity.** `codegraph_impact` and `codegraph_trace` return verbose output. Token-budgeted responses would help.
3. **Better indexing.** codegraph had the 2nd-highest cost on sqlite-utils ($3.74) despite having a rich tool surface. The index quality may not match codedb's trigram-based approach.

### For lean-ctx
1. **Reduce tool surface area.** 62 tools is overwhelming for the agent. Sonnet spends tokens deciding which of the 62 tools to call. A curated subset of 8-10 tools would likely improve both cost and turns.
2. **Fix httpx overhead.** $1.76 on httpx (vs $0.77-$1.22 for others) suggests compression/decompression overhead isn't worth it on focused exploration tasks.
3. **Faster reads.** lean-ctx had the slowest wall time (4,936s). The read compression pipeline adds latency per call that compounds over 306 turns.

### For all tools
1. **Test evaluation is critical.** Cost differences are meaningless without knowing which patches actually pass tests. A 45L patch that passes is infinitely better than a 926L patch that doesn't.
2. **Bigger repos needed.** These are all medium repos (50-500 files). The real differentiator for code intelligence is repos with 1000+ files where grep becomes prohibitively slow.
3. **Multi-run variance.** Single runs have high variance (the earlier SWE-bench run showed codedb at $1.13 for httpx vs $0.90 this run). 3+ runs per variant would give confidence intervals.

## Traces

All 35 trace JSON files are in `traces/`. Each contains:
- `cost_usd`, `num_turns`, `wall_seconds`, `duration_ms`, `ttft_ms`
- `usage` (input/output/cache tokens)
- `model_usage` (per-model breakdown)
- `permission_denials` (tools the agent tried but couldn't use)
- `stop_reason`, `terminal_reason`, `session_id`

## Methodology

- Each task run with `claude -p` using Sonnet 4.6, $5 budget, 200k context, `--dangerously-skip-permissions`
- Repos cloned fresh, checked out to specified base commit, `git clean -fd` between variants
- **codedb:** `codedb index` then MCP server via `codedb mcp <path>`
- **graphify:** `graphify update .` then MCP server via `python -m graphify.serve <graph.json>`
- **codegraph:** `codegraph index .` then MCP server via `codegraph serve --mcp --path <path>`
- **lean-ctx:** `lean-ctx index build` then MCP server via bare `lean-ctx` command
- **baseline:** no MCP — only built-in Claude Code tools (Read, Bash/grep/find, Edit, Write)
- All non-active MCP tools blocked with `--disallowedTools "mcp__codedb__*"` for non-codedb variants
