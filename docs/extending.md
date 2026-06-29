# How to extend

Common changes with minimal blast radius. After any of them — run checks from
[testing.md](testing.md) and cross-check with [contracts.md](contracts.md).

## Add / update a model

Edit only [../models.md](../models.md), do not touch the code. Add a line (one model =
one line) to the appropriate section between `<!-- models:<cli>:start/end -->` markers:

```
claude-opus-x-y | Claude Opus X.Y
```

The name after `|` is optional (the ID is used if omitted). The CLI is determined by
the section. Mark an inactive model by wrapping its ID in parentheses or using an
empty ID — it will be excluded from the menu. There are no hardcoded model IDs in
the code (contract #5). Verify `parse_models()`.

## Change a prompt

Prompts are in [../prompts/](../prompts/). When adding a new `{{PLACEHOLDER}}`:
1. Make sure the key exists in the mapping of the corresponding step in `arc`
   (`dev_map`/`rev_map`/phase0/summary). If not — add the value there.
2. Verify placeholder coverage (script in [testing.md](testing.md)).

The `spec.md` and verdict contracts are enforced by prompt pairs — edit them in sync
(`spec_write`↔`spec_review`, both review prompts for verdict format).

## Add a placeholder from existing data

If the value is already in the mapping (e.g. `TASK` is already in `dev_map`/`rev_map`),
just insert `{{TASK}}` in the prompt — no code change needed. Otherwise add the key
to the mapping in `review_loop`/`phase0`.

## Add a new phase

1. Introduce a `state["phase"]` value and handle it in the main loop in `main()`.
2. If it is a developer↔reviewer cycle — reuse `review_loop`, adding a branch
   of parameters by `kind` (prompts, review file, `cycles_key`, `next_phase`).
3. Create prompts in `prompts/` and document them in the spec (the "step → prompt file" table).
4. Update the `state.json` contract for new fields (`load_state` with `setdefault`).

## Add / change a CLI adapter

All launch logic lives in `run_agent`. To add a new CLI:
1. An `if cli == "<name>"` branch in `run_agent`: how to build the command, where to
   pass the prompt (stdin preferred — no argument length limit), where to read the
   response from, how to normalize to plain text.
2. A `<!-- models:<name>:start/end -->` section in `models.md`. `parse_models` already
   supports all four CLIs (`("claude", "codex", "mimo", "agy")`); when adding a fifth —
   extend the tuple.
3. State isolation for parallel runs if needed (follow the `codex_home` pattern).
4. A summary model for the new CLI in `summary_agent`.

## Change limit / pause behavior

`pause_menu` + the `action` branch at the end of `review_loop`. "Continue N" adds to
`state[cycles_key]`. Defaults are `DEFAULT_*` constants; CLI validation — `positive_int`.

## Change the summary layer

`LOG_WINDOW` (window size), `summary_agent` (model), `maybe_update_summary`
(when and how to compress), `prompts/log_summary.md` (compression instructions).
Remember the fallback on summary failure — context must not be lost.

## What not to do without an explicit user request

- Hard phase isolation (read-only sandbox) — intentionally deferred (spec, "Out of scope").
  Current isolation is soft, at the prompt level.
- Git checkpoints / rollback — excluded by user decision.
- Third-party dependencies — project is strictly stdlib.
