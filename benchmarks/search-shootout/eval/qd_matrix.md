# QD Matrix — code-search-shootout

Tasks: 4  ·  Backends: 4  ·  Filled cells: 15

## Quality (out of 5) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 5.00 | — | 5.00 | 4.00 |
| `T1_setState_trace` | 5.00 | 5.00 | 5.00 | 5.00 |
| `T2_snapshot_flag_sites` | 3.00 | 3.00 | 5.00 | 3.00 |
| `T3_compare_two_functions` | 5.00 | 5.00 | 5.00 | 5.00 |

### Per-backend averages (across all tasks where measured)

| backend | avg quality | avg tokens | avg wall (s) | avg calls | tokens / quality-point |
|---|---|---|---|---|---|
| **codedb** | 4.50 | 19,606 | 58.8 | 10.5 | 4,357 |
| **codedb_LEAN** | 4.33 | 24,474 | 108.0 | 14.7 | 5,648 |
| **fts5_trigram** | 5.00 | 15,890 | 49.5 | 8.2 | 3,178 |
| **leanctx** | 4.25 | 19,651 | 99.0 | 13.2 | 4,624 |

## Efficiency (tokens) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 22,598 | — | 14,523 | 21,212 |
| `T1_setState_trace` | 21,010 | 35,504 | 17,876 | 18,370 |
| `T2_snapshot_flag_sites` | 18,758 | 20,123 | 15,853 | 23,661 |
| `T3_compare_two_functions` | 16,058 | 17,795 | 15,307 | 15,361 |

## Wall time (seconds) — mean per cell

| task | codedb | codedb_LEAN | fts5_trigram | leanctx |
|---|---|---|---|---|
| `T0_getNextLanes` | 44.0 | — | 25.0 | 123.0 |
| `T1_setState_trace` | 108.0 | 226.0 | 95.0 | 91.0 |
| `T2_snapshot_flag_sites` | 55.0 | 46.0 | 49.0 | 121.0 |
| `T3_compare_two_functions` | 28.0 | 52.0 | 29.0 | 61.0 |

## Pareto frontier

A backend is **Pareto-dominant** if no other backend beats it on all three axes (quality higher, tokens lower, wall lower).

| backend | quality | tokens | wall (s) | status |
|---|---|---|---|---|
| fts5_trigram | 5.00 | 15,890 | 49.5 | **PARETO-OPTIMAL** |
| codedb | 4.50 | 19,606 | 58.8 | dominated by: fts5_trigram |
| codedb_LEAN | 4.33 | 24,474 | 108.0 | dominated by: codedb, fts5_trigram |
| leanctx | 4.25 | 19,651 | 99.0 | dominated by: codedb, fts5_trigram |
