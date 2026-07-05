# Invariants and contracts

What must not be broken when making changes: the loop depends on these contracts.
Behavioral rationale is in the spec; here — what and where in the code enforces it.

## 1. Prompt placeholders ⊆ step mapping

`render` will silently leave an unfilled `{{KEY}}` in the prompt if the orchestrator
did not pass it. Every placeholder in `prompts/<name>.md` must be present in the
mapping of the corresponding step in `arc`:

| Step (prompt) | Mapping in code | Keys |
|---|---|---|
| `explore` | phase0 | `TASK, LOG` |
| `spec_write` | `dev_map` | `TASK, LOG, ANSWERS, SPEC_REVIEW, PRIOR_RUN_NOTE` |
| `impl` | `dev_map` | `TASK, LOG, ANSWERS, IMPL_REVIEW, PRIOR_RUN_NOTE` |
| `spec_review`, `impl_review` | `rev_map` | `TASK, LOG, ANSWERS, PREV_REVIEW` |
| `log_summary` | summary | `PREV_SUMMARY, NEW_ENTRIES` |

Extra keys in the mapping are harmless (ignored). Missing keys are a bug. When
adding a placeholder to a prompt, update the mapping (see [extending.md](extending.md));
verification — in [testing.md](testing.md).

## 2. Verdict contract

`parse_verdict` (case-insensitive, by substring match):
1. Last non-empty line: contains `APPROVED` → APPROVED; else contains `CHANGES` → CHANGES.
2. Otherwise across the full text: `CHANGES` takes priority (safer to continue the loop).
3. No tokens → `INVALID`, which the caller treats as `CHANGES`.

Review prompts must output the verdict **as exactly one word on the last line**
and must not use the words `APPROVED`/`CHANGES` in prose — otherwise the parser
may misfire. Changing the parsing rule must be done in sync with the prompts.

## 3. Agent response normalization

`run_agent` always returns **plain text** (claude → `result` from JSON events
`assistant`/`result`; codex → `item.completed` from `--json` stdout; mimo →
text type events from `--format json` stdout; agy → plain text from stdout).
JSON is parsed inside `run_agent`; only text is returned. All text contracts
(`NO QUESTIONS`, verdict, summary) apply to this text. `ok=False` if exit code ≠0,
text is empty, or timeout. The third tuple element `timed_out` = `True` on
`TimeoutExpired` (emptiness check is on normalized text, not raw stdout).

## 4. Stateless agents

Each call is independent. The prompt must instruct the agent to gather context
in that same call (study the project/code/`spec.md`). It cannot rely on the agent
"remembering" a previous step. This is a prompt contract, not a code contract.

## 5. `models.md` schema

- Sections per CLI: `<!-- models:<cli>:start -->` … `<!-- models:<cli>:end -->`.
- Inside — **one model per line**: `<ID> | <name>` (name optional → ID used).
  The CLI comes from the section header, not a separate column.
- Skipped: blank lines, comments (`#`, `<!--`), inactive lines
  (empty ID or ID in parentheses, e.g. `(taken from ...)`).
- `parse_models` reads only lines between markers. No valid models → `die`.

## 6. `_agent/` files (roles)

| File | Written by | Purpose |
|---|---|---|
| `spec.md` | developer (Phase 1) | Spec; source of truth for impl and review |
| `answers.md` | orchestrator (Phase 0) | User answers; source of `{{ANSWERS}}` and skip-questions on resume |
| `spec_review.md`/`impl_review.md` | reviewer | Review + verdict |
| `log.md` | orchestrator | Full log (append-only) |
| `log_summary.md` | orchestrator (summary agent) | Compressed old iterations |
| `state.json` | orchestrator | Resume state |
| `.lock` | orchestrator | Prevents double launch |

`archive_agent`/`clear_agent` must **not touch** `archive/` and `.lock`.

## 7. `state.json`

Fields: `phase` (`phase0|spec|impl|done`), `iteration`, `developer`, `reviewer`,
`spec_cycles`, `impl_cycles`, `last_verdict`, `task`, `summarized_count`.
Runtime fields with the `_` prefix (e.g. `_project_root`) are not written to file
(`make_saver` filters them). When adding a field, maintain backward compatibility:
`load_state` must tolerate missing fields (`setdefault`).

## 8. `spec.md` contract

Required sections (see spec "spec.md contract"): Goal; Scope and out of scope;
Affected files/modules; Step-by-step plan; Acceptance criteria; Assumptions and
constraints. Enforced in `spec_write.md` (writer) and `spec_review.md` (checker) —
change both in sync.
