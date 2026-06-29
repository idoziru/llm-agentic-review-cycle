# Architecture

The rationale for the orchestrator + stateless model (vs sessions / interactive agents)
is covered in the spec. This document describes how it works in code.

## Two sides of the system

- **Orchestrator** (`arc`) — the sole owner of state and loop logic.
  Handles all user interaction, `_agent/` files, and phase ordering.
- **Agents** (`claude` / `codex` / `mimo` / `agy`) — invoked as **one-shot headless processes**
  (`run_agent`). They remember nothing between calls. All context is passed fresh
  in the prompt each time.

Key implication: **each agent call must gather the context it needs on its own**
(read the project/code/`spec.md`). That is why prompts explicitly instruct agents
to study the current state rather than "remember" a previous step. Violating this
principle is a common source of bugs (see [gotchas.md](gotchas.md)).

## Control flow (phases)

`state["phase"]` ∈ `phase0 | spec | impl | done`. The main loop in `main()`
dispatches by phase:

```
phase0  -> phase0()          -> sets phase=spec
spec    -> review_loop(spec) -> returns 'impl' or 'stop'
impl    -> review_loop(impl) -> returns 'done' or 'stop'
done    -> print "Done ✓", exit
```

`review_loop` is structurally identical for both phases; it differs only in parameters
(`kind='spec'|'impl'`): which prompts, which review file, which limit, which next phase.

### One pass of review_loop

```
while iteration < limit:
    build_context()                  # {{LOG}} = summary + last K iterations
    developer (writes spec.md / code)  # run_step -> append_log
    build_context()
    reviewer  (writes *_review.md)    # run_step -> append_log
    verdict = parse_verdict(review)  # APPROVED / CHANGES / INVALID->CHANGES
    if APPROVED: phase=next; return
limit exhausted -> pause_menu: continue N / stop  # transition without APPROVED is impossible
```

## Data flow

```
CLI args ───────┐
models.md ──────┼─> configuration (developer/reviewer/limits) ─> state.json
user answers ───┘                                                    │
                                                                    ▼
                              prompt = render(template, {placeholders})
                                                                    │
                                          run_agent (claude/codex/mimo/agy, stdin)
                                                                    │
                           normalized response text ────────────────┤
                                                                    ▼
                    _agent/* (spec.md, *_review.md, project code) + log.md
```

State is passed between iterations **only through files** in `_agent/` and through
the log injected into `{{LOG}}`.

## Log and summary layer

- `log.md` — full append-only log. Each entry is separated by `ENTRY_SEP`;
  written by `append_log`, parsed by `parse_entries`.
- The prompt receives not the full log, but `{{LOG}}` = `log_summary.md` + the last
  `LOG_WINDOW` (=5) entries (`build_context`).
- When entries fall outside the window, `maybe_update_summary` compresses them into
  `log_summary.md` via a separate cheap agent call (`summary_agent`), advancing
  `state["summarized_count"]`. On summary failure — fallback to raw concatenation
  (no context is lost).

## Resume

`state.json` — machine state (phase, iteration, agent selection, limits,
task, `summarized_count`). Rewritten after each significant step
(`make_saver` → `save()`). On re-launch, `has_prior_run` + the lifecycle menu
decide: continue (read `state.json`), archive, or clear. Contract details are
in the spec, "Resume and state.json" section.

## Isolation and parallelism

- **Per-project lock**: `_agent/.lock` with PID (`acquire_lock`/`release_lock`).
- **CLI state isolation**: claude — `--no-session-persistence`; codex —
  temporary `CODEX_HOME` with injected auth (`codex_home`).
- Parallelism — only different projects in different terminals (see spec).
