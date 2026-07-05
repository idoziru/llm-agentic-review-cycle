# Testing

The goal — verify orchestrator logic **without real calls** to `claude`/`codex`/`mimo`/`agy`
(they spend the user's tokens and require confirmation). Approach: mock `run_agent`.

## The `.pyc` compilation trap

`python3 -m py_compile arc` can fail in a sandbox when writing `.pyc` to the system
cache. Point it to your own cache directory:

```bash
export PYTHONPYCACHEPREFIX="$SCRATCHPAD/pycache"
python3 -m py_compile arc && echo OK
```

Alternative without writing `.pyc`: `python3 -c "import ast; ast.parse(open('arc').read())"`.

## Mock agent

`run_agent` is the single point of contact with the outside world. Substitute it:

```python
import importlib.util, os
spec = importlib.util.spec_from_file_location("arc", "arc")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
def fake(agent, prompt, writes, project_root):
    if "Phase 0" in prompt: return True, "NO QUESTIONS", False
    if "reviewer" in prompt:          # rough heuristic — see note below
        ... # write *_review.md with "APPROVED"/"CHANGES"
        return True, "APPROVED", False
    return True, "done", False
d.run_agent = fake
```

Important: developer prompts also contain the word "reviewer" (in feedback) — do not
distinguish steps by the substring "reviewer" in `prompt`. A more reliable approach:
distinguish by filename in the prompt (`spec_review.md` / `impl_review.md`) or test
functions in isolation.

## What to cover

- `parse_models` — on the real `models.md` (including hiding inactive lines).
- `parse_verdict` — cases: APPROVED on last line; CHANGES; both words
  (expect APPROVED — last line has priority, contracts.md §2); no tokens (INVALID); empty.
- `render` + placeholder coverage (script below).
- `state` save/load — that `_project_root` is not written to file.
- Log/summary — that when `>LOG_WINDOW` entries exist, old ones are compressed by a
  cheap model and `summarized_count` advances.
- Lock — repeated acquisition is blocked; release removes it.
- archive/clear — `.lock` and `archive/` survive.
- `has_prior_run` — reacts to `answers.md`/`state.json`, not only `spec/log`.
- E2E with mock agent: phase0 → spec APPROVED → impl APPROVED → `done`.
- Pause branch: limit exhausted → "continue N" extends limit; "stop" terminates.
  Transition to the next phase is only possible via APPROVED from reviewer.

## Placeholder coverage check

```python
import re, glob, os, importlib.util
spec = importlib.util.spec_from_file_location("arc", "arc")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
prov = {"explore":{"TASK","LOG"},
        "spec_write":{"TASK","LOG","ANSWERS","SPEC_REVIEW","PRIOR_RUN_NOTE"},
        "impl":{"TASK","LOG","ANSWERS","IMPL_REVIEW","PRIOR_RUN_NOTE"},
        "spec_review":{"TASK","LOG","ANSWERS","PREV_REVIEW"},
        "impl_review":{"TASK","LOG","ANSWERS","PREV_REVIEW"},
        "log_summary":{"PREV_SUMMARY","NEW_ENTRIES"}}
for f in glob.glob("prompts/*.md"):
    n=os.path.basename(f)[:-3]
    ph=set(re.findall(r"\{\{([A-Z_]+)\}\}", open(f).read()))
    assert ph <= prov[n], (n, ph - prov[n])
print("OK")
```

## Live smoke test (with user consent)

A real run spends tokens — only run with explicit approval. Minimal contract check
for one CLI, e.g. claude via stdin:

```bash
printf 'Reply with one word: hello' | \
  claude -p --model sonnet --output-format stream-json \
  --no-session-persistence --dangerously-skip-permissions
```
