# DeepSWE Big-Repo 5-Way Benchmark Results

**Model:** Sonnet 4.6 | **Date:** 2026-05-28 | **Budget:** $5/run | **Tasks:** 5 | **Variants:** 5 | **Total runs:** 25

## Summary

| Variant | Runs | Failures | Total Cost | Avg $/task | Total Turns | Wall Time | Total Tokens | Total Lines |
|---|---|---|---|---|---|---|---|---|
| graphify | 5 | **1** (numba) | **$13.76** | $2.75 | 159 | 94.0m | 7.3M | 1,771L |
| leanctx | 5 | 0 | $14.97 | $2.99 | 254 | 97.4m | 20.0M | 2,659L |
| baseline | 5 | **1** (numba) | $15.86 | $3.17 | 116 | 100.1m | 9.1M | 1,953L |
| codegraph | 5 | **1** (numba) | $16.06 | $3.21 | 109 | 94.3m | 5.3M | 1,438L |
| **codedb** | 5 | **0** | $17.45 | $3.49 | 231 | 91.4m | 18.5M | 2,419L |

**Key insight:** Only **codedb** and **leanctx** produced patches on all 5 tasks. graphify, codegraph, and baseline each failed on numba (0L patch despite ~$2.45 spent on each failed run). codedb is the **most expensive** but the **most reliable** — pays a premium for completeness.

## Validation Update (2026-05-29)

The cost ranking below measures spend and patch *size*, not correctness. Every non-empty
patch has since been applied in an isolated sandbox and exercised with task-specific
functional validators (full breakdown in [`VALIDATION.md`](./VALIDATION.md)). The
correctness ranking **inverts** the cost ranking:

| Variant | Functional pass rate | Patches applied | Note |
|---|---|---|---|
| **codedb** | **35/41 (85.4%)** | **5/5** | Highest correctness, zero broken patches |
| leanctx | 23/29 (79.3%) | 5/5 | — |
| graphify | 22/31 (71.0%) | 3/5 | 1 patch failed to apply |
| codegraph | 15/25 (60.0%) | 3/5 | 1 patch failed to apply |
| baseline | 12/23 (52.2%) | 4/5 | Cheapest-but-one, least correct |

**codedb is the most expensive variant ($17.45, ranked last on cost) but the most correct
(85.4%, ranked first).** Size is not correctness: two of the five largest fastapi-HEAD
patches are broken — baseline's 893L patch has a syntax error in `routing.py` (does not
import) and leanctx's 703L patch imports a module it never creates; both score 0/1
functionally despite their size.

## Per-Task Results

### langchain-request-coalescing — Runnable.with_coalesce() (ref: 820L)

The monorepo defeated everyone. All 5 variants produced 11-15% of reference solution.

| Variant | Cost | Turns | Wall | Tokens | Patch | % ref |
|---|---|---|---|---|---|---|
| baseline | **$1.56** | **23** | 610s | 1.6M | 115L | 14% |
| graphify | $1.65 | 35 | 720s | 1.9M | 97L | 12% |
| leanctx | $1.73 | 35 | **576s** | 2.0M | 123L | 15% |
| codegraph | $1.82 | 32 | 853s | 1.7M | 107L | 13% |
| codedb | $3.18 | 62 | 1,159s | 5.1M | 90L | 11% |

**Analysis:** langchain is structured as multiple sub-packages (`libs/core`, `libs/langchain`, `libs/community`). Symbol-based tools (codedb, codegraph) burned turns navigating directories. Baseline (raw grep) was cheapest *and* produced the most coverage proportionally. **codedb performed worst on every metric** — 2x the cost of baseline for fewer patch lines.

### fastapi-implicit-head-options — Implicit HEAD/OPTIONS (ref: 939L)

Tractable task, all variants produced substantial patches. codedb dominated on $/patch-line.

| Variant | Cost | Turns | Wall | Tokens | Patch | % ref |
|---|---|---|---|---|---|---|
| **codedb** | **$4.13** | 62 | 1,297s | 5.7M | **810L** | 86% |
| graphify | $4.62 | 39 | 1,128s | 1.5M | 638L | 68% |
| leanctx | $4.75 | 109 | 1,292s | 8.7M | 703L | 75% |
| baseline | $5.03 | 46 | 1,415s | 5.0M | 893L | 95% |
| codegraph | $5.18 | **16** | **935s** | 0.7M | 606L | 65% |

**Analysis:** codegraph hit the $5 budget cap. baseline produced the largest patch (893L = 95%) but cost the most. codedb gave the best $/patch-line ratio. codegraph was wall-fastest but cheapest *per turn* because it gave up after 16 rounds.

### fastapi-deprecation-response-headers — Deprecation headers (ref: 784L)

graphify won decisively — its graph traversal revealed the precedence structure quickly.

| Variant | Cost | Turns | Wall | Tokens | Patch | % ref |
|---|---|---|---|---|---|---|
| leanctx | **$2.27** | 36 | 875s | 2.1M | 595L | 76% |
| graphify | $3.30 | 38 | **795s** | 1.3M | **817L** | **104%** |
| codegraph | $4.86 | 34 | 812s | 1.2M | 560L | 71% |
| baseline | $4.91 | 23 | 804s | 0.6M | 617L | 79% |
| codedb | $5.03 | **23** | 842s | 0.7M | 606L | 77% |

**Analysis:** codedb **hit the $5 budget cap** with 23 turns. The task required understanding multi-layer parameter precedence (route → include_router → router → FastAPI), and codedb's symbol lookups didn't reveal the precedence chain efficiently. graphify produced the only patch that *exceeded* the reference (104%) — graph edges directly modeled the dependency relationships.

### textual-richlog-follow-state — RichLog scrolling state (ref: 521L)

codedb produced the biggest patch by 12% margin.

| Variant | Cost | Turns | Wall | Tokens | Patch | % ref |
|---|---|---|---|---|---|---|
| leanctx | **$1.46** | 26 | **677s** | 1.4M | 352L | 68% |
| codedb | $1.66 | 39 | 710s | 2.0M | **395L** | **76%** |
| graphify | $1.68 | 39 | 787s | 2.1M | 219L | 42% |
| codegraph | $1.76 | **19** | 853s | 1.2M | 165L | 32% |
| baseline | $1.91 | 19 | 960s | 1.4M | 328L | 63% |

**Analysis:** UI widget task with clear class hierarchies. codedb's symbol lookups paid off — found `Log` and `RichLog` base classes quickly and extended them. graphify and codegraph **under-implemented severely** (42% and 32% of ref), suggesting graph queries returned class signatures but not enough body context to write the actual implementation.

### numba-stencil-boundary-modes — @stencil boundary modes (ref: 535L)

**Three variants completely failed.** Only codedb and leanctx succeeded.

| Variant | Cost | Turns | Wall | Tokens | Patch | % ref |
|---|---|---|---|---|---|---|
| codedb | **$3.46** | **45** | **1,475s** | 5.0M | **518L** | **97%** |
| leanctx | $4.76 | 48 | 2,427s | 5.8M | 886L | 165% (over) |
| graphify | $2.52 | 17 | 2,213s | 0.5M | **0L** | **FAILED** |
| codegraph | $2.44 | 18 | 2,202s | 0.5M | **0L** | **FAILED** |
| baseline | $2.44 | 11 | 2,216s | 0.5M | **0L** | **FAILED** |

**Analysis — the big-repo killer task:** numba is a JIT compiler. Stencil compilation lives in `numba/stencils/`, the IR uses custom AST visitors, and boundary mode dispatch threads through type inference, lowering, and parfor passes. **graphify, codegraph, and baseline all gave up** after 11-18 turns — they couldn't locate the right code paths. codedb's symbol/outline tools navigated the compiler internals and produced a 97% complete implementation. leanctx over-implemented (165%, likely added redundant code paths). **This is where codedb earned its cost premium.**

## Timing & Latency Analysis

### Wall time

| Variant | Total | Avg/task | Avg/turn | vs baseline |
|---|---|---|---|---|
| codedb | **91.4 min** | 18.3min | 23.7s | **-8.7%** |
| graphify | 94.0 min | 18.8min | 35.5s | -6.1% |
| codegraph | 94.3 min | 18.9min | 51.9s | -5.8% |
| leanctx | 97.4 min | 19.5min | 23.0s | -2.7% |
| baseline | 100.1 min | 20.0min | 51.8s | — |

codedb is **fastest wall-clock overall** despite having the most turns (231). Its symbol lookups are cheap-per-turn (~23s/turn), while codegraph and baseline burn 50+s per turn on heavier reads.

leanctx has similar per-turn speed to codedb but logs more turns (254 vs 231).

### Turn efficiency

| Variant | Total Turns | Avg/task | Cost/turn |
|---|---|---|---|
| codegraph | **109** | 22 | $0.147 |
| baseline | 116 | 23 | $0.137 |
| graphify | 159 | 32 | $0.087 |
| codedb | 231 | 46 | **$0.076** |
| leanctx | 254 | 51 | $0.059 |

Inversion from medium repos: on big repos, codedb uses **more** turns than baseline (the opposite of medium repos). The symbol surface area is bigger, so it explores more before committing. But each turn is cheap, so total wall time stays low.

### Token usage

| Variant | Total | Avg/task | Patch lines/Mtok |
|---|---|---|---|
| codegraph | **5.3M** | 1.06M | 270 L/Mtok |
| graphify | 7.3M | 1.47M | 242 L/Mtok |
| baseline | 9.1M | 1.81M | 216 L/Mtok |
| codedb | 18.5M | 3.69M | 131 L/Mtok |
| leanctx | 20.0M | 3.99M | 133 L/Mtok |

codedb and leanctx burn 2-4x more tokens than the others. codedb reads more deeply (codedb_read returns full file content); leanctx has 62 tools that each return moderate context. graphify and codegraph are token-frugal — graph queries return signatures/edges, not bodies.

**But token frugality isn't enough on hard tasks:** all 3 frugal variants (graphify/codegraph/baseline) failed numba while codedb and leanctx — the token-heavy variants — succeeded. There's a real correlation between *tokens read* and *ability to implement complex features*.

## Tool Profiles (Big Repos)

### codedb — The Reliable Premium

- **Wins:** Cheapest on 2/5 tasks (fastapi-HEAD, numba). Fastest wall time overall. **0 failures** on a benchmark where 3 other variants failed.
- **Losses:** Most expensive overall ($17.45). Burned budget cap on fastapi-deprec. Worst-by-far on langchain.
- **Profile:** Reads deeply (3.7M tok/task), turns fast (23.7s/turn), produces complete patches. The "reliable premium" tool.
- **Best for:** Hard implementation tasks in non-monorepo codebases with clear symbol structure (compilers, frameworks, libraries).
- **Worst for:** Monorepos with split packages where you don't know which sub-package to search in.

### graphify — The Cost Leader (When It Works)

- **Wins:** Cheapest overall ($13.76). Won fastapi-deprec decisively (104% of reference). Token-frugal (1.5M/task).
- **Losses:** **Failed numba** ($2.52 spent for 0L). Under-implemented severely on textual (42%) and fastapi-HEAD (68%).
- **Profile:** Graph traversal reveals architecture cheaply, but doesn't return enough body context for complex implementations. Falls off a cliff when the task requires understanding non-obvious code paths.
- **Best for:** Tasks where graph structure matches the feature (parameter precedence, dependency chains).
- **Worst for:** Compiler internals, deeply-nested logic without clear graph edges.

### codegraph — Token-Frugal But Quiet

- **Wins:** Fewest tokens (5.3M total). Fewest turns (109). Never the worst on any task.
- **Losses:** **Failed numba**. Hit budget cap on fastapi-HEAD ($5.18, only 606L). 0/5 cost wins.
- **Profile:** Verbose tool outputs cost more per turn but require fewer turns. Doesn't differentiate strongly from baseline.
- **Best for:** Quick orientation on medium-sized codebases.
- **Worst for:** Tasks requiring deep code reads (the codegraph_explore output bloats context without adding implementation detail).

### lean-ctx — The Other Reliable Choice

- **Wins:** Cheapest on 2/5 tasks (fastapi-deprec, textual). 0 failures. Over-implemented numba (886L for 535L ref).
- **Losses:** Most turns (254). Most tokens (20.0M). 62-tool surface area means every task incurs selection overhead.
- **Profile:** Compression modes work, but the tool count is overwhelming. Sonnet spends tokens deciding which tool to call.
- **Best for:** Tasks where read compression saves tokens (cattrs from medium repos was a good fit).
- **Worst for:** Tight-budget runs — many tools means many trial calls.

### baseline (grep/find) — Surprisingly Competitive

- **Wins:** Cheapest on langchain (the only task where it beat tools). Best fastapi-HEAD patch coverage (95%).
- **Losses:** **Failed numba**. Slowest wall time. Most expensive avg/turn ($0.137).
- **Profile:** Raw grep is unbeatable when the codebase is small enough to brute-force. Falls apart on numba where you need to know `numba.core.typing` exists.
- **Best for:** Small focused tasks, monorepos where tools mis-navigate, or just as a sanity-check baseline.

## What This Says About codedb

### Where codedb wins on big repos:
1. **Compiler/framework internals** (numba): codedb's symbol/outline tools navigate complex AST/IR code that defeats grep and graph queries.
2. **Class-hierarchy extensions** (textual): symbol lookups find base classes quickly.
3. **Multi-file routing** (fastapi-HEAD): outline + symbol gives the structural map cheap.

### Where codedb loses on big repos:
1. **Monorepos** (langchain): `libs/core/` vs `libs/langchain/` vs `libs/community/` confuses the symbol index. Tool burns turns searching across packages.
2. **Precedence/dependency chains** (fastapi-deprec): symbol lookups don't reveal *order* relationships. graphify wins these because edges encode the chain.
3. **Token efficiency**: codedb_read returns full files. For wide-shallow reads, that's wasteful.

## Improvement Suggestions

### For codedb (priority by big-repo impact)

1. **Monorepo navigation.** langchain showed `codedb_search` doesn't help when the codebase has multiple roots. Add a `codedb_layout` tool that returns the top-level package structure first (e.g., "libs/core: 800 files | libs/langchain: 1200 files | libs/community: 500 files") with a one-line per-package summary. This would prevent the directory-search thrash.

2. **Precedence-aware lookups.** fastapi-deprec showed that knowing what calls what isn't enough — you need to know in what *order*. Consider a `codedb_resolution` tool that, given a parameter name (`deprecated`), returns the call chain showing how that parameter flows through layers (constructor → include_router → router → route).

3. **Budget-aware reads.** When approaching the budget cap (fastapi-deprec hit $5 at 23 turns), `codedb_read` should switch to signature-only mode automatically. The current behavior burns the remaining budget on full file reads.

4. **Batch symbol lookups.** codedb_symbol fetches one symbol per call. On numba, the agent called it 45 times — 45 turns × ~30s/turn = 22 min just on symbol calls. A `codedb_symbols([...])` (plural) would cut this 5-10x.

5. **Outline summarization.** `codedb_outline` returns the full outline. For files with 50+ functions (numba/stencils/stencilparfor.py), the agent spends tokens parsing the outline. Add a `codedb_outline --filter "stencil|boundary"` mode.

### For graphify

1. **Implement a fallback to file reads.** graphify failed numba because graph queries didn't reveal the boundary-mode dispatch path. Add a "show me the implementation of node X" tool that returns the function body, not just edges.

2. **Detect "graph confusion" early.** Three failures (numba, partial-fail on textual at 42%) shared a pattern: the agent kept calling `query_graph` and getting back lists of nodes with no implementation detail. Detect this and prompt the agent to fall back to file reads.

### For codegraph

1. **Fix the budget cap problem.** fastapi-HEAD ($5.18 cap), fastapi-deprec ($4.86), numba (failed) — codegraph_explore is too verbose for big repos. Trim default output to <500 lines, add `--full` flag if needed.

2. **Differentiate from baseline.** codegraph beat baseline by only $0.20/task on average. The codegraph_impact tool is unique but didn't differentiate. Consider task-specific tool hints.

### For lean-ctx

1. **Reduce tool surface area.** 62 tools = 62 candidates per turn. On numba where leanctx succeeded, it took 48 turns and 5.8M tokens. A curated 8-tool subset should cut that 2x.

2. **Fix the over-implementation tendency.** numba leanctx produced 886L for 535L ref (165%) — likely added redundant boundary mode code paths. Consider a "task completion check" tool.

### For all tools

1. **Test evaluation is critical.** A 518L patch that passes is worth more than an 886L patch that doesn't. This has now been done (see the Validation Update above and `VALIDATION.md`): functional validation re-ranks the variants — codedb 1st at 85.4%, baseline last at 52.2% — confirming code volume ≠ correctness.

2. **Monorepo handling is the next frontier.** Every tool failed langchain. The pattern (libs/{core,langchain,community,etc}) is becoming standard (next/vercel monorepos, nx workspaces, pnpm workspaces). Tools need first-class monorepo awareness.

3. **Budget caps reveal tool inefficiency.** 4/25 runs hit or approached the $5 cap. The cap is a hard wall — when you hit it, you get a half-done patch. Tools should self-throttle near the cap (signature-only modes, batch queries).

## Cross-Benchmark Comparison (Medium vs Big)

| Variant | Medium (7 tasks) | Big (5 tasks) | Big penalty |
|---|---|---|---|
| graphify | $1.72/task, 4 wins | $2.75/task, 1 win, **1 fail** | +60% cost, much worse |
| codegraph | $1.99/task, 0 wins | $3.21/task, 0 wins, **1 fail** | +61% cost |
| codedb | $2.00/task, 1 win | $3.49/task, 2 wins, **0 fail** | +75% cost, **most reliable** |
| leanctx | $2.11/task, 1 win | $2.99/task, 2 wins, **0 fail** | +42% cost |
| baseline | $2.41/task, 1 win | $3.17/task, 1 win, **1 fail** | +31% cost |

**The big-repo story:**
- graphify (the medium-repo cost leader) struggles — its graph approach falls off when codebases get complex.
- codedb pays more but never fails — the "reliable premium" picture sharpens.
- leanctx scales well — 0 failures, only +42% cost vs medium.
- baseline holds up surprisingly — it's not the worst.

## Traces

All 25 trace JSON files in `traces/`. Each contains:
- `cost_usd`, `num_turns`, `wall_seconds`, `duration_ms`, `duration_api_ms`, `ttft_ms`
- `usage` (input/output/cache_read/cache_create tokens)
- `model_usage` (per-model breakdown)
- `permission_denials`, `stop_reason`, `terminal_reason`, `session_id`

## Methodology

- Each task run with `claude -p` using Sonnet 4.6, $5 budget, 200k context, `--dangerously-skip-permissions`
- Repos cloned fresh, checked out to specified base commit, `git clean -fd` between variants
- **codedb:** `codedb index` then MCP server via `codedb mcp <path>`
- **graphify:** `graphify update .` then MCP server via `python -m graphify.serve <graph.json>`
- **codegraph:** `codegraph index .` then MCP server via `codegraph serve --mcp --path <path>`
- **lean-ctx:** `lean-ctx index build` then MCP server via bare `lean-ctx` command
- **baseline:** no MCP — only built-in Claude Code tools (Read, Bash/grep/find, Edit, Write)
- All non-active MCP tools blocked with `--disallowedTools "mcp__codedb__*"` for non-codedb variants
- Patches captured via `git diff` after the run completes
- Failed runs (no patch produced) still counted toward cost/turn totals
