# Available models

Source of truth for developer and reviewer selection. The orchestrator reads this file
and builds the selection menu. One model = one line between section markers
`<!-- models:<cli>:start --> … <!-- models:<cli>:end -->`.

Line format: `<ID> | <human-readable name>` (name is optional — if omitted, the ID is used).
Blank lines, comment lines (`#`), and lines with an ID in parentheses are ignored.
There are no hardcoded model IDs in the code — edit only this file.

---

## Claude (via `claude` CLI)

Launch: `claude -p --model <ID> --output-format stream-json --no-session-persistence --dangerously-skip-permissions` — prompt via stdin.

Only models confirmed through the local console (`claude --help`) are listed below:
the CLI guarantees acceptance of aliases `opus`, `sonnet`, `fable`. Full IDs for
these lines are not exposed by help, so aliases are used in the list rather than
unconfirmed full names.

<!-- models:claude:start -->

claude-fable-5
claude-opus-4-8
claude-sonnet-5
claude-haiku-4-5

<!-- models:claude:end -->

---

## Codex (via `codex` CLI)

Launch: `CODEX_HOME=<per-run> codex exec --json -m <ID> -s <sandbox> -c approval_policy="never"` — prompt via stdin, response from stdout JSON.

Codex accepts the model via `-m`, but only the actually configured model has been
confirmed from the local console: `codex doctor` shows `model gpt-5.5 · openai`.
Only that model is included in the list.

<!-- models:codex:start -->

gpt-5.6-sol medium
gpt-5.6-terra medium
gpt-5.6-luna medium
gpt-5.5
gpt-5.4
gpt-5.4-mini

<!-- models:codex:end -->

---

## MiMo (via `mimo` CLI — MiMo Code)

Launch: `mimo run --format json --model <ID> --dangerously-skip-permissions` — prompt via stdin.

<!-- models:mimo:start -->

mimo/mimo-auto | MiMo Auto (free)

<!-- models:mimo:end -->

---

## Antigravity (via `agy` CLI)

Launch: `agy -p --model <ID> --dangerously-skip-permissions [--sandbox]` — prompt via stdin.

<!-- models:agy:start -->

Gemini 3.5 Flash (Medium)
Gemini 3.5 Flash (High)
Gemini 3.5 Flash (Low)
Gemini 3.1 Pro (Low)
Gemini 3.1 Pro (High)

<!-- models:agy:end -->

---

## How to update

- Claude: check IDs when new versions are released (aliases `fable`/`opus`/`sonnet` —
  from `claude --help`).
- Codex: current default — `grep model ~/.codex/config.toml` or `codex doctor`.
  Add the desired model as a line and select it from the menu.
- MiMo: model list — `mimo models`. The free model `mimo/mimo-auto` is available
  without an API key. Paid models require a key from platform.xiaomimimo.com.
- Antigravity (agy): model list — `agy models`.
