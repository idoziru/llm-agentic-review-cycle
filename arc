#!/usr/bin/env python3
"""arc — CLI for loop engineering.

Pure stdlib orchestrator. Run from the project root to execute a two-phase
agentic loop: developer explores the project and agrees on a spec with the user,
then implements it under reviewer supervision. All communication is in the
language of the task.
"""

import argparse
import atexit
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime

# --- Constants -------------------------------------------------------------

# realpath, not abspath: the command is typically installed as a symlink in PATH,
# and assets (prompts/, models.md) live next to the real arc
TOOL_ROOT = os.path.dirname(os.path.realpath(__file__))
PROMPTS_DIR = os.path.join(TOOL_ROOT, "prompts")
MODELS_FILE = os.path.join(TOOL_ROOT, "models.md")

DEFAULT_SPEC_CYCLES = 3
DEFAULT_IMPL_CYCLES = 5

LOG_WINDOW = 5            # K: how many recent iterations are passed to the prompt in full
AGENT_TIMEOUT = 1500      # single agent call timeout, seconds (25 minutes)

# cheap model for the summary layer when developer is on claude
CHEAP_CLAUDE_MODEL = "claude-haiku-4-5-20251001"

ENTRY_SEP = "<!--ENTRY-->"

# Process-level globals for cleanup on exit
_LOCK_PATH = None          # path to the lock file we currently hold
_CODEX_HOME = None         # temporary CODEX_HOME (lazy)


# --- Console styling -------------------------------------------------------

_NO_COLOR = bool(os.environ.get("NO_COLOR"))
# Single flag: disable color if NO_COLOR or stderr is not a TTY.
# stderr is chosen as the master stream: claude streams into it; if it is
# redirected, the session is likely non-interactive.
_COLOR = not _NO_COLOR and hasattr(sys.stderr, "isatty") and sys.stderr.isatty()


def _c(text, *codes):
    """ANSI styling; falls back to plain text if _COLOR=False."""
    if not _COLOR or not codes:
        return text
    seq = ";".join(str(c) for c in codes)
    return f"\033[{seq}m{text}\033[0m"


def bold(t):   return _c(t, 1)
def dim(t):    return _c(t, 2)
def green(t):  return _c(t, 1, 32)
def red(t):    return _c(t, 1, 31)
def yellow(t): return _c(t, 1, 33)

def dim_e(t):  return _c(t, 2)      # alias for readability in stderr contexts
def red_e(t):  return _c(t, 1, 31)  # alias for readability in stderr contexts


def phase_header(label):
    """Bold phase/iteration header with dim-yellow separator lines."""
    sep = _c("─" * 60, 2, 33)  # dim yellow: \033[2;33m
    return f"\n{sep}\n  {bold(label)}\n{sep}"


# --- Basic utilities -------------------------------------------------------

def now_iso():
    return datetime.now().isoformat(timespec="seconds")


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def write_text(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def die(msg, code=1):
    print(red_e(f"Error: {msg}"), file=sys.stderr)
    sys.exit(code)


# --- Interactive input -----------------------------------------------------

def positive_int(s):
    """argparse type: positive integer."""
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer")
    if v <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return v


def ask_line(prompt):
    """Read one line. EOF is treated as cancellation → exit."""
    try:
        return input(prompt)
    except EOFError:
        print()
        die("input interrupted", 130)


def ask_int(prompt, default):
    while True:
        raw = ask_line(f"{prompt} {dim('(default: ' + str(default) + ')')}\n> ").strip()
        if raw == "":
            return default
        if raw.isdigit() and int(raw) > 0:
            return int(raw)
        print(dim("Enter a positive integer."))


def ask_choice(title, options):
    """options: list of (label, value). Returns value."""
    print(bold(title))
    for i, (label, _) in enumerate(options, 1):
        print(f"  {dim(str(i) + '.')} {label}")
    while True:
        raw = ask_line("> ").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1][1]
        print(dim(f"Enter a number from 1 to {len(options)}."))


def ask_multiline(header):
    """Read a multiline answer until EOF (Ctrl-D)."""
    print(bold(header))
    print(dim("(type your answer; press Enter then Ctrl+D to finish)"))
    print("> ", end="", flush=True)
    data = sys.stdin.read()
    print()
    return data.strip()


# --- Parsing models.md -----------------------------------------------------

def parse_models():
    """Return a list of {label, cli, id} dicts from models.md.

    Format: one model per line `<ID> | <name>` between section markers
    `<!-- models:<cli>:start --> … <!-- models:<cli>:end -->`. Name is optional.
    Blank lines, comments (`#`/`<!--`), and lines with ID in parentheses are skipped.
    """
    text = read_text(MODELS_FILE)
    if not text:
        die(f"file not found: {MODELS_FILE}")

    models = []
    for cli in ("claude", "codex", "mimo", "agy"):
        start = f"<!-- models:{cli}:start -->"
        end = f"<!-- models:{cli}:end -->"
        si = text.find(start)
        ei = text.find(end)
        if si == -1 or ei == -1 or ei < si:
            continue
        section = text[si + len(start):ei]
        for line in section.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("<!--"):
                continue
            parts = [p.strip() for p in line.split("|")]
            mid = parts[0]
            label = parts[1] if len(parts) > 1 and parts[1] else mid
            # inactive line: empty ID or ID in parentheses (marker/comment)
            if not mid or mid.startswith("("):
                continue
            models.append({"label": label, "cli": cli, "id": mid})

    if not models:
        die("no valid models found in models.md — check the format")
    return models


def choose_agent(role, models):
    options = [(f"{m['label']}  ({m['cli']} / {m['id']})", m) for m in models]
    return ask_choice(f"Who will be the {role}?", options)


# --- Per-project lock -------------------------------------------------------

def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def acquire_lock(agent_dir):
    global _LOCK_PATH
    path = os.path.join(agent_dir, ".lock")
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            _LOCK_PATH = path
            return
        except FileExistsError:
            old = read_text(path).strip()
            if old.isdigit() and _pid_alive(int(old)):
                print(yellow(f"\narc process (PID {old}) is already running in this project."))
                choice = ask_choice("What to do?", [
                    (f"Terminate process {old} and take over", "kill"),
                    ("Stop", "stop"),
                ])
                if choice == "kill":
                    try:
                        os.kill(int(old), 15)  # SIGTERM
                        time.sleep(1)
                        if _pid_alive(int(old)):
                            os.kill(int(old), 9)  # SIGKILL if still alive
                    except (ProcessLookupError, PermissionError):
                        pass
                    try:
                        os.remove(path)
                    except FileNotFoundError:
                        pass
                    continue  # retry acquiring the lock
                die("launch cancelled")
            # stale lock: owner is dead — take it over
            try:
                os.remove(path)
            except FileNotFoundError:
                pass


def release_lock():
    global _LOCK_PATH
    if _LOCK_PATH and os.path.exists(_LOCK_PATH):
        try:
            if read_text(_LOCK_PATH).strip() == str(os.getpid()):
                os.remove(_LOCK_PATH)
        except OSError:
            pass
    _LOCK_PATH = None


# --- CODEX_HOME isolation --------------------------------------------------

def codex_home():
    """Temporary CODEX_HOME with the user's auth/config injected."""
    global _CODEX_HOME
    if _CODEX_HOME:
        return _CODEX_HOME
    real = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    tmp = tempfile.mkdtemp(prefix="arc-codex-")
    for name in ("auth.json", "config.toml"):
        src = os.path.join(real, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(tmp, name))
    _CODEX_HOME = tmp
    return tmp


def cleanup_codex_home():
    if _CODEX_HOME and os.path.isdir(_CODEX_HOME):
        shutil.rmtree(_CODEX_HOME, ignore_errors=True)


# --- Agent invocation -------------------------------------------------------

def _find_mimo():
    """Find the mimo binary (MiMo Code). Checks ~/.mimocode/bin, then PATH."""
    local_bin = os.path.expanduser("~/.mimocode/bin/mimo")
    if os.path.isfile(local_bin) and os.access(local_bin, os.X_OK):
        return local_bin
    found = shutil.which("mimo")
    if found:
        return found
    die("mimo not found: install MiMo Code (https://mimo.xiaomi.com/mimocode/install)")


def _codex_timer(stop_event, start_time):
    """Background thread: prints elapsed time to stderr every 60 seconds."""
    interval = 60
    while not stop_event.wait(interval):
        elapsed = int(time.monotonic() - start_time)
        print(dim_e(f"  • {elapsed} sec..."), file=sys.stderr, flush=True)


def run_agent(agent, prompt, writes, project_root, timeout=AGENT_TIMEOUT):
    """Invoke a CLI agent. Returns (ok, text, timed_out). timed_out=True only on TimeoutExpired.

    agent: {cli, id}; writes: whether write access is needed (for codex sandbox).
    ok = exit code 0 and non-empty normalized response text.
    claude: streams text_delta to stderr in real time.
    codex:  prints a timer every 60 sec; reads response from --json stdout.
    """
    cli = agent["cli"]
    mid = agent["id"]
    try:
        if cli == "claude":
            cmd = [
                "claude", "-p",
                "--model", mid,
                "--output-format", "stream-json",
                "--verbose",
                "--no-session-persistence",
                "--dangerously-skip-permissions",
            ]
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,  # inherited: claude errors go to the terminal
                text=True,
                cwd=project_root,
            )
            buf = []
            # watchdog thread kills the process after timeout seconds,
            # even if the for-loop is blocked reading from an empty stdout
            _wd_stop = threading.Event()
            _wd_killed = [False]

            def _watchdog():
                if not _wd_stop.wait(timeout):
                    _wd_killed[0] = True
                    proc.kill()

            wd = threading.Thread(target=_watchdog, daemon=True)
            try:
                proc.stdin.write(prompt)
                proc.stdin.close()
                wd.start()
                result_text = None
                for line in proc.stdout:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    ev_type = ev.get("type")
                    if ev_type == "assistant":
                        # claude -p stream-json: text arrives in assistant events
                        for block in ev.get("message", {}).get("content", []):
                            if block.get("type") == "text":
                                chunk = block.get("text", "")
                                if chunk:
                                    print(chunk, end="", file=sys.stderr, flush=True)
                                    buf.append(chunk)
                    elif ev_type == "result":
                        # final response — authoritative text source
                        result_text = ev.get("result", "").strip()
                if result_text is not None:
                    buf = [result_text]
            finally:
                _wd_stop.set()
                wd.join()
                proc.stdout.close()
                proc.wait()
            if buf:
                print(file=sys.stderr)  # newline after stream
            if _wd_killed[0]:
                return False, "", True
            answer = "".join(buf).strip()
            ok = proc.returncode == 0 and answer != ""
            if not ok:
                parts = []
                if proc.returncode != 0:
                    parts.append(f"exit code {proc.returncode}")
                if not answer:
                    parts.append("empty response")
                print(red_e(f"\n[claude] error: {'; '.join(parts)}"), file=sys.stderr, flush=True)
            return ok, answer, False

        if cli == "codex":
            sandbox = "workspace-write" if writes else "read-only"
            env = os.environ.copy()
            env["CODEX_HOME"] = codex_home()
            cmd = ["codex", "exec", "--json"]
            if mid:  # mid=None → model taken from codex config
                cmd += ["-m", mid]
            cmd += [
                "-s", sandbox,
                "-c", 'approval_policy="never"',
            ]
            t0 = time.monotonic()
            stop_evt = threading.Event()
            timer = threading.Thread(target=_codex_timer, args=(stop_evt, t0), daemon=True)
            timer.start()
            completed = False
            try:
                proc = subprocess.run(
                    cmd, input=prompt, capture_output=True, text=True,
                    cwd=project_root, env=env, timeout=timeout,
                )
                completed = True
            finally:
                stop_evt.set()
                timer.join()
                elapsed = int(time.monotonic() - t0)
                label = "done" if completed else "interrupted"
                print(dim_e(f"  {label} ({elapsed} sec)"), file=sys.stderr, flush=True)
            # response from --json stdout: look for item.completed with agent_message
            answer = ""
            for line in (proc.stdout or "").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (ev.get("type") == "item.completed"
                        and ev.get("item", {}).get("type") == "agent_message"):
                    answer = ev["item"].get("text", "").strip()
            ok = proc.returncode == 0 and answer != ""
            if not ok:
                parts = []
                if proc.returncode != 0:
                    parts.append(f"exit code {proc.returncode}")
                if not answer:
                    parts.append("empty agent_message")
                if proc.stderr and proc.stderr.strip():
                    parts.append(f"stderr:\n{proc.stderr.strip()}")
                print(red_e(f"\n[codex] error: {'; '.join(parts)}"), file=sys.stderr, flush=True)
            return ok, answer, False

        if cli == "mimo":
            mimo_bin = _find_mimo()
            cmd = [
                mimo_bin, "run",
                "--format", "json",
                "--model", mid,
                "--dangerously-skip-permissions",
            ]
            t0 = time.monotonic()
            stop_evt = threading.Event()
            timer = threading.Thread(target=_codex_timer, args=(stop_evt, t0), daemon=True)
            timer.start()
            completed = False
            try:
                proc = subprocess.run(
                    cmd, input=prompt, capture_output=True, text=True,
                    cwd=project_root, timeout=timeout,
                )
                completed = True
            finally:
                stop_evt.set()
                timer.join()
                elapsed = int(time.monotonic() - t0)
                label = "done" if completed else "interrupted"
                print(dim_e(f"  {label} ({elapsed} sec)"), file=sys.stderr, flush=True)
            # response from --format json: collect all text-type events
            answer_parts = []
            for line in (proc.stdout or "").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("type") == "text":
                    text_chunk = ev.get("part", {}).get("text", "")
                    if text_chunk:
                        print(text_chunk, end="", file=sys.stderr, flush=True)
                        answer_parts.append(text_chunk)
            if answer_parts:
                print(file=sys.stderr)
            answer = "".join(answer_parts).strip()
            ok = proc.returncode == 0 and answer != ""
            if not ok:
                parts = []
                if proc.returncode != 0:
                    parts.append(f"exit code {proc.returncode}")
                if not answer:
                    parts.append("empty response")
                if proc.stderr and proc.stderr.strip():
                    parts.append(f"stderr:\n{proc.stderr.strip()}")
                print(red_e(f"\n[mimo] error: {'; '.join(parts)}"), file=sys.stderr, flush=True)
            return ok, answer, False

        if cli == "agy":
            cmd = [
                "agy", "-p",
                "--model", mid,
                "--dangerously-skip-permissions",
            ]
            if not writes:
                cmd.append("--sandbox")

            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=project_root,
            )
            buf = []
            _wd_stop = threading.Event()
            _wd_killed = [False]

            def _watchdog():
                if not _wd_stop.wait(timeout):
                    _wd_killed[0] = True
                    proc.kill()

            wd = threading.Thread(target=_watchdog, daemon=True)
            try:
                proc.stdin.write(prompt)
                proc.stdin.close()
                wd.start()
                while True:
                    chunk = proc.stdout.read(1)
                    if not chunk:
                        break
                    print(chunk, end="", file=sys.stderr, flush=True)
                    buf.append(chunk)
            finally:
                _wd_stop.set()
                wd.join()
                proc.stdout.close()
                stderr_content = proc.stderr.read()
                proc.stderr.close()
                proc.wait()

            if buf:
                print(file=sys.stderr)  # newline after stream
            if _wd_killed[0]:
                return False, "", True

            answer = "".join(buf).strip()
            ok = proc.returncode == 0 and answer != ""
            if not ok:
                parts = []
                if proc.returncode != 0:
                    parts.append(f"exit code {proc.returncode}")
                if not answer:
                    parts.append("empty response")
                if stderr_content.strip():
                    parts.append(f"stderr:\n{stderr_content.strip()}")
                print(red_e(f"\n[agy] error: {'; '.join(parts)}"), file=sys.stderr, flush=True)
            return ok, answer, False

        die(f"unknown CLI: {cli}")
    except subprocess.TimeoutExpired:
        return False, "", True
    except FileNotFoundError:
        die(f"CLI '{cli}' not found in PATH")


# --- Prompts ---------------------------------------------------------------

def load_prompt(name):
    path = os.path.join(PROMPTS_DIR, f"{name}.md")
    if not os.path.exists(path):
        die(f"prompt not found: {path}")
        return ""
    content = read_text(path)
    if not content.strip():
        die(f"prompt not found: {path}")
        return ""

    import re
    # Recursive {{include:filename}} resolution
    def replacer(match):
        inc_name = match.group(1)
        return load_prompt(inc_name)

    return re.sub(r'\{\{include:([a-zA-Z0-9_-]+)\}\}', replacer, content)


def render(template, mapping):
    out = template
    for key, value in mapping.items():
        out = out.replace("{{" + key + "}}", value)
    return out


# --- Log and summary layer -------------------------------------------------

def agent_paths(agent_dir):
    return {
        "spec": os.path.join(agent_dir, "spec.md"),
        "answers": os.path.join(agent_dir, "answers.md"),
        "spec_review": os.path.join(agent_dir, "spec_review.md"),
        "impl_review": os.path.join(agent_dir, "impl_review.md"),
        "log": os.path.join(agent_dir, "log.md"),
        "log_summary": os.path.join(agent_dir, "log_summary.md"),
        "state": os.path.join(agent_dir, "state.json"),
    }


def append_log(agent_dir, phase, iteration, role, status, body):
    p = agent_paths(agent_dir)["log"]
    header = f"[{now_iso()}] phase={phase} iter={iteration} role={role} status={status}"
    entry = f"\n{ENTRY_SEP}\n### {header}\n{body.strip()}\n"
    with open(p, "a", encoding="utf-8") as f:
        f.write(entry)


def parse_entries(agent_dir):
    text = read_text(agent_paths(agent_dir)["log"])
    parts = [e.strip() for e in text.split(ENTRY_SEP)]
    return [e for e in parts if e]


def maybe_update_summary(agent_dir, state, save):
    """Compress iterations that have fallen outside the last LOG_WINDOW window into the summary."""
    entries = parse_entries(agent_dir)
    target = max(0, len(entries) - LOG_WINDOW)
    done = state.get("summarized_count", 0)
    if target <= done:
        return
    new_entries = entries[done:target]
    prev = read_text(agent_paths(agent_dir)["log_summary"])
    prompt = render(load_prompt("log_summary"), {
        "PREV_SUMMARY": prev,
        "NEW_ENTRIES": "\n\n".join(new_entries),
    })
    spec = summary_agent(state)
    ok, ans, _ = run_agent(spec, prompt, False, state["_project_root"])
    if ok and ans.strip():
        write_text(agent_paths(agent_dir)["log_summary"], ans.strip())
    else:
        # fallback: don't lose information — append raw entries
        merged = (prev + "\n\n" + "\n\n".join(new_entries)).strip()
        write_text(agent_paths(agent_dir)["log_summary"], merged)
    state["summarized_count"] = target
    save()


def prior_run_note(agent_dir):
    """Returns a reminder to study the previous run, if one exists."""
    paths = agent_paths(agent_dir)
    has_history = (
        bool(read_text(paths["log"]).strip())
        or bool(read_text(paths["log_summary"]).strip())
    )
    if not has_history:
        return ""
    return (
        "\n⚠️ This is a continuation of a previous run. The _agent/ directory contains "
        "results from prior work. Before starting:\n"
        "1. Read _agent/spec.md — the already written spec (if present).\n"
        "2. Study the iteration log below — what was done, approved, rejected.\n"
        "3. Read the current state of the project code.\n"
        "Do not rewrite from scratch what has already been done correctly. "
        "Only revise or fix what needs to be changed.\n"
    )


def build_context(agent_dir, state, save):
    maybe_update_summary(agent_dir, state, save)
    entries = parse_entries(agent_dir)
    window = entries[max(0, len(entries) - LOG_WINDOW):]
    summary = read_text(agent_paths(agent_dir)["log_summary"]).strip()
    parts = []
    if summary:
        parts.append("# Summary of previous iterations\n" + summary)
    if window:
        parts.append("# Recent iterations\n" + "\n\n".join(window))
    return "\n\n".join(parts)


def summary_agent(state):
    dev = state["developer"]
    if dev["cli"] == "claude":
        return {"cli": "claude", "id": CHEAP_CLAUDE_MODEL}
    if dev["cli"] == "mimo":
        return {"cli": "mimo", "id": "mimo/mimo-auto"}
    if dev["cli"] == "agy":
        return {"cli": "agy", "id": "Gemini 3.5 Flash (Low)"}
    # codex: summary model taken from codex config (id=None → no -m flag)
    return {"cli": dev["cli"], "id": None}


# --- State -----------------------------------------------------------------

def new_state(project_root):
    return {
        "phase": "phase0",
        "iteration": 0,
        "developer": {},
        "reviewer": {},
        "spec_cycles": DEFAULT_SPEC_CYCLES,
        "impl_cycles": DEFAULT_IMPL_CYCLES,
        "last_verdict": "none",
        "task": "",
        "summarized_count": 0,
        "_project_root": project_root,
    }


def make_saver(agent_dir, state):
    path = agent_paths(agent_dir)["state"]

    def save():
        # _project_root is a runtime field — do not write to file
        data = {k: v for k, v in state.items() if not k.startswith("_")}
        write_text(path, json.dumps(data, ensure_ascii=False, indent=2))

    return save


def load_state(agent_dir, project_root):
    path = agent_paths(agent_dir)["state"]
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    data["_project_root"] = project_root
    data.setdefault("summarized_count", 0)
    return data


# --- Verdict parsing --------------------------------------------------------

def parse_verdict(review_text):
    """Return 'APPROVED' / 'CHANGES' / 'INVALID' according to the spec rule."""
    upper = review_text.upper()
    lines = [ln for ln in upper.splitlines() if ln.strip()]
    if lines:
        last = lines[-1]
        if "APPROVED" in last:
            return "APPROVED"
        if "CHANGES" in last:
            return "CHANGES"
    if "CHANGES" in upper:
        return "CHANGES"
    if "APPROVED" in upper:
        return "APPROVED"
    return "INVALID"


# --- Git commit & push after successful completion -------------------------

def generate_commit_msg(agent_dir, state, project_root):
    """Ask the AI to compose a commit message from spec.md and the iteration log."""
    paths = agent_paths(agent_dir)
    spec = read_text(paths["spec"]).strip()
    log_summary = read_text(paths["log_summary"]).strip()
    prompt = (
        "Write a git commit message in one line, no longer than 72 characters.\n"
        "Describe what WAS DONE (the completed work), not the task statement.\n"
        "No quotes, no markdown, no trailing period.\n"
        "Output only one line — the commit message itself.\n\n"
        f"Spec (spec.md):\n{spec[:3000]}\n\n"
        f"Iteration history summary:\n{log_summary[:1500]}"
    )
    agent = summary_agent(state)
    print(dim("  Generating commit message..."))
    ok, text, _ = run_agent(agent, prompt, False, project_root, timeout=120)
    if ok and text.strip():
        # take the first non-empty line — the commit itself, without preamble
        msg = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
        if msg:
            return msg[:72]
    # fallback: first line of the task
    first = state.get("task", "").strip().splitlines()
    return (first[0][:72] if first else "work completed")


def git_commit_and_push(agent_dir, state, project_root):
    """Run git add -A, commit (AI-generated message), and push."""
    def run(cmd):
        return subprocess.run(
            cmd, cwd=project_root, capture_output=True, text=True
        )

    # Check that this is a git repository
    r = run(["git", "rev-parse", "--git-dir"])
    if r.returncode != 0:
        print(dim("  (not a git repository — commit skipped)"))
        return

    msg = generate_commit_msg(agent_dir, state, project_root)

    run(["git", "add", "-A"])

    r = run(["git", "commit", "-m", msg])
    if r.returncode != 0:
        output = r.stdout.strip() or r.stderr.strip()
        if "nothing to commit" in output or "nothing added" in output:
            print(dim("  Commit not created: nothing to commit."))
        else:
            print(yellow(f"  Commit failed: {output}"))
        return

    r_hash = run(["git", "rev-parse", "--short", "HEAD"])
    sha = r_hash.stdout.strip() if r_hash.returncode == 0 else "?"
    print(green(f"  Commit created: {sha}  \"{msg}\""))

    r = run(["git", "push"])
    if r.returncode == 0:
        print(green("  Pushed to remote repository."))
    else:
        err = (r.stderr or r.stdout).strip()
        print(yellow(f"  Push failed: {err}"))
        print(dim("  Commit saved locally — push manually."))


# --- Agent step with error handling ----------------------------------------

def run_step(agent, prompt, writes, project_root, what,
             agent_dir, phase, iteration, role):
    """Invoke agent; on error log it and offer retry/stop.

    Returns (text, stop) — stop=True means the user chose to abort.
    Each failed call is recorded as an error entry in log.md so that the
    summary layer and subsequent iterations see the context of failed attempts.
    """
    while True:
        ok, text, timed_out = run_agent(agent, prompt, writes, project_root)
        if ok:
            return text, False
        append_log(agent_dir, phase, iteration, role, "error",
                   f"Step \"{what}\": empty response, non-zero exit code, or timeout.")
        print("\n" + red(f"✗ Step \"{what}\" failed "
                         f"(empty response, non-zero exit code, or timeout)."))
        choice = ask_choice("What to do?", [
            ("Retry step", "retry"),
            ("Stop", "stop"),
        ])
        if choice == "stop":
            return "", True


# --- Pause on limit exhaustion ----------------------------------------------

def pause_menu(phase_name, limit):
    print("\n" + yellow(f"Attempt limit ({limit}) reached for phase \"{phase_name}\".") +
          "\nThe last version was not approved by the reviewer.")
    choice = ask_choice("How to proceed?", [
        (f"Add {limit} more automatic revision attempts (count can be changed)", "continue"),
        ("Stop (terminate execution)", "stop"),
    ])
    if choice == "continue":
        n = ask_int("How many attempts to add?", limit)
        return ("continue", n)
    return ("stop", 0)


# --- Phase 0 ----------------------------------------------------------------

def phase0(agent_dir, state, save):
    paths = agent_paths(agent_dir)
    # skip the questions step if and only if answers.md already exists
    if not os.path.exists(paths["answers"]):
        print(phase_header("Phase 0 — Developer explores the project"))
        context = build_context(agent_dir, state, save)
        prompt = render(load_prompt("explore"), {
            "TASK": state["task"],
            "LOG": context,
        })
        print(dim_e("→ Developer exploring project..."), file=sys.stderr)
        text, stop = run_step(state["developer"], prompt, False,
                              state["_project_root"], "project exploration",
                              agent_dir, "phase0", 0, "developer")
        if stop:
            return False
        if "NO QUESTIONS" in text.upper():
            write_text(paths["answers"], "no questions\n")
            append_log(agent_dir, "phase0", 0, "developer", "no-questions", text)
        else:
            # Streaming CLIs (claude, agy, mimo) already printed text to stderr in real time.
            # For non-streaming CLIs (e.g. codex) print the questions before prompting for input.
            if state["developer"]["cli"] not in ("claude", "agy", "mimo"):
                print("\n" + text + "\n")
            answers = ask_multiline("Answer the questions:")
            write_text(paths["answers"], answers + "\n")
            append_log(agent_dir, "phase0", 0, "developer", "questions", text)
    state["phase"] = "spec"
    state["iteration"] = 0
    save()
    return True


# --- Review loops (Phase 1 and Phase 2) ------------------------------------

def review_loop(agent_dir, state, save, kind):
    """kind: 'spec' or 'impl'. Returns the next phase or 'stop'."""
    paths = agent_paths(agent_dir)
    if kind == "spec":
        dev_prompt, rev_prompt = "spec_write", "spec_review"
        review_path = paths["spec_review"]
        review_key = "SPEC_REVIEW"
        cycles_key = "spec_cycles"
        phase_name = "spec"
        next_phase = "impl"
    else:
        dev_prompt, rev_prompt = "impl", "impl_review"
        review_path = paths["impl_review"]
        review_key = "IMPL_REVIEW"
        cycles_key = "impl_cycles"
        phase_name = "implementation"
        next_phase = "done"

    while True:
        while state["iteration"] < state[cycles_key]:
            it = state["iteration"]
            print(phase_header(f"Phase {phase_name} — iteration {it + 1}/{state[cycles_key]}"))

            # --- developer ---
            context = build_context(agent_dir, state, save)
            dev_map = {
                "TASK": state["task"],
                "LOG": context,
                "ANSWERS": read_text(paths["answers"]),
                review_key: read_text(review_path),
                "PRIOR_RUN_NOTE": prior_run_note(agent_dir),
            }
            print(dim_e(f"→ Developer ({phase_name})..."), file=sys.stderr)
            text, stop = run_step(state["developer"],
                                  render(load_prompt(dev_prompt), dev_map),
                                  True, state["_project_root"],
                                  f"{phase_name}: developer",
                                  agent_dir, kind, it, "developer")
            if stop:
                return "stop"
            append_log(agent_dir, kind, it, "developer", "done", text)

            # --- reviewer ---
            context = build_context(agent_dir, state, save)
            rev_map = {
                "TASK": state["task"],
                "LOG": context,
                "ANSWERS": read_text(paths["answers"]),
            }
            print(dim_e(f"→ Reviewer ({phase_name})..."), file=sys.stderr)
            text, stop = run_step(state["reviewer"],
                                  render(load_prompt(rev_prompt), rev_map),
                                  True, state["_project_root"],
                                  f"{phase_name}: reviewer",
                                  agent_dir, kind, it, "reviewer")
            if stop:
                return "stop"

            verdict = parse_verdict(read_text(review_path))
            status = verdict
            if verdict == "INVALID":
                status = "CHANGES (verdict not recognized)"
                verdict = "CHANGES"
            append_log(agent_dir, kind, it, "reviewer", status, text)

            state["last_verdict"] = verdict
            state["iteration"] = it + 1
            save()

            if verdict == "APPROVED":
                print("\n" + green(f"✓ Phase \"{phase_name}\" completed successfully: APPROVED (reviewer approved)"))
                state["phase"] = next_phase
                state["iteration"] = 0
                save()
                return next_phase
            else:
                remaining = state[cycles_key] - it - 1
                if remaining > 0:
                    print("\n" + yellow(f"✗ Reviewer requested changes (CHANGES). Running automatic revision (attempts remaining: {remaining})."))
                else:
                    print("\n" + yellow("✗ Reviewer requested changes (CHANGES). This was the last attempt in the current limit."))

        # limit exhausted
        action, n = pause_menu(phase_name, state[cycles_key])
        if action == "continue":
            state[cycles_key] += n
            save()
            append_log(agent_dir, kind, state["iteration"], "system",
                       "extend", f"Limit for \"{phase_name}\" extended by {n}.")
            continue
        return "stop"


# --- _agent/ lifecycle ------------------------------------------------------

def has_prior_run(agent_dir):
    # Any working artifact = there was a previous run. Important to include answers.md
    # and state.json: Phase 0 creates them before spec.md/log.md appear, and an
    # interruption at that stage must not silently overwrite state (resume contract).
    p = agent_paths(agent_dir)
    return any(os.path.exists(p[k])
               for k in ("spec", "log", "answers", "state"))


def archive_agent(agent_dir):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(agent_dir, "archive", ts)
    os.makedirs(dest, exist_ok=True)
    for name in os.listdir(agent_dir):
        if name in ("archive", ".lock"):
            continue
        shutil.move(os.path.join(agent_dir, name), os.path.join(dest, name))
    print(dim(f"Previous run moved to {dest}"))


def clear_agent(agent_dir):
    for name in os.listdir(agent_dir):
        if name in ("archive", ".lock"):
            continue
        path = os.path.join(agent_dir, name)
        if os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            os.remove(path)
    print(dim("_agent/ working files cleared."))


# --- Configuration (developer/reviewer/limits) -----------------------------

def setup_state(state, args, models):
    state["developer"] = choose_agent("developer", models)
    state["reviewer"] = choose_agent("reviewer", models)
    state["spec_cycles"] = (args.spec_cycles if args.spec_cycles
                            else ask_int(
                                bold("Phase 1 — spec writing.") + "\n"
                                "How many attempts to give the developer? "
                                "If reviewer does not approve — stop.",
                                DEFAULT_SPEC_CYCLES))
    state["impl_cycles"] = (args.impl_cycles if args.impl_cycles
                            else ask_int(
                                bold("Phase 2 — implementation.") + "\n"
                                "How many attempts to give the developer? "
                                "If reviewer does not approve — stop.",
                                DEFAULT_IMPL_CYCLES))


# --- arc --test ------------------------------------------------------------

def _run_test(models, project_root):
    """Select models to test and send each a test prompt."""
    print(bold("Test mode — checking model availability.") + "\n")
    options = [(f"{m['label']}  ({m['cli']} / {m['id']})", m) for m in models]
    print(dim("Select models to test (one at a time; empty input to finish):"))
    for i, (label, _) in enumerate(options, 1):
        print(f"  {dim(str(i) + '.')} {label}")
    selected = []
    while True:
        raw = input("> ").strip()
        if raw == "":
            break
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            m = options[int(raw) - 1][1]
            if m not in selected:
                selected.append(m)
                print(green(f"  + added: {m['label']}"))
        else:
            print(dim(f"  Enter a number from 1 to {len(options)} or press Enter to finish."))
    if not selected:
        print(yellow("No models selected."))
        return
    prompt = "Reply with exactly one word: hello"
    print()
    passed = 0
    for m in selected:
        label = f"{m['label']} ({m['cli']})"
        print(f"Test {bold(label)} ...", end=" ", flush=True)
        ok, text, _ = run_agent(m, prompt, False, project_root)
        if ok:
            print(green("✓ OK") + f"  response: \"{text[:60]}\"")
            passed += 1
        else:
            print(red("✗ FAIL") + "  — no response or error")
    result_color = green if passed == len(selected) else (red if passed == 0 else yellow)
    print("\n" + result_color(f"Result: {passed}/{len(selected)} passed."))


# --- main ------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog="arc",
        description="CLI for loop engineering (two-phase agentic loop).",
    )
    parser.add_argument("task", nargs="?", help="task description")
    parser.add_argument("--spec-cycles", type=positive_int, default=None,
                        help="number of spec phase iterations (positive integer)")
    parser.add_argument("--impl-cycles", type=positive_int, default=None,
                        help="number of implementation phase iterations (positive integer)")
    parser.add_argument("--test", action="store_true",
                        help="check availability of selected models and exit")
    args = parser.parse_args()

    project_root = os.getcwd()
    agent_dir = os.path.join(project_root, "_agent")

    models = parse_models()

    if args.test:
        atexit.register(cleanup_codex_home)  # needed if test touches codex
        _run_test(models, project_root)
        return

    os.makedirs(agent_dir, exist_ok=True)
    atexit.register(release_lock)
    atexit.register(cleanup_codex_home)
    acquire_lock(agent_dir)

    state = None
    save = None

    if has_prior_run(agent_dir):
        action = ask_choice(
            bold("\nPrevious run artifacts found in project (_agent/).") +
            "\nWhat to do?",
            [("Continue with existing files", "continue"),
             ("Archive previous run and start fresh", "archive"),
             ("Clear _agent/ and start fresh", "clear")],
        )
        if action == "continue":
            state = load_state(agent_dir, project_root)
            if state is None or state.get("phase") == "done":
                if state is None:
                    print(yellow("state.json is missing or corrupted — "
                                 "parameters need to be selected again."))
                else:
                    print(dim("Previous run is complete. "
                              "Select settings for a new run "
                              "(existing files will remain as context)."))
                # Remove old review files: they contain feedback from the previous
                # run and would give false input to the new cycle.
                # spec.md, log.md, log_summary.md are kept as context.
                for key in ("spec_review", "impl_review"):
                    p = agent_paths(agent_dir)[key]
                    try:
                        os.remove(p)
                    except FileNotFoundError:
                        pass
                state = new_state(project_root)
                save = make_saver(agent_dir, state)
                state["task"] = args.task or ask_line(bold("Describe the task:") + "\n> ").strip()
                setup_state(state, args, models)
                # if spec.md exists → start from spec phase, otherwise from Phase 0
                state["phase"] = ("spec"
                                  if os.path.exists(agent_paths(agent_dir)["spec"])
                                  else "phase0")
                save()
            else:
                save = make_saver(agent_dir, state)
                if args.task:
                    state["task"] = args.task
                print(bold(f"Resuming from phase \"{state['phase']}\", "
                           f"iteration {state['iteration']}."))
                print(dim("Select models to resume:"))
                setup_state(state, args, models)
                save()
        elif action == "archive":
            archive_agent(agent_dir)
        elif action == "clear":
            clear_agent(agent_dir)

    if state is None:
        state = new_state(project_root)
        save = make_saver(agent_dir, state)
        if not args.task:
            die("task description not provided")
        state["task"] = args.task
        setup_state(state, args, models)
        save()

    # --- main phase loop ---
    while True:
        phase = state["phase"]
        if phase == "phase0":
            if not phase0(agent_dir, state, save):
                print("\n" + yellow("Stopped."))
                return
        elif phase == "spec":
            if review_loop(agent_dir, state, save, "spec") == "stop":
                print("\n" + yellow("Stopped."))
                return
        elif phase == "impl":
            if review_loop(agent_dir, state, save, "impl") == "stop":
                print("\n" + yellow("Stopped."))
                return
        elif phase == "done":
            print("\n" + green("✓ Work accepted — spec and implementation approved by reviewer."))
            print(bold("Creating commit and pushing..."))
            git_commit_and_push(agent_dir, state, state["_project_root"])
            return
        else:
            die(f"unknown phase in state.json: {phase}")


def _handle_sighup(signum, frame):
    raise KeyboardInterrupt

if __name__ == "__main__":
    signal.signal(signal.SIGHUP, _handle_sighup)
    try:
        main()
    except KeyboardInterrupt:
        print("\n" + yellow("Interrupted by user."))
        sys.exit(130)
