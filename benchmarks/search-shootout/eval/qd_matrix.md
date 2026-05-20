# QD Matrix — code-search-shootout

Tasks: 8  ·  Backends: 4  ·  Filled cells: 27

## Quality (out of 5) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 5.00±0.00 (n=2) | — | 5.00 | 4.00 |
| `T1_setState_trace` | 4.50±0.71 (n=2) | 5.00 | 5.00 | 5.00 |
| `T2_snapshot_flag_sites` | 3.67±0.58 (n=3) | 3.00 | 5.00 | 3.00 |
| `T3_compare_two_functions` | 5.00±0.00 (n=2) | 5.00 | 5.00 | 5.00 |
| `R0_find_iter` | 5.00 | — | 5.00 | 5.00 |
| `R1_pattern_compile_trace` | 4.00 | — | 4.00 | 4.00 |
| `R2_matchkind_all_sites` | 4.00 | — | 3.00 | 3.00 |
| `R3_pikevm_vs_backtrack` | 5.00 | — | 3.00 | 5.00 |

### Per-backend averages (across all tasks where measured)

| backend | avg quality | avg tokens | avg wall (s) | avg calls | tokens / quality-point |
|---|---|---|---|---|---|
| **codedb** | 4.52 | 17,492 | 28.2 | 6.3 | 3,869 |
| **codedb_LEAN** | 4.33 | 24,474 | 108.0 | 14.7 | 5,648 |
| **fts5_trigram** | 4.38 | 17,172 | 36.9 | 7.9 | 3,925 |
| **leanctx** | 4.25 | 21,452 | 67.8 | 13.1 | 5,047 |

## Efficiency (tokens) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 21,198±1,980 (n=2) | — | 14,523 | 21,212 |
| `T1_setState_trace` | 18,324±3,799 (n=2) | 35,504 | 17,876 | 18,370 |
| `T2_snapshot_flag_sites` | 15,129±3,263 (n=3) | 20,123 | 15,853 | 23,661 |
| `T3_compare_two_functions` | 15,151±1,283 (n=2) | 17,795 | 15,307 | 15,361 |
| `R0_find_iter` | 13,642 | — | 14,299 | 17,729 |
| `R1_pattern_compile_trace` | 24,156 | — | 22,645 | 32,596 |
| `R2_matchkind_all_sites` | 12,867 | — | 21,030 | 18,040 |
| `R3_pikevm_vs_backtrack` | 19,467 | — | 15,844 | 24,645 |

## Wall time (seconds) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 31.5±17.7 (n=2) | — | 25.0 | 123.0 |
| `T1_setState_trace` | 67.0±58.0 (n=2) | 226.0 | 95.0 | 91.0 |
| `T2_snapshot_flag_sites` | 22.7±28.4 (n=3) | 46.0 | 49.0 | 121.0 |
| `T3_compare_two_functions` | 21.5±9.2 (n=2) | 52.0 | 29.0 | 61.0 |
| `R0_find_iter` | 21.0 | — | 12.0 | 12.0 |
| `R1_pattern_compile_trace` | 49.0 | — | 32.0 | 68.0 |
| `R2_matchkind_all_sites` | 1.0 | — | 28.0 | 28.0 |
| `R3_pikevm_vs_backtrack` | 12.0 | — | 25.0 | 38.0 |

## Pareto frontier

A backend is **Pareto-dominant** if no other backend beats it on all three axes (quality higher, tokens lower, wall lower).

| backend | quality | tokens | wall (s) | status |
|---|---|---|---|---|
| codedb | 4.52 | 17,492 | 28.2 | **PARETO-OPTIMAL** |
| fts5_trigram | 4.38 | 17,172 | 36.9 | **PARETO-OPTIMAL** |
| codedb_LEAN | 4.33 | 24,474 | 108.0 | dominated by: codedb, fts5_trigram |
| leanctx | 4.25 | 21,452 | 67.8 | dominated by: codedb, fts5_trigram |

## MAP-Elites grid

Rows = behavioral niche (`query_type`). Cols = backend.
Each cell shows aggregated (quality / tokens / wall) over tasks in that niche.
**Bold** = best in row on quality; *italic* = best in row on tokens.

| niche | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `uncategorized` (4 tasks) | 4.54 / 17,451 / 35.7s | 4.33 / 24,474 / 108.0s | **5.00** / *15,890* / 49.5s | 4.25 / 19,651 / 99.0s |
| `symbol-lookup` (1 task) | **5.00** / *13,642* / 21.0s | — | 5.00 / 14,299 / 12.0s | 5.00 / 17,729 / 12.0s |
| `trace` (1 task) | **4.00** / 24,156 / 49.0s | — | 4.00 / *22,645* / 32.0s | 4.00 / 32,596 / 68.0s |
| `pattern-find` (1 task) | **4.00** / *12,867* / 1.0s | — | 3.00 / 21,030 / 28.0s | 3.00 / 18,040 / 28.0s |
| `comparison` (1 task) | **5.00** / 19,467 / 12.0s | — | 3.00 / *15,844* / 25.0s | 5.00 / 24,645 / 38.0s |

### Niche wins per backend

| backend | niches won on quality | niches won on tokens |
|---|---|---|
| codedb | 4 | 2 |
| codedb_LEAN | 0 | 0 |
| fts5_trigram | 1 | 3 |
| leanctx | 0 | 0 |
