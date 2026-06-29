# Gotchas

Non-obvious places where it is easy to break the system or draw a wrong conclusion.

## Statelessness — the main source of bugs

The agent remembers nothing between calls. If a prompt says "based on the project
you studied" but does not tell the agent to study it in this very call — the agent
operates blind. Check every new or modified prompt for this (contract #4).

## Phase isolation is soft, not guaranteed

"Spec first, then impl" is enforced only by prompt text. The agent can technically
touch code before the spec is approved; the orchestrator neither prevents nor rolls
this back (git is intentionally disabled). Do not describe two-phase as a hard guarantee.

## CODEX_HOME requires injected auth

An empty temporary `CODEX_HOME` will break codex auth. `codex_home()` copies the
user's `auth.json`/`config.toml` — do not remove this. If codex changes its auth
file format, update the list of copied files.

## claude `-p`: prompt via stdin

Verified: `claude -p` reads the prompt from stdin and passes it to the model correctly
(both stdin and positional variants work). The code uses stdin (no argument length
limit for large `{{LOG}}`). `models.md` and the spec describe stdin — keep docs and
code in sync.

## codex: response from `--json` stdout

codex writes JSON events to stdout (`--json`); the final response is in the
`item.completed` event. `run_agent` parses stdout and extracts the text. The
"empty response" criterion is based on normalized text, not the presence of output.

## mimo: response from text type events

mimo writes JSON events to stdout (`--format json`); the response is assembled from
all events of type `text` (field `part.text`). Similar mechanism, but a different
event type — do not confuse with `item.completed` in codex.

## agy: direct output to stdout

Unlike claude, codex, and mimo, `agy` in print mode (`-p`) writes the plain response
text directly to stdout (no JSON wrapper). `run_agent` reads this stream char-by-char
for interactive display to stderr and accumulates the response in a buffer.

## Verdict parser is sensitive to prose

`parse_verdict` matches words by substring. If the reviewer writes "changes" in the
review body, the parser may catch it. The protection is "last line — exactly one word"
in the prompts. Change one → change the other.

## Empty `_agent/` after a failed start

Launching without a task creates `_agent/` and a lock, then `die`; the lock is
released on atexit, but the empty directory remains. This is harmless: `has_prior_run`
looks for specific files; an empty directory does not trigger the lifecycle menu.

## The summary layer costs tokens

Log compression is a separate agent call. On long loops this is noticeable. The model
is cheap (Haiku for claude; config for codex). Do not switch summary to an expensive
model without reason.

## Limits and extension

"Continue N" **adds** to `state[cycles_key]`, it does not replace it. The pause loop
can repeat. `iteration` is not reset on extension (continues from current); it is
reset only on phase transition.

## Parallel runs

Designed for 1–3 runs in **different** projects in **different** terminals. In one
terminal interactive input breaks (stdin contention); in background without a TTY —
also. Do not describe this as background/bulk mode support.

## stdin is occupied by interactive input

The orchestrator reads user answers from stdin (`ask_*`). Prompts are passed to the
agent also via stdin of the child process — these are different streams (parent vs
subprocess `input=`), so there is no conflict. But do not redirect interactive input
to the same channel as agent responses.
