"""Unit tests for arc — orchestrator shared code (parse_verdict, parse_models,
render, state, lock, archive/clear, has_prior_run, prior_run_note,
summary logic, E2E with mock agent, pause branch).

All tests mock run_agent and make no real CLI calls.
No CLI-specific differences — only shared code paths are tested.
"""

import json
import os
import tempfile
import shutil
import sys
from unittest.mock import patch, MagicMock

import pytest

# Add project root to sys.path to import arc without extension
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
d = SourceFileLoader("arc", os.path.join(project_dir, "arc")).load_module()
sys.modules["arc"] = d


# --- Fixtures ---------------------------------------------------------------

@pytest.fixture
def agent_dir(tmp_path):
    """Create a temporary _agent/ with basic artifacts."""
    ad = tmp_path / "_agent"
    ad.mkdir()
    return str(ad)


@pytest.fixture
def project_root(tmp_path):
    """Project root for tests."""
    return str(tmp_path)


@pytest.fixture
def clean_state():
    """Reset arc global state before/after test."""
    old_lock = d._LOCK_PATH
    old_codex = d._CODEX_HOME
    d._LOCK_PATH = None
    d._CODEX_HOME = None
    yield
    d._LOCK_PATH = old_lock
    d._CODEX_HOME = old_codex


# --- Step 2: parse_verdict --------------------------------------------------

class TestParseVerdict:
    def test_approved_last_line(self):
        assert d.parse_verdict("some text\nAPPROVED") == "APPROVED"

    def test_changes_last_line(self):
        assert d.parse_verdict("some text\nCHANGES") == "CHANGES"

    def test_changes_text_approved_last(self):
        # CHANGES in body, APPROVED on last line → APPROVED
        # Rule: last non-empty line checked first; if it has APPROVED → APPROVED.
        result = d.parse_verdict("CHANGES in text\nAPPROVED")
        assert result == "APPROVED"

    def test_empty_text(self):
        assert d.parse_verdict("") == "INVALID"

    def test_no_tokens(self):
        assert d.parse_verdict("plain text without keywords") == "INVALID"

    def test_changes_case_insensitive(self):
        assert d.parse_verdict("text\nchanges") == "CHANGES"

    def test_approved_case_insensitive(self):
        assert d.parse_verdict("text\napproved") == "APPROVED"

    def test_approved_inline_last_line(self):
        # APPROVED in the middle of the last line
        assert d.parse_verdict("text\nVerdict: APPROVED on review") == "APPROVED"

    def test_whitespace_only(self):
        assert d.parse_verdict("   \n  \n  ") == "INVALID"

    def test_single_line_approved(self):
        assert d.parse_verdict("APPROVED") == "APPROVED"

    def test_single_line_changes(self):
        assert d.parse_verdict("CHANGES") == "CHANGES"


# --- Step 3: parse_models ---------------------------------------------------

class TestParseModels:
    @pytest.fixture
    def models_file(self, tmp_path, monkeypatch):
        """Create models.md with four sections and patch MODELS_FILE."""
        content = """# Models

<!-- models:claude:start -->
claude-opus-4-8
claude-sonnet-4-6 | Sonnet
<!-- models:claude:end -->

<!-- models:codex:start -->
gpt-5.5
(hidden model)
<!-- models:codex:end -->

<!-- models:mimo:start -->
mimo/mimo-auto | MiMo Auto
<!-- models:mimo:end -->

<!-- models:agy:start -->
Gemini 3.5 Flash (Medium)
<!-- models:agy:end -->
"""
        path = tmp_path / "models.md"
        path.write_text(content, encoding="utf-8")
        monkeypatch.setattr(d, "MODELS_FILE", str(path))
        return path

    def test_four_clis(self, models_file):
        models = d.parse_models()
        clis = {m["cli"] for m in models}
        assert clis == {"claude", "codex", "mimo", "agy"}

    def test_hidden_line_skipped(self, models_file):
        models = d.parse_models()
        labels = [m["label"] for m in models]
        # (hidden model) — ID in parentheses, skipped
        assert "hidden model" not in labels

    def test_label_fallback_to_id(self, models_file):
        models = d.parse_models()
        opus = next(m for m in models if m["id"] == "claude-opus-4-8")
        assert opus["label"] == "claude-opus-4-8"

    def test_label_from_pipe(self, models_file):
        models = d.parse_models()
        sonnet = next(m for m in models if m["id"] == "claude-sonnet-4-6")
        assert sonnet["label"] == "Sonnet"

    def test_empty_models_file(self, tmp_path, monkeypatch, capsys):
        path = tmp_path / "models.md"
        path.write_text("", encoding="utf-8")
        monkeypatch.setattr(d, "MODELS_FILE", str(path))
        with pytest.raises(SystemExit):
            d.parse_models()

    def test_no_valid_models(self, tmp_path, monkeypatch):
        content = """<!-- models:claude:start -->
# comments only

<!-- models:claude:end -->
"""
        path = tmp_path / "models.md"
        path.write_text(content, encoding="utf-8")
        monkeypatch.setattr(d, "MODELS_FILE", str(path))
        with pytest.raises(SystemExit):
            d.parse_models()


# --- Step 4: render ---------------------------------------------------------

class TestRender:
    def test_all_placeholders_replaced(self):
        template = "Hello, {{NAME}}! Your role: {{ROLE}}."
        result = d.render(template, {"NAME": "Alice", "ROLE": "developer"})
        assert result == "Hello, Alice! Your role: developer."

    def test_unmatched_placeholder_stays(self):
        template = "Hello, {{NAME}}! Task: {{TASK}}."
        result = d.render(template, {"NAME": "Bob"})
        assert result == "Hello, Bob! Task: {{TASK}}."

    def test_no_placeholders(self):
        assert d.render("plain text", {}) == "plain text"

    def test_empty_template(self):
        assert d.render("", {"KEY": "val"}) == ""

    def test_multiple_same_placeholder(self):
        template = "{{X}} and {{X}}"
        assert d.render(template, {"X": "yes"}) == "yes and yes"


# --- Step 5: state save/load ------------------------------------------------

class TestState:
    def test_project_root_not_in_file(self, agent_dir, project_root):
        state = d.new_state(project_root)
        save = d.make_saver(agent_dir, state)
        save()
        with open(os.path.join(agent_dir, "state.json"), "r") as f:
            data = json.load(f)
        assert "_project_root" not in data

    def test_roundtrip(self, agent_dir, project_root):
        state = d.new_state(project_root)
        state["phase"] = "spec"
        state["iteration"] = 2
        state["task"] = "test task"
        save = d.make_saver(agent_dir, state)
        save()
        loaded = d.load_state(agent_dir, project_root)
        assert loaded["phase"] == "spec"
        assert loaded["iteration"] == 2
        assert loaded["task"] == "test task"
        assert loaded["_project_root"] == project_root

    def test_setdefault_for_missing_fields(self, agent_dir, project_root):
        # Write state without summarized_count
        data = {"phase": "spec", "iteration": 0}
        with open(os.path.join(agent_dir, "state.json"), "w") as f:
            json.dump(data, f)
        loaded = d.load_state(agent_dir, project_root)
        assert loaded["summarized_count"] == 0

    def test_missing_state_file(self, agent_dir, project_root):
        loaded = d.load_state(agent_dir, project_root)
        assert loaded is None

    def test_corrupted_state_file(self, agent_dir, project_root):
        with open(os.path.join(agent_dir, "state.json"), "w") as f:
            f.write("{invalid json")
        loaded = d.load_state(agent_dir, project_root)
        assert loaded is None


# --- Step 6: lock -----------------------------------------------------------

class TestLock:
    def test_acquire_and_release(self, agent_dir, clean_state):
        d.acquire_lock(agent_dir)
        lock_path = os.path.join(agent_dir, ".lock")
        assert os.path.exists(lock_path)
        assert d._LOCK_PATH == lock_path
        d.release_lock()
        assert not os.path.exists(lock_path)
        assert d._LOCK_PATH is None

    def test_stale_lock_released(self, agent_dir, clean_state):
        # Write a dead PID
        lock_path = os.path.join(agent_dir, ".lock")
        with open(lock_path, "w") as f:
            f.write("999999999")  # guaranteed non-existent PID
        # acquire_lock should take over the stale lock (PID is dead)
        d.acquire_lock(agent_dir)
        assert os.path.exists(lock_path)
        assert d._LOCK_PATH == lock_path
        d.release_lock()

    def test_double_acquire_blocks(self, agent_dir, clean_state, monkeypatch):
        # First acquire
        d.acquire_lock(agent_dir)
        # Second acquire with mocked ask_choice (select "stop")
        monkeypatch.setattr(d, "ask_choice", lambda title, options: "stop")
        with pytest.raises(SystemExit):
            d.acquire_lock(agent_dir)
        d.release_lock()


# --- Step 7: archive/clear --------------------------------------------------

class TestArchiveClear:
    def test_archive_preserves_lock_and_archive_dir(self, agent_dir):
        os.makedirs(os.path.join(agent_dir, "archive"), exist_ok=True)
        lock_path = os.path.join(agent_dir, ".lock")
        with open(lock_path, "w") as f:
            f.write(str(os.getpid()))
        spec_path = os.path.join(agent_dir, "spec.md")
        with open(spec_path, "w") as f:
            f.write("test")
        d.archive_agent(agent_dir)
        # spec.md should have been moved to archive/
        assert not os.path.exists(spec_path)
        assert os.path.exists(lock_path)
        assert os.path.isdir(os.path.join(agent_dir, "archive"))
        d.release_lock()

    def test_clear_preserves_lock_and_archive_dir(self, agent_dir):
        os.makedirs(os.path.join(agent_dir, "archive"), exist_ok=True)
        lock_path = os.path.join(agent_dir, ".lock")
        with open(lock_path, "w") as f:
            f.write(str(os.getpid()))
        spec_path = os.path.join(agent_dir, "spec.md")
        with open(spec_path, "w") as f:
            f.write("test")
        d.clear_agent(agent_dir)
        assert not os.path.exists(spec_path)
        assert os.path.exists(lock_path)
        assert os.path.isdir(os.path.join(agent_dir, "archive"))
        d.release_lock()


# --- Step 8: has_prior_run / prior_run_note ---------------------------------

class TestHasPriorRun:
    def test_empty_agent_dir(self, agent_dir):
        assert d.has_prior_run(agent_dir) is False

    def test_answers_md_present(self, agent_dir):
        with open(os.path.join(agent_dir, "answers.md"), "w") as f:
            f.write("answers")
        assert d.has_prior_run(agent_dir) is True

    def test_state_json_present(self, agent_dir):
        with open(os.path.join(agent_dir, "state.json"), "w") as f:
            json.dump({"phase": "spec"}, f)
        assert d.has_prior_run(agent_dir) is True

    def test_spec_only(self, agent_dir):
        with open(os.path.join(agent_dir, "spec.md"), "w") as f:
            f.write("spec")
        assert d.has_prior_run(agent_dir) is True

    def test_log_only(self, agent_dir):
        with open(os.path.join(agent_dir, "log.md"), "w") as f:
            f.write("log")
        assert d.has_prior_run(agent_dir) is True

    def test_spec_log_no_answers_no_state(self, agent_dir):
        # spec/log present but no answers.md/state.json → True
        with open(os.path.join(agent_dir, "spec.md"), "w") as f:
            f.write("spec")
        with open(os.path.join(agent_dir, "log.md"), "w") as f:
            f.write("log")
        assert d.has_prior_run(agent_dir) is True


class TestPriorRunNote:
    def test_with_log(self, agent_dir):
        with open(os.path.join(agent_dir, "log.md"), "w") as f:
            f.write("log")
        note = d.prior_run_note(agent_dir)
        assert note != ""
        assert "continuation" in note.lower() or "⚠" in note

    def test_with_log_summary(self, agent_dir):
        with open(os.path.join(agent_dir, "log_summary.md"), "w") as f:
            f.write("summary")
        note = d.prior_run_note(agent_dir)
        assert note != ""

    def test_empty_agent_dir(self, agent_dir):
        note = d.prior_run_note(agent_dir)
        assert note == ""


# --- Step 9: summary logic (maybe_update_summary) --------------------------

class TestMaybeUpdateSummary:
    def test_within_window_no_summary(self, agent_dir, project_root, monkeypatch):
        # Create 3 entries (<= LOG_WINDOW=5), summarized_count=0
        for i in range(3):
            d.append_log(agent_dir, "spec", i, "developer", "done", f"entry {i}")
        state = d.new_state(project_root)
        state["summarized_count"] = 0
        save = d.make_saver(agent_dir, state)

        # run_agent must not be called
        with patch.object(d, "run_agent") as mock_run:
            d.maybe_update_summary(agent_dir, state, save)
            mock_run.assert_not_called()
        assert state["summarized_count"] == 0

    def test_exceeds_window_triggers_summary(self, agent_dir, project_root, monkeypatch):
        # Create 7 entries (> LOG_WINDOW=5), summarized_count=0
        for i in range(7):
            d.append_log(agent_dir, "spec", i, "developer", "done", f"entry {i}")
        state = d.new_state(project_root)
        state["developer"] = {"cli": "claude", "id": "claude-sonnet-4-6"}
        state["summarized_count"] = 0
        save = d.make_saver(agent_dir, state)

        with patch.object(d, "run_agent", return_value=(True, "summary", False)) as mock_run:
            d.maybe_update_summary(agent_dir, state, save)
            mock_run.assert_called_once()
            # summarized_count should advance: 7 entries, LOG_WINDOW=5 → target=2
            assert state["summarized_count"] == 2

    def test_summary_written_to_file(self, agent_dir, project_root):
        for i in range(7):
            d.append_log(agent_dir, "spec", i, "developer", "done", f"entry {i}")
        state = d.new_state(project_root)
        state["developer"] = {"cli": "claude", "id": "claude-sonnet-4-6"}
        state["summarized_count"] = 0
        save = d.make_saver(agent_dir, state)

        with patch.object(d, "run_agent", return_value=(True, "new summary", False)):
            d.maybe_update_summary(agent_dir, state, save)
        summary_path = os.path.join(agent_dir, "log_summary.md")
        assert os.path.exists(summary_path)
        with open(summary_path) as f:
            assert "new summary" in f.read()

    def test_fallback_on_agent_error(self, agent_dir, project_root):
        # run_agent returns error — fallback appends raw entries
        for i in range(7):
            d.append_log(agent_dir, "spec", i, "developer", "done", f"entry {i}")
        state = d.new_state(project_root)
        state["developer"] = {"cli": "claude", "id": "claude-sonnet-4-6"}
        state["summarized_count"] = 0
        save = d.make_saver(agent_dir, state)

        with patch.object(d, "run_agent", return_value=(False, "", False)):
            d.maybe_update_summary(agent_dir, state, save)
        summary_path = os.path.join(agent_dir, "log_summary.md")
        with open(summary_path) as f:
            content = f.read()
        # Fallback: raw entries appended
        assert "entry 0" in content or "entry 1" in content


# --- Step 10: E2E test with mock agent --------------------------------------

class TestE2E:
    def _make_mock_agent(self, agent_dir):
        """Create a mock that distinguishes phases by prompt filename."""
        call_count = [0]

        def fake_run_agent(agent, prompt, writes, project_root, timeout=None):
            call_count[0] += 1
            # Phase 0: developer explores project
            if "Phase 0" in prompt or "explore" in prompt.lower():
                return True, "NO QUESTIONS", False
            # Reviewer: spec_review.md → APPROVED
            if "spec_review.md" in prompt:
                review_path = os.path.join(agent_dir, "spec_review.md")
                d.write_text(review_path, "APPROVED")
                return True, "APPROVED", False
            # Reviewer: impl_review.md → APPROVED
            if "impl_review.md" in prompt:
                review_path = os.path.join(agent_dir, "impl_review.md")
                d.write_text(review_path, "APPROVED")
                return True, "APPROVED", False
            # Developer: arbitrary text
            return True, "done", False

        return fake_run_agent

    def test_full_pass(self, agent_dir, project_root, monkeypatch):
        monkeypatch.setattr(d, "run_agent", self._make_mock_agent(agent_dir))

        state = d.new_state(project_root)
        state["task"] = "test task"
        state["developer"] = {"cli": "claude", "id": "claude-sonnet-4-6"}
        state["reviewer"] = {"cli": "claude", "id": "claude-sonnet-4-6"}
        save = d.make_saver(agent_dir, state)

        # Phase 0
        result = d.phase0(agent_dir, state, save)
        assert result is True
        assert state["phase"] == "spec"

        # Spec review loop
        result = d.review_loop(agent_dir, state, save, "spec")
        assert result == "impl"
        assert state["phase"] == "impl"

        # Impl review loop
        result = d.review_loop(agent_dir, state, save, "impl")
        assert result == "done"
        assert state["phase"] == "done"

    def test_agent_error_stop(self, agent_dir, project_root, monkeypatch):
        """Mock returns error (ok=False), user selects stop."""
        error_calls = [0]

        def error_agent(agent, prompt, writes, project_root, timeout=None):
            error_calls[0] += 1
            if error_calls[0] == 1:
                return False, "", False
            return True, "done", False

        monkeypatch.setattr(d, "run_agent", error_agent)
        monkeypatch.setattr(d, "ask_choice", lambda title, options: "stop")

        state = d.new_state(project_root)
        state["task"] = "test"
        state["developer"] = {"cli": "claude", "id": "test"}
        state["reviewer"] = {"cli": "claude", "id": "test"}
        save = d.make_saver(agent_dir, state)

        # run_step on error calls ask_choice; "stop" returns ("", True)
        text, stop = d.run_step(
            state["developer"], "prompt", False, project_root,
            "test", agent_dir, "spec", 0, "developer"
        )
        assert stop is True
        assert text == ""

        # Verify error was logged
        log_entries = d.parse_entries(agent_dir)
        assert any("error" in e.lower() for e in log_entries)


# --- Step 11: pause branch --------------------------------------------------

class TestPauseMenu:
    def test_continue_extends_limit(self, monkeypatch, capsys):
        answers = iter(["continue", "10"])
        monkeypatch.setattr(d, "ask_choice", lambda title, options: next(answers))
        monkeypatch.setattr(d, "ask_int", lambda prompt, default: 10)
        result = d.pause_menu("spec", 3)
        assert result == ("continue", 10)

    def test_stop_ends(self, monkeypatch):
        monkeypatch.setattr(d, "ask_choice", lambda title, options: "stop")
        result = d.pause_menu("spec", 3)
        assert result == ("stop", 0)

    def test_review_loop_stop_on_limit(self, agent_dir, project_root, monkeypatch):
        """On limit exhaustion and stop selection, review_loop returns 'stop'."""
        def chg_agent(agent, prompt, writes, project_root, timeout=None):
            if "spec_review.md" in prompt:
                review_path = os.path.join(agent_dir, "spec_review.md")
                d.write_text(review_path, "CHANGES")
                return True, "CHANGES", False
            return True, "text", False

        monkeypatch.setattr(d, "run_agent", chg_agent)
        monkeypatch.setattr(d, "ask_choice", lambda title, options: "stop")

        state = d.new_state(project_root)
        state["task"] = "test"
        state["developer"] = {"cli": "claude", "id": "test"}
        state["reviewer"] = {"cli": "claude", "id": "test"}
        state["spec_cycles"] = 1  # limit = 1 iteration
        save = d.make_saver(agent_dir, state)

        result = d.review_loop(agent_dir, state, save, "spec")
        assert result == "stop"

    def test_review_loop_continue_extends(self, agent_dir, project_root, monkeypatch):
        """On limit exhaustion and 'continue' selection, limit is increased."""
        def chg_agent(agent, prompt, writes, project_root, timeout=None):
            if "spec_review.md" in prompt:
                review_path = os.path.join(agent_dir, "spec_review.md")
                d.write_text(review_path, "CHANGES")
                return True, "CHANGES", False
            return True, "text", False

        call_count = [0]
        def mock_choice(title, options):
            call_count[0] += 1
            if call_count[0] <= 1:
                return "continue"
            return "stop"
        monkeypatch.setattr(d, "run_agent", chg_agent)
        monkeypatch.setattr(d, "ask_choice", mock_choice)
        monkeypatch.setattr(d, "ask_int", lambda prompt, default: 2)

        state = d.new_state(project_root)
        state["task"] = "test"
        state["developer"] = {"cli": "claude", "id": "test"}
        state["reviewer"] = {"cli": "claude", "id": "test"}
        state["spec_cycles"] = 1
        save = d.make_saver(agent_dir, state)

        result = d.review_loop(agent_dir, state, save, "spec")
        # After extension: limit 1+2=3, second iteration → CHANGES, then limit again
        # → ask_choice returns "stop" → result = "stop"
        assert result == "stop"
        assert state["spec_cycles"] == 3


# --- Step 12: placeholder coverage check ------------------------------------

class TestPlaceholderCoverage:
    def test_all_placeholders_covered(self):
        """All placeholders in prompts/ must be present in the arc mapping."""
        import re
        import glob

        prov = {
            "explore": {"TASK", "LOG"},
            "spec_write": {"TASK", "LOG", "ANSWERS", "SPEC_REVIEW", "PRIOR_RUN_NOTE"},
            "impl": {"TASK", "LOG", "ANSWERS", "IMPL_REVIEW", "PRIOR_RUN_NOTE"},
            "spec_review": {"TASK", "LOG", "ANSWERS", "PREV_REVIEW"},
            "impl_review": {"TASK", "LOG", "ANSWERS", "PREV_REVIEW"},
            "log_summary": {"PREV_SUMMARY", "NEW_ENTRIES"},
        }

        prompts_dir = os.path.join(d.TOOL_ROOT, "prompts")
        for f in glob.glob(os.path.join(prompts_dir, "*.md")):
            name = os.path.basename(f)[:-3]
            with open(f, encoding="utf-8") as fh:
                content = fh.read()
            ph = set(re.findall(r"\{\{([A-Z_]+)\}\}", content))
            if name in prov:
                missing = ph - prov[name]
                assert not missing, f"Placeholders {missing} in {name}.md are not covered by the mapping"


# --- Helpers: read_text, write_text, now_iso --------------------------------

class TestHelpers:
    def test_read_text_existing(self, tmp_path):
        p = tmp_path / "test.txt"
        p.write_text("hello", encoding="utf-8")
        assert d.read_text(str(p)) == "hello"

    def test_read_text_missing(self, tmp_path):
        assert d.read_text(str(tmp_path / "nope.txt")) == ""

    def test_write_text_creates_dirs(self, tmp_path):
        p = tmp_path / "a" / "b" / "c.txt"
        d.write_text(str(p), "content")
        assert p.read_text(encoding="utf-8") == "content"

    def test_now_iso_format(self):
        result = d.now_iso()
        # Format: YYYY-MM-DDTHH:MM:SS
        assert "T" in result
        parts = result.split("T")
        assert len(parts) == 2


# --- agent_paths -----------------------------------------------------------

class TestAgentPaths:
    def test_all_keys_present(self):
        paths = d.agent_paths("/tmp/test")
        expected = {"spec", "answers", "spec_review", "impl_review",
                    "log", "log_summary", "state"}
        assert set(paths.keys()) == expected
        assert all(isinstance(v, str) for v in paths.values())


# --- summary_agent ---------------------------------------------------------

class TestSummaryAgent:
    def test_claude_uses_cheap_model(self):
        state = {"developer": {"cli": "claude", "id": "claude-opus-4-8"}}
        agent = d.summary_agent(state)
        assert agent["cli"] == "claude"
        assert agent["id"] == d.CHEAP_CLAUDE_MODEL

    def test_mimo_uses_mimo_auto(self):
        state = {"developer": {"cli": "mimo", "id": "mimo/mimo-auto"}}
        agent = d.summary_agent(state)
        assert agent["cli"] == "mimo"
        assert agent["id"] == "mimo/mimo-auto"

    def test_codex_uses_none_id(self):
        state = {"developer": {"cli": "codex", "id": "gpt-5.5"}}
        agent = d.summary_agent(state)
        assert agent["cli"] == "codex"
        assert agent["id"] is None

    def test_agy_uses_flash_low(self):
        state = {"developer": {"cli": "agy", "id": "Gemini 3.5 Flash (Medium)"}}
        agent = d.summary_agent(state)
        assert agent["cli"] == "agy"
        assert agent["id"] == "Gemini 3.5 Flash (Low)"


# --- append_log / parse_entries ---------------------------------------------

class TestLog:
    def test_append_and_parse(self, agent_dir):
        d.append_log(agent_dir, "spec", 0, "developer", "done", "iteration text")
        entries = d.parse_entries(agent_dir)
        assert len(entries) == 1
        assert "phase=spec" in entries[0]
        assert "iter=0" in entries[0]
        assert "iteration text" in entries[0]

    def test_multiple_entries(self, agent_dir):
        for i in range(3):
            d.append_log(agent_dir, "spec", i, "developer", "done", f"entry {i}")
        entries = d.parse_entries(agent_dir)
        assert len(entries) == 3

    def test_empty_log(self, agent_dir):
        entries = d.parse_entries(agent_dir)
        assert entries == []


# --- positive_int (argparse type) ------------------------------------------

class TestPositiveInt:
    def test_valid(self):
        assert d.positive_int("5") == 5

    def test_zero_rejected(self):
        with pytest.raises(Exception):
            d.positive_int("0")

    def test_negative_rejected(self):
        with pytest.raises(Exception):
            d.positive_int("-1")

    def test_non_integer_rejected(self):
        with pytest.raises(Exception):
            d.positive_int("abc")


# --- load_prompt & phase0 question streaming suppression -------------------

class TestLoadPrompt:
    def test_load_prompt_simple(self, tmp_path, monkeypatch):
        prompts_dir = tmp_path / "prompts"
        prompts_dir.mkdir()
        monkeypatch.setattr(d, "PROMPTS_DIR", str(prompts_dir))

        (prompts_dir / "simple.md").write_text("Hello World", encoding="utf-8")
        assert d.load_prompt("simple") == "Hello World"

    def test_load_prompt_with_include(self, tmp_path, monkeypatch):
        prompts_dir = tmp_path / "prompts"
        prompts_dir.mkdir()
        monkeypatch.setattr(d, "PROMPTS_DIR", str(prompts_dir))

        (prompts_dir / "parent.md").write_text("Prefix {{include:child}} Suffix", encoding="utf-8")
        (prompts_dir / "child.md").write_text("ChildContent", encoding="utf-8")

        assert d.load_prompt("parent") == "Prefix ChildContent Suffix"

    def test_load_prompt_recursive_include(self, tmp_path, monkeypatch):
        prompts_dir = tmp_path / "prompts"
        prompts_dir.mkdir()
        monkeypatch.setattr(d, "PROMPTS_DIR", str(prompts_dir))

        (prompts_dir / "a.md").write_text("A {{include:b}} A", encoding="utf-8")
        (prompts_dir / "b.md").write_text("B {{include:c}} B", encoding="utf-8")
        (prompts_dir / "c.md").write_text("C", encoding="utf-8")

        assert d.load_prompt("a") == "A B C B A"

    def test_load_prompt_missing_die(self, tmp_path, monkeypatch):
        prompts_dir = tmp_path / "prompts"
        prompts_dir.mkdir()
        monkeypatch.setattr(d, "PROMPTS_DIR", str(prompts_dir))

        with patch("arc.die") as mock_die:
            d.load_prompt("missing")
            mock_die.assert_called_once()
            args, _ = mock_die.call_args
            assert "prompt not found" in args[0]

    def test_load_prompt_empty_die(self, tmp_path, monkeypatch):
        prompts_dir = tmp_path / "prompts"
        prompts_dir.mkdir()
        monkeypatch.setattr(d, "PROMPTS_DIR", str(prompts_dir))

        (prompts_dir / "empty.md").write_text("   \n  ", encoding="utf-8")

        with patch("arc.die") as mock_die:
            d.load_prompt("empty")
            mock_die.assert_called_once()
            args, _ = mock_die.call_args
            assert "prompt not found" in args[0]


class TestPhase0Questions:
    def test_phase0_with_questions_streaming_cli(self, agent_dir, project_root, monkeypatch):
        state = d.new_state(project_root)
        state["task"] = "test"
        state["developer"] = {"cli": "claude", "id": "test"}
        state["reviewer"] = {"cli": "claude", "id": "test"}
        save = d.make_saver(agent_dir, state)

        monkeypatch.setattr(d, "run_agent", lambda *args, **kwargs: (True, "Question 1", False))
        monkeypatch.setattr(d, "ask_multiline", lambda prompt: "Answer 1")

        printed_texts = []
        original_print = print
        def mock_print(*args, **kwargs):
            printed_texts.append(args)

        monkeypatch.setattr("builtins.print", mock_print)

        result = d.phase0(agent_dir, state, save)
        assert result is True
        assert state["phase"] == "spec"

        printed_question = False
        for args in printed_texts:
            if len(args) > 0 and isinstance(args[0], str) and "Question 1" in args[0]:
                printed_question = True
        assert not printed_question

    def test_phase0_with_questions_non_streaming_cli(self, agent_dir, project_root, monkeypatch):
        state = d.new_state(project_root)
        state["task"] = "test"
        state["developer"] = {"cli": "codex", "id": "test"}
        state["reviewer"] = {"cli": "claude", "id": "test"}
        save = d.make_saver(agent_dir, state)

        monkeypatch.setattr(d, "run_agent", lambda *args, **kwargs: (True, "Question 1", False))
        monkeypatch.setattr(d, "ask_multiline", lambda prompt: "Answer 1")

        printed_texts = []
        def mock_print(*args, **kwargs):
            printed_texts.append(args)

        monkeypatch.setattr("builtins.print", mock_print)

        result = d.phase0(agent_dir, state, save)
        assert result is True
        assert state["phase"] == "spec"

        printed_question = False
        for args in printed_texts:
            if len(args) > 0 and isinstance(args[0], str) and "Question 1" in args[0]:
                printed_question = True
        assert printed_question
