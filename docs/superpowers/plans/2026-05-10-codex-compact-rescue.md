# Codex Compact Rescue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local CLI rescue layer that detects Codex remote compact failures, resumes the same original session with a smaller model, triggers a maintenance-only compaction turn, verifies `context_compacted`, and then leaves the user able to continue the original conversation normally.

**Architecture:** A Python standard-library CLI reads local Codex logs and session JSONL files, decides whether a failed compact event still needs rescue, then invokes `codex exec resume <thread_id> <maintenance-prompt>` with `gpt-5.4-mini` and `--disable goals`. The first release is conservative: dry-run by default, per-thread locking, cooldown, active-turn guard, and explicit success verification before marking a rescue complete.

**Tech Stack:** Python 3 standard library (`argparse`, `sqlite3`, `json`, `pathlib`, `subprocess`, `fcntl`, `tempfile`, `unittest`), local Codex CLI `0.128.0`, Codex session JSONL files under `~/.codex/sessions` and `~/.codex/archived_sessions`, optional macOS `launchd`.

---

## 1. Feasibility Analysis

### 1.1 Problem Evidence

Local evidence on this Mac shows repeated remote compact failures on `gpt-5.5`:

- Current CLI: `codex-cli 0.128.0`.
- Current config: `model = "gpt-5.5"`, `model_reasoning_effort = "xhigh"`, `[features].goals = true`, `[features.multi_agent_v2].enabled = true`.
- Compact failure target: `codex_core::compact_remote`.
- Error shape: `stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses/compact)`.
- Failure metrics seen locally: compact requests around `835826` to `978242` model-visible bytes and `162k` to `205k+` total tokens.
- Session files record successful compaction boundaries as JSONL event messages containing `context_compacted`.

Community evidence supports the same direction:

- OpenAI Codex issue [`#19400`](https://github.com/openai/codex/issues/19400) reports that remote compaction is broken on `gpt-5.5` while `gpt-5.4` is supported.
- Existing workaround projects such as [`codex-compact-proxy`](https://github.com/tiderzheng/codex-compact-proxy) rewrite only compact requests to a smaller model.

### 1.2 Candidate Approaches

| Approach | Summary | Fit For This User | Risk |
| --- | --- | --- | --- |
| A. Transparent compact proxy | Intercept `/responses/compact` and rewrite only compact model from `gpt-5.5` to `gpt-5.4` or `gpt-5.4-mini`. | Best UX if the network/provider path is fully controllable. | Medium-high on Codex Desktop because the app calls `chatgpt.com/backend-api/codex/responses/compact`; HTTPS interception or provider rebinding can be fragile. |
| B. CLI original-session rescue | Detect compact failure, run `codex exec resume <thread_id>` with smaller model, send maintenance-only prompt, then verify `context_compacted`. | Best first implementation because it preserves the same thread and uses supported CLI behavior. | Medium. It creates one visible maintenance turn and must avoid running while another turn is active. |
| C. Manual handoff summary | Generate a new summary and start a new thread. | Poor fit because the user wants the original conversation to continue like auto-compact. | Low implementation risk, high workflow cost. |

Selected approach: **B. CLI original-session rescue**.

### 1.3 Why CLI Original-Session Rescue Is Feasible

- `codex exec resume [SESSION_ID] [PROMPT]` is available locally and accepts session UUID or thread name.
- `-m/--model` allows per-run model override without changing the user's default `gpt-5.5`.
- `--disable goals` maps to `features.goals=false` for that maintenance run, reducing the chance that the rescue turn completes or mutates an active goal.
- `--skip-git-repo-check` allows rescue from `~/.codex` even when the original workspace is not a git repository.
- `--json` and `-o/--output-last-message` provide observable command output and a stable last-message file.
- The session JSONL success marker `context_compacted` is a concrete postcondition.

### 1.4 Compatibility With Goal Mode

This is compatible if the rescue turn is treated as infrastructure maintenance:

- Run with `--disable goals`.
- Use a prompt that explicitly forbids tool use, project work, and goal updates.
- Verify success from session history, not from goal state.
- Do not use Codex heartbeat automations for rescue because they attach to the same thread and can look like user workflow turns.

Maintenance prompt:

```text
[codex-compact-rescue] This is a maintenance turn, not task execution. Do not run tools. Do not update, complete, or create any goal. Do not continue project work. Reply only: compact-ok. If the system triggers automatic context compaction, wait for compaction to finish before replying.
```

### 1.5 Main Risks And Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Rescue collides with an active Desktop turn. | Corrupts workflow ordering or duplicates work. | Active-turn guard: skip if the session tail has `task_started` without a later terminal event. |
| Rescue loops on the same failure. | Wastes quota and adds visible turns. | State file tracks processed log ids, per-thread cooldown, and max attempts. |
| Log timestamp units are ambiguous. | Wrong "after failure" comparison. | Use monotonic log `id` for processing; use session JSONL event timestamps only for compact-boundary checks. |
| `codex exec resume` fails because session cannot be found. | No rescue. | Resolve session file first by searching `~/.codex/sessions` and `~/.codex/archived_sessions`; fail closed if missing. |
| Smaller model also fails compact. | Repeated failure. | Try at most two attempts: `gpt-5.4-mini medium`, then `gpt-5.4-mini low`; then mark `needs_manual_review`. |
| Maintenance turn changes goal state. | User workflow confusion. | `--disable goals` plus prompt contract plus no tool execution. |
| Desktop UI does not refresh immediately. | User sees old state until reopen/refresh. | Treat `context_compacted` in JSONL as source of truth; final runbook tells the user to reopen the same thread only if the UI lags. |

### 1.6 Acceptance Criteria

The rescue layer is acceptable when all criteria pass:

- Dry-run lists recent unresolved compact failures without mutating session files.
- It ignores failures already followed by a later `context_compacted` event when the failed turn id can be located in the session JSONL.
- It refuses to rescue a session that appears to have an active unfinished turn.
- It invokes `codex exec resume` only when `--execute` is provided.
- The command includes `-m gpt-5.4-mini`, `--disable goals`, `--skip-git-repo-check`, `--json`, and `-o`.
- A successful rescue is recorded only after a new `context_compacted` event appears in the target session JSONL.
- State survives repeated runs and prevents duplicate rescue for the same log id.
- The original session id/thread id remains the target; no new handoff session is created by the tool.

---

## 2. File Structure

Create:

- `$HOME/.codex/compact-rescue/codex_compact_rescue.py`
  - Main Python module and CLI entrypoint.
  - Owns SQLite querying, log parsing, session lookup, decision engine, lock handling, command construction, subprocess execution, and verification.

- `$HOME/.codex/bin/codex-compact-rescue`
  - Thin executable wrapper.
  - Imports and calls `main()` from `$HOME/.codex/compact-rescue/codex_compact_rescue.py`.

- `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
  - Unit tests using temporary SQLite databases and temporary session JSONL files.
  - Does not call the real Codex CLI.

Runtime-generated:

- `$HOME/.codex/compact-rescue/state.json`
  - Processed log ids, attempts, last rescue times, and final statuses.

- `$HOME/.codex/compact-rescue/rescue.log`
  - Append-only operational log for rescue decisions and command outcomes.

- `$HOME/.codex/compact-rescue/locks/<thread_id>.lock`
  - Per-thread lock files.

Optional after manual acceptance:

- `$HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist`
  - Runs the rescue tool periodically with `--once --execute`.

---

## 3. Implementation Plan

### Task 1: Build Parser And Data Model Tests

**Files:**

- Create: `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- Create later in Task 2: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Create the test directory**

Run:

```bash
mkdir -p $HOME/.codex/compact-rescue/tests
```

- [ ] **Step 2: Write failing parser tests**

Add this initial test file:

```python
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path.home() / ".codex" / "compact-rescue" / "codex_compact_rescue.py"
spec = importlib.util.spec_from_file_location("codex_compact_rescue", MODULE_PATH)
rescue = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = rescue
spec.loader.exec_module(rescue)


FAILURE_BODY = (
    'session_loop{thread_id=019df873-2bae-73b2-a4a4-150660c3c570}:'
    'submission_dispatch{otel.name="op.dispatch.compact"}:'
    'turn{otel.name="session_task.compact" thread.id=019df873-2bae-73b2-a4a4-150660c3c570 '
    'turn.id=019e10b2-39f4-7703-833d-94561519bc60 model=gpt-5.5}: '
    'remote compaction failed turn_id=019e10b2-39f4-7703-833d-94561519bc60 '
    'last_api_response_total_tokens=184680 '
    'all_history_items_model_visible_bytes=965865 '
    'estimated_tokens_of_items_added_since_last_successful_api_response=4372 '
    'estimated_bytes_of_items_added_since_last_successful_api_response=17485 '
    'model_context_window_tokens=Some(258400) '
    'failing_compaction_request_model_visible_bytes=978242 '
    'compact_error=stream disconnected before completion: error sending request for url '
    '(https://chatgpt.com/backend-api/codex/responses/compact)'
)


class ParserTests(unittest.TestCase):
    def test_parse_compact_failure_extracts_core_fields(self):
        event = rescue.parse_compact_failure_log(
            log_id=75122406,
            thread_id="019df873-2bae-73b2-a4a4-150660c3c570",
            body=FAILURE_BODY,
        )

        self.assertEqual(event.log_id, 75122406)
        self.assertEqual(event.thread_id, "019df873-2bae-73b2-a4a4-150660c3c570")
        self.assertEqual(event.turn_id, "019e10b2-39f4-7703-833d-94561519bc60")
        self.assertEqual(event.model, "gpt-5.5")
        self.assertEqual(event.last_api_response_total_tokens, 184680)
        self.assertEqual(event.failing_compaction_request_model_visible_bytes, 978242)
        self.assertIn("stream disconnected before completion", event.compact_error)

    def test_parse_compact_failure_rejects_non_failure_body(self):
        event = rescue.parse_compact_failure_log(
            log_id=1,
            thread_id="019df873-2bae-73b2-a4a4-150660c3c570",
            body="ordinary info log",
        )

        self.assertIsNone(event)
```

- [ ] **Step 3: Run tests and confirm the expected import failure**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
FileNotFoundError
```

### Task 2: Implement Parser And Data Model

**Files:**

- Create: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Add minimal module code**

Create `$HOME/.codex/compact-rescue/codex_compact_rescue.py` with:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import fcntl
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable


CODEX_HOME = Path.home() / ".codex"
DEFAULT_LOG_DB = CODEX_HOME / "logs_2.sqlite"
DEFAULT_STATE_DIR = CODEX_HOME / "compact-rescue"
DEFAULT_STATE_FILE = DEFAULT_STATE_DIR / "state.json"
DEFAULT_CODEX_BIN = "codex"
DEFAULT_MODEL = "gpt-5.4-mini"
DEFAULT_REASONING = "medium"
DEFAULT_COOLDOWN_SECONDS = 600
DEFAULT_MAX_ATTEMPTS = 2

MAINTENANCE_PROMPT = (
    "[codex-compact-rescue] This is a maintenance turn, not task execution. "
    "Do not run tools. Do not update, complete, or create any goal. "
    "Do not continue project work. Reply only: compact-ok. "
    "If the system triggers automatic context compaction, wait for compaction to finish before replying."
)


@dataclasses.dataclass(frozen=True)
class CompactFailureEvent:
    log_id: int
    thread_id: str
    turn_id: str | None
    model: str | None
    last_api_response_total_tokens: int | None
    failing_compaction_request_model_visible_bytes: int | None
    compact_error: str


def _extract_int(body: str, name: str) -> int | None:
    match = re.search(rf"{re.escape(name)}=(\d+)", body)
    return int(match.group(1)) if match else None


def parse_compact_failure_log(log_id: int, thread_id: str, body: str) -> CompactFailureEvent | None:
    if "remote compaction failed" not in body:
        return None

    turn_match = re.search(r"turn_id=([0-9a-f-]+)", body)
    model_match = re.search(r"\bmodel=([A-Za-z0-9_.-]+)", body)
    error_match = re.search(r"compact_error=(.*)$", body)

    return CompactFailureEvent(
        log_id=log_id,
        thread_id=thread_id,
        turn_id=turn_match.group(1) if turn_match else None,
        model=model_match.group(1) if model_match else None,
        last_api_response_total_tokens=_extract_int(body, "last_api_response_total_tokens"),
        failing_compaction_request_model_visible_bytes=_extract_int(
            body, "failing_compaction_request_model_visible_bytes"
        ),
        compact_error=error_match.group(1).strip() if error_match else "",
    )
```

- [ ] **Step 2: Run parser tests**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
OK
```

### Task 3: Add SQLite Query And Session Lookup

**Files:**

- Modify: `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- Modify: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Add failing tests for querying and session lookup**

Append to the test file:

```python
import json
import sqlite3


class StorageTests(unittest.TestCase):
    def test_load_recent_failures_reads_sqlite_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "logs.sqlite"
            conn = sqlite3.connect(db_path)
            conn.execute(
                "create table logs (id integer, level text, target text, thread_id text, feedback_log_body text)"
            )
            conn.execute(
                "insert into logs values (?, ?, ?, ?, ?)",
                (
                    10,
                    "ERROR",
                    "codex_core::compact_remote",
                    "019df873-2bae-73b2-a4a4-150660c3c570",
                    FAILURE_BODY,
                ),
            )
            conn.commit()
            conn.close()

            events = rescue.load_recent_compact_failures(db_path, since_id=0, limit=20)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].log_id, 10)
        self.assertEqual(events[0].thread_id, "019df873-2bae-73b2-a4a4-150660c3c570")

    def test_find_session_file_locates_matching_rollout(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions" / "2026" / "05" / "05"
            sessions.mkdir(parents=True)
            target = sessions / "rollout-2026-05-05T22-03-10-019df873-2bae-73b2-a4a4-150660c3c570.jsonl"
            target.write_text(
                json.dumps({"type": "session_meta", "payload": {"id": "019df873-2bae-73b2-a4a4-150660c3c570"}})
                + "\n",
                encoding="utf-8",
            )

            found = rescue.find_session_file(
                "019df873-2bae-73b2-a4a4-150660c3c570",
                search_roots=[tmp_path / "sessions"],
            )

        self.assertEqual(found, target)
```

- [ ] **Step 2: Run tests and confirm missing functions**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
AttributeError
```

- [ ] **Step 3: Implement SQLite query and session lookup**

Append to the module:

```python
def load_recent_compact_failures(db_path: Path, since_id: int = 0, limit: int = 50) -> list[CompactFailureEvent]:
    if not db_path.exists():
        return []

    query = """
        select id, thread_id, feedback_log_body
        from logs
        where id > ?
          and level = 'ERROR'
          and target = 'codex_core::compact_remote'
          and feedback_log_body like '%remote compaction failed%'
        order by id asc
        limit ?
    """

    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(query, (since_id, limit)).fetchall()
    finally:
        conn.close()

    events: list[CompactFailureEvent] = []
    for log_id, thread_id, body in rows:
        event = parse_compact_failure_log(int(log_id), str(thread_id), str(body))
        if event is not None:
            events.append(event)
    return events


def find_session_file(thread_id: str, search_roots: Iterable[Path] | None = None) -> Path | None:
    roots = list(search_roots) if search_roots is not None else [
        CODEX_HOME / "sessions",
        CODEX_HOME / "archived_sessions",
    ]

    for root in roots:
        if not root.exists():
            continue
        matches = sorted(root.rglob(f"*{thread_id}.jsonl"))
        if matches:
            return matches[-1]
    return None
```

- [ ] **Step 4: Run tests**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
OK
```

### Task 4: Add Session Guards And Success Verification

**Files:**

- Modify: `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- Modify: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Add failing session-state tests**

Append to the test file:

```python
def write_jsonl(path: Path, items: list[dict]):
    path.write_text("\n".join(json.dumps(item) for item in items) + "\n", encoding="utf-8")


class SessionStateTests(unittest.TestCase):
    def test_session_has_context_compacted_after_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_file = Path(tmp) / "session.jsonl"
            write_jsonl(
                session_file,
                [
                    {"type": "event_msg", "payload": {"type": "task_started"}},
                    {"type": "event_msg", "payload": {"type": "task_complete"}},
                ],
            )
            before_line = rescue.session_line_count(session_file)
            with session_file.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "event_msg", "payload": {"type": "context_compacted"}}) + "\n")

            self.assertTrue(rescue.session_has_context_compacted_after_line(session_file, before_line))

    def test_session_has_context_compacted_after_failure_turn(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_file = Path(tmp) / "session.jsonl"
            event = rescue.parse_compact_failure_log(75122406, "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY)
            write_jsonl(
                session_file,
                [
                    {"type": "response_item", "payload": {"turn_id": "019e10b2-39f4-7703-833d-94561519bc60"}},
                    {"type": "event_msg", "payload": {"type": "context_compacted"}},
                ],
            )

            self.assertTrue(rescue.session_has_context_compacted_after_failure(session_file, event))

    def test_session_active_turn_guard_detects_unfinished_turn(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_file = Path(tmp) / "session.jsonl"
            write_jsonl(session_file, [{"type": "event_msg", "payload": {"type": "task_started"}}])

            self.assertTrue(rescue.session_has_active_turn(session_file))

    def test_session_active_turn_guard_allows_completed_turn(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_file = Path(tmp) / "session.jsonl"
            write_jsonl(
                session_file,
                [
                    {"type": "event_msg", "payload": {"type": "task_started"}},
                    {"type": "event_msg", "payload": {"type": "task_complete"}},
                ],
            )

            self.assertFalse(rescue.session_has_active_turn(session_file))
```

- [ ] **Step 2: Run tests and confirm missing functions**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
AttributeError
```

- [ ] **Step 3: Implement JSONL helpers**

Append to the module:

```python
def iter_session_items(session_file: Path) -> Iterable[dict[str, Any]]:
    with session_file.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                yield item


def session_line_count(session_file: Path) -> int:
    with session_file.open("r", encoding="utf-8") as fh:
        return sum(1 for _ in fh)


def session_line_number_containing(session_file: Path, needle: str) -> int | None:
    if not needle:
        return None
    with session_file.open("r", encoding="utf-8") as fh:
        for line_number, line in enumerate(fh, start=1):
            if needle in line:
                return line_number
    return None


def session_has_context_compacted_after_line(session_file: Path, start_line: int) -> bool:
    with session_file.open("r", encoding="utf-8") as fh:
        for line_number, line in enumerate(fh, start=1):
            if line_number <= start_line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = item.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "context_compacted":
                return True
    return False


def session_has_context_compacted_after_failure(session_file: Path, event: CompactFailureEvent) -> bool:
    if event.turn_id is None:
        return False
    failure_line = session_line_number_containing(session_file, event.turn_id)
    if failure_line is None:
        return False
    return session_has_context_compacted_after_line(session_file, failure_line)


def session_has_active_turn(session_file: Path) -> bool:
    active = False
    terminal = {"task_complete", "turn_aborted", "error"}
    for item in iter_session_items(session_file):
        payload = item.get("payload")
        if not isinstance(payload, dict):
            continue
        event_type = payload.get("type")
        if event_type == "task_started":
            active = True
        elif event_type in terminal:
            active = False
    return active
```

- [ ] **Step 4: Run tests**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
OK
```

### Task 5: Add State, Decision Engine, And Command Builder

**Files:**

- Modify: `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- Modify: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Add failing decision tests**

Append to the test file:

```python
class DecisionTests(unittest.TestCase):
    def test_should_rescue_skips_processed_log_id(self):
        state = {"processed_log_ids": {"75122406": {"status": "rescued"}}}
        event = rescue.parse_compact_failure_log(75122406, "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY)

        decision = rescue.should_rescue(event, state, now=1000, cooldown_seconds=600, max_attempts=2)

        self.assertFalse(decision.allowed)
        self.assertEqual(decision.reason, "already_processed")

    def test_should_rescue_allows_first_attempt(self):
        state = {"processed_log_ids": {}, "threads": {}}
        event = rescue.parse_compact_failure_log(75122406, "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY)

        decision = rescue.should_rescue(event, state, now=1000, cooldown_seconds=600, max_attempts=2)

        self.assertTrue(decision.allowed)
        self.assertEqual(decision.reason, "eligible")

    def test_build_rescue_command_uses_same_thread_and_disabled_goals(self):
        with tempfile.TemporaryDirectory() as tmp:
            output_file = Path(tmp) / "last.txt"
            command = rescue.build_rescue_command(
                codex_bin="codex",
                thread_id="019df873-2bae-73b2-a4a4-150660c3c570",
                model="gpt-5.4-mini",
                reasoning="medium",
                output_last_message=output_file,
            )

        self.assertEqual(command[:3], ["codex", "exec", "resume"])
        self.assertIn("019df873-2bae-73b2-a4a4-150660c3c570", command)
        self.assertEqual(["-m", "gpt-5.4-mini"], command[command.index("-m"):command.index("-m") + 2])
        self.assertIn("--disable", command)
        self.assertIn("goals", command)
        self.assertIn("--skip-git-repo-check", command)
        self.assertIn(str(output_file), command)
```

- [ ] **Step 2: Run tests and confirm missing functions**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
AttributeError
```

- [ ] **Step 3: Implement state and command logic**

Append to the module:

```python
@dataclasses.dataclass(frozen=True)
class RescueDecision:
    allowed: bool
    reason: str


def load_state(state_file: Path) -> dict[str, Any]:
    if not state_file.exists():
        return {"processed_log_ids": {}, "threads": {}}
    try:
        data = json.loads(state_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"processed_log_ids": {}, "threads": {}}
    data.setdefault("processed_log_ids", {})
    data.setdefault("threads", {})
    return data


def save_state(state_file: Path, state: dict[str, Any]) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(state_file)


def should_rescue(
    event: CompactFailureEvent,
    state: dict[str, Any],
    now: float,
    cooldown_seconds: int,
    max_attempts: int,
) -> RescueDecision:
    processed = state.get("processed_log_ids", {})
    if str(event.log_id) in processed:
        return RescueDecision(False, "already_processed")

    thread_state = state.get("threads", {}).get(event.thread_id, {})
    last_attempt_at = float(thread_state.get("last_attempt_at", 0))
    attempts = int(thread_state.get("attempts", 0))

    if attempts >= max_attempts:
        return RescueDecision(False, "max_attempts_reached")
    if last_attempt_at and now - last_attempt_at < cooldown_seconds:
        return RescueDecision(False, "cooldown")
    return RescueDecision(True, "eligible")


def build_rescue_command(
    codex_bin: str,
    thread_id: str,
    model: str,
    reasoning: str,
    output_last_message: Path,
) -> list[str]:
    return [
        codex_bin,
        "exec",
        "resume",
        "-m",
        model,
        "--disable",
        "goals",
        "-c",
        f'model_reasoning_effort="{reasoning}"',
        "--skip-git-repo-check",
        "--json",
        "-o",
        str(output_last_message),
        thread_id,
        MAINTENANCE_PROMPT,
    ]
```

- [ ] **Step 4: Run tests**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
OK
```

### Task 6: Add CLI Orchestration, Locking, Dry-Run, And Execution

**Files:**

- Modify: `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- Modify: `$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1: Add orchestration tests using a fake runner**

Append to the test file:

```python
class FakeRunner:
    def __init__(self):
        self.commands = []

    def __call__(self, command, cwd, timeout, text, capture_output):
        self.commands.append(command)
        return type("Completed", (), {"returncode": 0, "stdout": '{"type":"done"}\n', "stderr": ""})()


class OrchestrationTests(unittest.TestCase):
    def test_handle_event_dry_run_does_not_call_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_file = tmp_path / "state.json"
            session_file = tmp_path / "session.jsonl"
            write_jsonl(session_file, [{"type": "event_msg", "payload": {"type": "task_complete"}}])
            event = rescue.parse_compact_failure_log(75122406, "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY)
            runner = FakeRunner()

            result = rescue.handle_event(
                event=event,
                session_file=session_file,
                state_file=state_file,
                dry_run=True,
                execute=False,
                codex_bin="codex",
                model="gpt-5.4-mini",
                reasoning="medium",
                cooldown_seconds=600,
                max_attempts=2,
                runner=runner,
            )

        self.assertEqual(result, "dry_run")
        self.assertEqual(runner.commands, [])

    def test_handle_event_execute_calls_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_file = tmp_path / "state.json"
            session_file = tmp_path / "session.jsonl"
            write_jsonl(session_file, [{"type": "event_msg", "payload": {"type": "task_complete"}}])
            event = rescue.parse_compact_failure_log(75122406, "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY)
            runner = FakeRunner()

            result = rescue.handle_event(
                event=event,
                session_file=session_file,
                state_file=state_file,
                dry_run=False,
                execute=True,
                codex_bin="codex",
                model="gpt-5.4-mini",
                reasoning="medium",
                cooldown_seconds=600,
                max_attempts=2,
                runner=runner,
            )

        self.assertIn(result, {"executed_unverified", "rescued"})
        self.assertEqual(len(runner.commands), 1)
```

- [ ] **Step 2: Run tests and confirm missing orchestration function**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
AttributeError
```

- [ ] **Step 3: Implement orchestration**

Append to the module:

```python
def mark_processed(state: dict[str, Any], event: CompactFailureEvent, status: str, now: float) -> None:
    state.setdefault("processed_log_ids", {})[str(event.log_id)] = {"status": status, "updated_at": now}
    thread_state = state.setdefault("threads", {}).setdefault(event.thread_id, {})
    thread_state["last_attempt_at"] = now
    thread_state["attempts"] = int(thread_state.get("attempts", 0)) + 1


def acquire_thread_lock(lock_dir: Path, thread_id: str):
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_file = (lock_dir / f"{thread_id}.lock").open("a+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        return None
    return lock_file


def handle_event(
    event: CompactFailureEvent,
    session_file: Path,
    state_file: Path,
    dry_run: bool,
    execute: bool,
    codex_bin: str,
    model: str,
    reasoning: str,
    cooldown_seconds: int,
    max_attempts: int,
    runner=subprocess.run,
) -> str:
    lock_file = acquire_thread_lock(state_file.parent / "locks", event.thread_id)
    if lock_file is None:
        return "locked"

    try:
        state = load_state(state_file)
        now = time.time()

        if session_has_context_compacted_after_failure(session_file, event):
            mark_processed(state, event, "already_compacted", now)
            save_state(state_file, state)
            return "already_compacted"

        if session_has_active_turn(session_file):
            return "active_turn"

        decision = should_rescue(event, state, now, cooldown_seconds, max_attempts)
        if not decision.allowed:
            return decision.reason

        output_file = state_file.parent / f"last-message-{event.thread_id}.txt"
        command = build_rescue_command(codex_bin, event.thread_id, model, reasoning, output_file)
        before_line = session_line_count(session_file)

        if dry_run or not execute:
            return "dry_run"

        completed = runner(command, cwd=str(Path.home()), timeout=900, text=True, capture_output=True)
        if completed.returncode != 0:
            mark_processed(state, event, "command_failed", now)
            save_state(state_file, state)
            return "command_failed"

        if session_has_context_compacted_after_line(session_file, before_line):
            mark_processed(state, event, "rescued", now)
            save_state(state_file, state)
            return "rescued"

        mark_processed(state, event, "executed_unverified", now)
        save_state(state_file, state)
        return "executed_unverified"
    finally:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        lock_file.close()
```

- [ ] **Step 4: Add CLI `main()`**

Append to the module:

```python
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rescue Codex remote compact failures in-place.")
    parser.add_argument("--once", action="store_true", help="Scan once and exit.")
    parser.add_argument("--dry-run", action="store_true", default=True, help="Print actions without running codex.")
    parser.add_argument("--execute", action="store_true", help="Actually run codex exec resume.")
    parser.add_argument("--thread", help="Only process one thread id.")
    parser.add_argument("--since-id", type=int, default=0)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--reasoning", default=DEFAULT_REASONING)
    parser.add_argument("--cooldown-seconds", type=int, default=DEFAULT_COOLDOWN_SECONDS)
    parser.add_argument("--max-attempts", type=int, default=DEFAULT_MAX_ATTEMPTS)
    parser.add_argument("--log-db", type=Path, default=DEFAULT_LOG_DB)
    parser.add_argument("--state-file", type=Path, default=DEFAULT_STATE_FILE)
    parser.add_argument("--codex-bin", default=DEFAULT_CODEX_BIN)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    events = load_recent_compact_failures(args.log_db, since_id=args.since_id, limit=args.limit)
    if args.thread:
        events = [event for event in events if event.thread_id == args.thread]

    if not events:
        print("no compact failures found")
        return 0

    exit_code = 0
    for event in events:
        session_file = find_session_file(event.thread_id)
        if session_file is None:
            print(f"{event.log_id} {event.thread_id} missing_session")
            exit_code = 2
            continue
        result = handle_event(
            event=event,
            session_file=session_file,
            state_file=args.state_file,
            dry_run=not args.execute,
            execute=args.execute,
            codex_bin=args.codex_bin,
            model=args.model,
            reasoning=args.reasoning,
            cooldown_seconds=args.cooldown_seconds,
            max_attempts=args.max_attempts,
        )
        print(f"{event.log_id} {event.thread_id} {result}")

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Run tests**

Run:

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

Expected:

```text
OK
```

### Task 7: Add Executable Wrapper

**Files:**

- Create: `$HOME/.codex/bin/codex-compact-rescue`

- [ ] **Step 1: Create wrapper**

Create `$HOME/.codex/bin/codex-compact-rescue`:

```python
#!/usr/bin/env python3
from pathlib import Path
import importlib.util
import sys


MODULE_PATH = Path.home() / ".codex" / "compact-rescue" / "codex_compact_rescue.py"
spec = importlib.util.spec_from_file_location("codex_compact_rescue", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
raise SystemExit(module.main(sys.argv[1:]))
```

- [ ] **Step 2: Make wrapper executable**

Run:

```bash
chmod +x $HOME/.codex/bin/codex-compact-rescue
```

- [ ] **Step 3: Verify help output**

Run:

```bash
$HOME/.codex/bin/codex-compact-rescue --help
```

Expected:

```text
usage: codex-compact-rescue
```

### Task 8: Dry-Run Against Real Local Logs

**Files:**

- Read only: `$HOME/.codex/logs_2.sqlite`
- Read only: `$HOME/.codex/sessions/**`
- Read only: `$HOME/.codex/archived_sessions/**`
- Generated only if missing: `$HOME/.codex/compact-rescue/state.json`

- [ ] **Step 1: Run real dry-run**

Run:

```bash
$HOME/.codex/bin/codex-compact-rescue --once --since-id 0
```

Expected:

```text
<log_id> <thread_id> dry_run
```

or:

```text
<log_id> <thread_id> already_compacted
```

- [ ] **Step 2: Inspect state after dry-run**

Run:

```bash
test -f $HOME/.codex/compact-rescue/state.json && sed -n '1,220p' $HOME/.codex/compact-rescue/state.json || true
```

Expected:

```text
No new rescued status unless a prior context_compacted marker was detected.
```

### Task 9: Controlled Real Rescue For One Thread

**Files:**

- Read/write session effect: the Codex CLI will append to the original session JSONL.
- Write: `$HOME/.codex/compact-rescue/state.json`
- Write: `$HOME/.codex/compact-rescue/last-message-<thread_id>.txt`

- [ ] **Step 1: Choose one target log id and thread id from dry-run output**

Use the newest unresolved failure whose session is not active.

- [ ] **Step 2: Execute one rescue**

Run:

```bash
$HOME/.codex/bin/codex-compact-rescue \
  --once \
  --execute \
  --thread 019df873-2bae-73b2-a4a4-150660c3c570 \
  --model gpt-5.4-mini \
  --reasoning medium
```

Expected:

```text
<log_id> 019df873-2bae-73b2-a4a4-150660c3c570 rescued
```

or, if Codex did not write the compact event before the script checks:

```text
<log_id> 019df873-2bae-73b2-a4a4-150660c3c570 executed_unverified
```

- [ ] **Step 3: Verify session contains a compact marker**

Run:

```bash
rg -n '"context_compacted"' $HOME/.codex/sessions $HOME/.codex/archived_sessions
```

Expected:

```text
The target thread has a context_compacted entry after the rescue run.
```

### Task 10: Optional Periodic Automation With Launchd

**Files:**

- Create after manual acceptance: `$HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist`

- [ ] **Step 1: Create launchd plist**

Use this content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.codex-compact-rescue</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>$HOME/.codex/bin/codex-compact-rescue --once --execute</string>
  </array>
  <key>StartInterval</key>
  <integer>120</integer>
  <key>StandardOutPath</key>
  <string>/tmp/codex-compact-rescue.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/codex-compact-rescue.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Load launchd job**

Run:

```bash
launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist
launchctl enable gui/$(id -u)/com.local.codex-compact-rescue
```

- [ ] **Step 3: Verify launchd status**

Run:

```bash
launchctl print gui/$(id -u)/com.local.codex-compact-rescue
```

Expected:

```text
state = waiting
```

### Task 11: Operational Runbook

**Files:**

- Create: `$HOME/.codex/compact-rescue/README.md`

- [ ] **Step 1: Document normal operations**

Create README content:

````markdown
# Codex Compact Rescue

This local tool rescues Codex remote compact failures by resuming the original thread with a smaller model and a maintenance-only prompt.

## Dry Run

```bash
$HOME/.codex/bin/codex-compact-rescue --once
```

## Execute One Thread

```bash
$HOME/.codex/bin/codex-compact-rescue --once --execute --thread <thread_id>
```

## Execute All Eligible Failures

```bash
$HOME/.codex/bin/codex-compact-rescue --once --execute
```

## Success Check

```bash
rg -n '"context_compacted"' $HOME/.codex/sessions $HOME/.codex/archived_sessions
```

## Safety Rules

- Dry-run is the default behavior.
- The tool skips sessions that appear to have an active unfinished turn.
- The rescue command disables goals for the maintenance turn.
- The tool never creates a new handoff session.
- The tool does not modify `~/.codex/config.toml`.
````

- [ ] **Step 2: Verify README renders as plain Markdown**

Run:

```bash
sed -n '1,220p' $HOME/.codex/compact-rescue/README.md
```

Expected:

```text
# Codex Compact Rescue
```

---

## 4. Verification Matrix

| Verification | Command | Required Result |
| --- | --- | --- |
| Unit tests | `python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py` | `OK` |
| Wrapper help | `$HOME/.codex/bin/codex-compact-rescue --help` | Shows CLI usage |
| Dry-run safety | `$HOME/.codex/bin/codex-compact-rescue --once` | No `codex exec resume` invocation |
| Real rescue | `$HOME/.codex/bin/codex-compact-rescue --once --execute --thread <thread_id>` | `rescued` or `executed_unverified` |
| Compact marker | `rg -n '"context_compacted"' $HOME/.codex/sessions $HOME/.codex/archived_sessions` | Target thread has a compact marker after rescue |
| Goal isolation | Inspect command output and state | Rescue command includes `--disable goals` |

---

## 5. Rollout Strategy

1. Implement Tasks 1-7 with unit tests only.
2. Run Task 8 dry-run against local logs.
3. Execute Task 9 for one thread only.
4. Continue the original Desktop conversation after the rescue.
5. If the original thread behaves normally and the session JSONL contains `context_compacted`, enable Task 10 launchd automation.
6. If Task 9 returns `executed_unverified`, rerun the success check after 30 seconds before trying a second rescue.
7. If two attempts fail on the same thread, mark the thread `needs_manual_review` and do not retry automatically.

---

## 6. Self-Review

Spec coverage:

- Same original session: covered by `codex exec resume <thread_id>`.
- Automatic handling: covered by launchd after manual acceptance.
- Goal compatibility: covered by `--disable goals` and maintenance prompt.
- Avoid handoff: covered by selected approach and command builder tests.
- Safety: covered by dry-run default, active-turn guard, cooldown, max attempts, state file, and success verification.

Placeholder scan:

- No implementation step depends on unspecified behavior.
- Every created file has an exact absolute path.
- Every verification step has a concrete command and expected result.

Known implementation caveat:

- Historical "already compacted" detection is only reliable when the failed `turn_id` appears in the session JSONL. Real rescue success verification is stronger because it snapshots the session line count before `codex exec resume` and only accepts a `context_compacted` event appended after that point.
