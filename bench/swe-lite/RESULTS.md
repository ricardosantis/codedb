# Code Intelligence Benchmark: codedb vs graphify vs baseline

**Model:** Sonnet 4.6 | **Date:** 2026-05-27 | **Eval:** All patches validated against test suites (12/12 pass for all three variants)

## SWE-bench Lite (10 bug-fix instances)

| Instance | codedb | graphify | baseline | Cheapest |
|---|---|---|---|---|
| flask-4992 | $0.167, 11T, 54L | $0.130, 7T, 54L | **$0.117**, 6T, 54L | baseline |
| requests-863 | $0.144, 10T, 17L | $0.154, 10T, 16L | **$0.121**, 8T, 17L | baseline |
| matplotlib-24970 | **$0.132**, 6T, 15L | $0.140, 6T, 13L | $0.195, 11T, 32L | codedb |
| scikit-learn-10297 | $0.179, 12T, 18L | $0.134, 7T, 18L | **$0.133**, 7T, 18L | baseline |
| django-12708 | $0.171, 10T, 13L | **$0.153**, 9T, 13L | $0.155, 8T, 18L | graphify |
| xarray-4094 | $0.199, 9T, 45L | **$0.156**, 6T, 45L | $0.238, 12T, 13L | graphify |
| seaborn-3407 | $0.205, 9T, 22L | $0.373, 15T, 15L | **$0.195**, 9T, 15L | baseline |
| astropy-14182 | $0.329, 16T, 20L | **$0.239**, 10T, 19L | $0.319, 17T, 20L | graphify |
| pytest-8906 | $0.294, 21T, 58L | **$0.120**, 8T, 14L | $0.305, 22T, 59L | graphify |
| sympy-14024 | **$1.012**, 29T, 14L | $1.194, 30T, 14L | $1.216, 35T, 14L | codedb |
| **Total** | **$2.83**, 133T | **$2.79**, 108T | **$2.99**, 135T | **graphify** |

Pass rate: **10/10** for all three variants.

## DeepSWE (2 feature-implementation instances)

| Instance | codedb | graphify | baseline | Cheapest |
|---|---|---|---|---|
| httpx-streaming-json-iteration | **$1.125**, 34T, 194L | $2.040, 58T, 194L | $2.306, 47T, 256L | codedb |
| vulture-persistent-analysis-cache | **$1.132**, 30T, 318L | $1.250, 36T, 374L | $1.560, 32T, 386L | codedb |
| **Total** | **$2.26**, 64T | **$3.29**, 94T | **$3.87**, 79T | **codedb** |

Pass rate: **2/2** for all three variants.

## Combined Summary

| | codedb | graphify | baseline |
|---|---|---|---|
| Pass rate | 12/12 (100%) | 12/12 (100%) | 12/12 (100%) |
| Total cost | **$5.09** | $6.08 | $6.86 |
| Total turns | 197 | 202 | 214 |
| Total patch lines | 788 | 789 | 902 |
| Cost vs baseline | **-26%** | -11% | — |

## Takeaways

- **All three solve everything.** On these 12 instances, Sonnet 4.6 produces correct patches regardless of tooling. The differentiator is cost, not correctness.
- **Simple bugfixes:** graphify is slightly cheapest ($2.79 vs $2.83 vs $2.99). Both tools save ~5-7% vs baseline. Graphify wins on 4/10 instances, baseline on 4/10, codedb on 2/10.
- **Complex feature implementations:** codedb wins decisively ($2.26 vs $3.29 vs $3.87 — 42% cheaper than baseline). codedb's targeted symbol/outline lookups are far more token-efficient than graphify's BFS subgraphs on multi-file tasks.
- **Overall:** codedb is cheapest combined at $5.09, saving 26% vs baseline. The DeepSWE advantage dominates.
- **Patch size:** codedb and graphify produce similarly-sized patches (~789L). Baseline produces ~14% more code (902L), suggesting less precise edits.
- **Turns:** graphify uses the fewest turns on bugfixes (108 vs 133). codedb uses the fewest on features (64 vs 94). Baseline is consistently highest (214 total).

## Methodology

- Each instance was run with `claude -p` using Sonnet 4.6, $5 budget, 200k context
- **codedb variant:** codedb MCP server providing `codedb_symbol`, `codedb_outline`, `codedb_search`, etc.
- **graphify variant:** graphify MCP server providing graph-based code navigation
- **baseline variant:** no code intelligence MCP — only built-in Claude Code tools (Read, Bash/grep, etc.)
- Patches evaluated on a Linux VM (Daytona sandbox) with correct Python versions and dependencies per repo
- SWE-bench Lite instances selected from: flask, requests, matplotlib, scikit-learn, django, xarray, seaborn, astropy, pytest, sympy
- DeepSWE instances: httpx (streaming JSON iteration), vulture (persistent analysis cache)

**Legend:** T = agent turns, L = patch lines (unified diff)
