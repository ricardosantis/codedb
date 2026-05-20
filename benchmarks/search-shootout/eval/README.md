# QD Eval — Quality × Efficiency matrix for code-search backends

A reproducible, drop-in-extensible eval harness for the search-shootout
benchmark. Produces a **QD matrix** where each cell is (task, backend) →
{quality, tokens, wall, calls}.

## Layout

```
eval/
├── tasks.json         # task definitions (prompt, ground truth, answer shape)
├── backends.json      # backend definitions (constraint prompts)
├── answers/           # one JSON file per (task, backend, rep) cell
│   └── <task>/<backend>-rep<N>.json
├── scores/scores.json # judge output (auto-managed)
├── prompts/           # generated agent prompts (for manual collection)
├── judge.py           # score one or all answers via `claude --print`
├── matrix.py          # aggregate → QD matrix (md + json)
├── qd_matrix.md       # the matrix (auto-generated)
└── qd_matrix.json     # machine-readable matrix
```

## Quick start: produce the matrix from existing data

```bash
python3 matrix.py
```

That reads the persisted answers + scores and emits `qd_matrix.md` + `qd_matrix.json`.

## Add a new backend or task

1. **New backend:** append an entry to `backends.json` with `id`, `name`,
   `constraint_prompt`, and `env`.
2. **New task:** append to `tasks.json` with `id`, `title`, `prompt`,
   `ground_truth`, `answer_shape`.
3. **Collect agent answers** — see "running new evals" below.
4. **Score them:** `python3 judge.py --all` (scores any answer that
   doesn't have a score yet).
5. **Rebuild matrix:** `python3 matrix.py`.

## Running new evals

The harness doesn't itself spawn Claude sub-agents (that requires the
Claude Agent SDK or an `ANTHROPIC_API_KEY`). Two paths:

### Path A: manual collection (works anywhere)

For each (task, backend, rep) you want to add:
1. Construct the agent prompt:
   - Take `task.prompt` + `backend.constraint_prompt` + the standard
     "report JSON matching this shape" trailer.
2. Run a Sonnet 4.6 agent on that prompt against the React corpus.
3. Capture the agent's final JSON answer (matching `task.answer_shape`).
4. Add `tokens`, `wall_seconds`, `tool_calls` fields if you tracked them.
5. Drop the result at `answers/<task_id>/<backend_id>-rep<N>.json`.

### Path B: programmatic via Claude Code

If you're inside a Claude Code session, use the `Agent` tool with
`subagent_type=general-purpose` and `model=sonnet`. The prompt template:

```
{backend.constraint_prompt}

## Task
{task.prompt}

## Report
Track wall time with `date +%s`. End your response with one JSON object
matching this shape:
{task.answer_shape}
Plus: tool_calls (int), wall_seconds (int), tokens (parent records).
```

Capture the result, save under `answers/<task>/<backend>-rep<N>.json`.

## Scoring

### Automatic (uses `claude --print`)

```bash
python3 judge.py --all                       # score everything unscored
python3 judge.py T0_getNextLanes codedb 2    # score one specific cell
python3 judge.py T0_getNextLanes codedb 2 --force  # re-score
python3 judge.py --print-prompt-only --all   # emit prompts for manual scoring
```

The judge uses a 5-point rubric (file, function, snippet, explanation,
completeness) and writes scores to `scores/scores.json`.

### Manual

Use `--print-prompt-only` to emit the judge prompts; paste each into
Claude, capture the trailing JSON, and append to `scores/scores.json`
yourself. Same format as the automatic output.

## Pareto frontier

`matrix.py` computes a Pareto frontier: a backend is Pareto-dominant if
no other backend beats it on quality (higher), tokens (lower), AND wall
time (lower) simultaneously. Pareto-optimal backends are tagged
explicitly in the output.
