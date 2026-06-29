# Code map — `arc`

Single file, stdlib only. Divided into sections by `# --- ... ---` comments.
Below — responsibilities and key functions for quick navigation.

## Constants (top of file)

- `TOOL_ROOT` — real directory of `arc` (via `realpath`, so symlinks in PATH work).
  `PROMPTS_DIR` and `MODELS_FILE` are resolved from it.
- `DEFAULT_SPEC_CYCLES=3`, `DEFAULT_IMPL_CYCLES=5` — default limits.
- `LOG_WINDOW=5` — how many recent log entries go into the prompt in full (K).
- `AGENT_TIMEOUT=1500` — single agent call timeout (seconds, 25 minutes).
- `CHEAP_CLAUDE_MODEL` — model used for summaries when developer is on claude.
- `ENTRY_SEP` — entry separator in `log.md`.
- `_LOCK_PATH`, `_CODEX_HOME` — globals for cleanup on exit (atexit).

## Utilities

`now_iso`, `read_text` (missing file → `""`), `write_text` (creates directories),
`die(msg, code)` (print to stderr + `sys.exit`).

## Interactive input

- `positive_int` — argparse type: positive integer (validates limits from CLI).
- `ask_line` — single line; EOF → exit.
- `ask_int` — integer with default, checks >0.
- `ask_choice(title, options)` — menu `[(label, value)]`, returns value.
- `ask_multiline(header)` — multiline input until EOF (for Phase 0 answers).

## Models

- `parse_models()` — reads `models.md`, sections `<!-- models:<cli>:start/end -->`,
  lines `<ID> | <name>` (one model per line, CLI from section); skips blank lines,
  comments, and inactive lines (empty ID or ID in parentheses). No valid models → `die`.
  Schema — in [contracts.md](contracts.md).
- `choose_agent(role, models)` — builds menu from models, returns `{cli, id}`.

## Lock

`_pid_alive`, `acquire_lock` (via `O_CREAT|O_EXCL`, takes over stale lock of dead PID),
`release_lock` (removes only its own lock).

## Codex isolation

`codex_home()` — lazily creates a temporary `CODEX_HOME`, copies the user's
`auth.json`/`config.toml` into it (preserves auth). `cleanup_codex_home`
removes it on exit.

## Agent invocation

`run_agent(agent, prompt, writes, project_root) -> (ok, text, timed_out)` — the single
point for launching a CLI:
- claude: `claude -p --model <id> --output-format stream-json --verbose
  --no-session-persistence --dangerously-skip-permissions`, prompt via stdin,
  response from JSON events `assistant`/`result` in stdout (text is printed to stderr).
- codex: `codex exec --json [-m <id>] -s <read-only|workspace-write>
  -c approval_policy="never"`, prompt via stdin, response from `item.completed` in
  `--json` stdout. If `id is None` — `-m` is omitted (model from codex config).
- mimo: `mimo run --format json --model <id> --dangerously-skip-permissions`,
  prompt via stdin, response from text type events in JSON stdout.
- agy: `agy -p --model <id> --dangerously-skip-permissions [--sandbox]`,
  prompt via stdin, response from stdout (text streamed char-by-char to stderr).
- `writes` controls codex sandbox and agy sandbox. `ok` = exit code 0 and non-empty normalized text.

## Prompts

`load_prompt(name)` — reads `prompts/<name>.md`. `render(template, mapping)` —
replaces `{{KEY}}`. Step-to-placeholder mapping — in [contracts.md](contracts.md).

## Log, summary, state

- `agent_paths(agent_dir)` — dictionary of all `_agent/` file paths.
- `append_log`, `parse_entries` — write/parse `log.md`.
- `maybe_update_summary`, `build_context`, `summary_agent` — summary layer
  (see [architecture.md](architecture.md)).
- `new_state`, `make_saver` (returns `save()`, skips fields with `_`),
  `load_state` (None on missing/corrupted file).

## Loop logic

- `parse_verdict(text)` — `APPROVED|CHANGES|INVALID` (rule in [contracts.md](contracts.md)).
- `run_step(...)` — agent call with error logging and retry/stop. **Note:**
  takes `agent_dir, phase, iteration, role` specifically to write failed iterations
  to the log.
- `pause_menu(phase_name, limit)` — menu when limit is exhausted.
- `phase0(agent_dir, state, save)` — Phase 0; creates `answers.md`, sets
  `phase=spec`. Returns False on stop.
- `review_loop(agent_dir, state, save, kind)` — Phases 1/2; returns next phase or `'stop'`.

## Lifecycle and configuration

`has_prior_run` (checks `spec/log/answers/state`), `archive_agent`,
`clear_agent` (both leave `archive/` and `.lock` untouched), `setup_state`.

## main()

argparse → `project_root=cwd`, create `_agent/`, atexit cleanup, `acquire_lock`,
`parse_models`, lifecycle branch (continue/archive/clear) → setup if needed →
main phase loop.
