# search-shootout

Compares full-text search backends for code intelligence on a real-world
JS/TS corpus (facebook/react):

| Backend | What it is |
|---|---|
| `codedb` | This repo. Custom Zig trigram + inverted word index, served over MCP. |
| `fts5_trigram` | SQLite FTS5 with the `trigram` tokenizer (added in 3.34). Pure-substring matching, similar shape to codedb's trigram. |
| `fts5_unicode61` | SQLite FTS5 with the default word-boundary tokenizer + BM25 ranking. The "lean-ctx-style" backend. |
| `lean-ctx` | The yvgude/lean-ctx CLI (`lean-ctx index build` + `lean-ctx grep`). |

## Reproducing

1. Build codedb: `zig build -Doptimize=ReleaseFast`
2. (Optional) Install lean-ctx: `cargo install lean-ctx`
3. Clone a corpus **outside `/tmp`** — codedb refuses to index temporary roots:
   ```
   mkdir -p ~/codedb-bench
   git clone --depth 1 https://github.com/facebook/react ~/codedb-bench/react
   ```
4. Run:
   ```
   python3 shootout.py --corpus ~/codedb-bench/react \
                       --out results/react-$(date +%Y-%m-%d).md \
                       --clean-codedb
   ```

Flags:

- `--iters N` — warm iterations per query (default 20)
- `--skip-codedb`, `--skip-fts5`, `--skip-leanctx` — limit backends
- `--clean-codedb` — wipe matching codedb snapshot before indexing (forces cold build)

## What it measures

**Build phase:** wall-clock time to build the index from scratch + final on-disk
size. Run once per backend per corpus.

**Query phase:** for each query in `queries.json`, warm the backend with one
call, then time `--iters` calls. Reports p50 and p99 latency plus the result
count.

> ⚠️  Result counts are **not directly comparable** across backends:
> - codedb counts matching lines (and caps display at 50)
> - FTS5 counts matching files
> - lean-ctx counts matches reported in its "N matches in M files" header
>
> Use these as a **recall sanity check** (zero vs non-zero) and use
> **latency** for performance comparison.

## Calibration: how each backend is invoked

- **codedb** runs as an MCP server over stdio (`codedb <root> mcp`). The first
  query warms a long-lived process; subsequent queries are pure RPC.
- **FTS5** uses a persistent SQLite connection from Python.
- **lean-ctx** is invoked as `lean-ctx grep <q>` with `cwd=<corpus>` per
  query. Each invocation pays ~700ms of CLI binary startup even though
  lean-ctx uses a daemon for the actual search work. This is honest "what it
  costs to call from a script" — not what an MCP-resident lean-ctx would feel
  like.

## Query set

`queries.json` covers a spectrum of code-search workloads on a React corpus:

- common-identifier — high-frequency, lots of result merging (`useState`)
- camelcase-identifier — full identifier (`forwardRef`, `createElement`)
- substring-identifier — substring of bigger names (`Fiber`, `Lane`, `Suspense`)
- rare-camelcase — low-frequency named symbol (`flushPassiveEffects`)
- short-trigram-exact — 3-char query, exercises the trigram lower bound (`set`)
- lang-keyword — high-frequency stress test (`function`)
- negative — should return 0 on all backends (`xyzzy_react_does_not_exist`)

## Output

Console: one line per query showing each backend's p50/p99 and hit count.
Markdown: written to `--out` path, includes corpus stats, build table, and
per-query latency table.

Reports for past runs live under `results/`. A separate `RESULTS.md` at the
top of this folder summarizes findings across runs and includes the agentic
traversal eval (a Sonnet 4.6 sub-agent doing the same task on each backend).
