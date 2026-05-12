# Codex 压缩失败原地救援实现计划

> **给 agentic workers 的要求：** 实施本计划时必须使用 `superpowers:subagent-driven-development` 或 `superpowers:executing-plans`。所有步骤使用 checkbox (`- [ ]`) 跟踪执行状态。

**目标：** 做一个本地 CLI 救援层，在 Codex 远程压缩失败后自动识别失败事件，用较小模型恢复同一个原始会话触发维护式压缩，并在确认 `context_compacted` 后让用户继续原会话工作。

**架构：** 用 Python 标准库实现一个本地命令行工具，读取 `~/.codex/logs_2.sqlite` 和 `~/.codex/sessions/**/*.jsonl`，判断哪些 compact 失败还需要救援。救援时执行 `codex exec resume <thread_id> <maintenance_prompt>`，使用 `gpt-5.4-mini`，并对维护 turn 禁用 goals，避免影响用户原本的 Goal 状态。

**技术栈：** Python 3 标准库、SQLite、JSONL、Codex CLI `0.128.0`、macOS `launchd` 可选定时执行。

---

## 1. 可行性分析

### 1.1 当前问题

本机已经观察到多次 `gpt-5.5` 远程 compact 失败，典型错误是：

```text
stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses/compact)
```

本地证据说明这不是普通代理未生效：

- Codex CLI 版本是 `codex-cli 0.128.0`。
- 当前默认模型是 `gpt-5.5`，推理强度是 `xhigh`。
- `goals = true`，`multi_agent_v2` 已启用。
- 失败日志目标是 `codex_core::compact_remote`。
- 失败请求体量已经接近百万 model-visible bytes。
- 成功压缩会在 session JSONL 中出现 `context_compacted` 事件。

社区方向也一致：已有项目用代理方式把 compact 请求单独降级到 `gpt-5.4`，例如 [`codex-compact-proxy`](https://github.com/tiderzheng/codex-compact-proxy)。但代理方案更依赖网络链路和 provider 配置，不是最稳的第一步。

### 1.2 三种方案对比

| 方案 | 做法 | 优点 | 问题 |
| --- | --- | --- | --- |
| 透明 compact proxy | 拦截 `/responses/compact`，只把 compact 模型改成 `gpt-5.4` 或 `gpt-5.4-mini` | 最像官方自动压缩，没有维护消息 | Codex Desktop 走 `chatgpt.com/backend-api`，HTTPS 拦截或 provider 重绑风险高 |
| CLI 原地救援 | 发现失败后执行 `codex exec resume <thread_id>`，用小模型做维护 turn | 保留原 thread，支持自动化，落地快 | 会多一条维护消息，需要避免和正在运行的 turn 冲突 |
| 新会话 handoff | 生成 summary 后开新会话 | 实现简单 | 不满足“原会话继续”，会破坏工作流 |

结论：第一阶段采用 **CLI 原地救援**。它不是最透明，但可控、可测、可回滚，最适合先解决当前失败。

### 1.3 为什么 CLI 原地救援可行

本机 `codex exec resume --help` 已确认支持这些能力：

```bash
codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]
```

关键参数：

- `-m gpt-5.4-mini`：只对救援 turn 降级模型，不改全局默认模型。
- `--disable goals`：维护 turn 不进入 Goal 工作流。
- `-c 'model_reasoning_effort="medium"'`：降低救援推理强度。
- `--skip-git-repo-check`：救援不依赖当前目录是否是 git repo。
- `--json`：输出 JSONL，便于记录执行结果。
- `-o <file>`：保存最后一条模型回复，便于审计。

维护 turn 的目标不是继续项目工作，而是触发 Codex 自身的上下文压缩机制。

### 1.4 Goal 模式兼容性

兼容，但必须遵守三个规则：

1. 救援命令加 `--disable goals`。
2. 维护 prompt 明确禁止更新、完成、创建 goal。
3. 成功标准只看 session JSONL 里的 `context_compacted`，不看 goal 状态。

维护 prompt：

```text
[codex-compact-rescue] This is a maintenance turn, not task execution. Do not run tools. Do not update, complete, or create any goal. Do not continue project work. Reply only: compact-ok. If the system triggers automatic context compaction, wait for compaction to finish before replying.
```

### 1.5 关键风险

| 风险 | 影响 | 处理方式 |
| --- | --- | --- |
| 用户原会话正在运行任务 | 救援 turn 和工作 turn 并发，顺序混乱 | active-turn guard：发现 `task_started` 后没有结束事件就跳过 |
| 同一失败被反复救援 | 浪费额度，污染会话 | `state.json` 记录处理过的 log id 和每个 thread 的冷却时间 |
| 小模型也压缩失败 | 继续失败 | 最多尝试两次：`medium` 后可降到 `low`，再失败就标记人工处理 |
| Desktop UI 未立即刷新 | 用户看不到压缩结果 | 以 session JSONL 为准，必要时重新打开同一 thread |
| 维护 turn 改动 Goal | 影响原任务 | `--disable goals` 加 prompt 双保险 |
| 误判历史 compact 成功 | 错过救援 | 历史判断必须定位失败 `turn_id`，真实救援成功必须看执行后新增 `context_compacted` |

---

## 2. 文件规划

创建这些文件：

- `$HOME/.codex/compact-rescue/codex_compact_rescue.py`
  - 主逻辑文件。
  - 负责读取 SQLite、解析日志、查找 session 文件、判断是否救援、构造命令、执行命令、验证结果。

- `$HOME/.codex/bin/codex-compact-rescue`
  - 可执行入口。
  - 只负责加载主模块并调用 `main()`。

- `$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
  - 单元测试。
  - 使用临时 SQLite 和临时 JSONL，不调用真实 Codex CLI。

运行时生成：

- `$HOME/.codex/compact-rescue/state.json`
  - 已处理日志、重试次数、每个 thread 的最近救援时间。

- `$HOME/.codex/compact-rescue/rescue.log`
  - 追加式运行日志。

- `$HOME/.codex/compact-rescue/locks/<thread_id>.lock`
  - 每个 thread 一个锁，防止并发救援。

可选自动化：

- `$HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist`
  - 通过 `launchd` 每隔一段时间执行一次救援扫描。

---

## 3. 实施计划

### Task 1：写失败日志解析测试

**文件：**

- 创建：`$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`

- [ ] **Step 1：创建测试目录**

运行：

```bash
mkdir -p $HOME/.codex/compact-rescue/tests
```

- [ ] **Step 2：写解析测试**

创建测试文件，先只覆盖 compact 失败日志解析：

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
    'turn{otel.name="session_task.compact" thread.id=019df873-2bae-73b2-a4a4-150660c3c570 '
    'turn.id=019e10b2-39f4-7703-833d-94561519bc60 model=gpt-5.5}: '
    'remote compaction failed turn_id=019e10b2-39f4-7703-833d-94561519bc60 '
    'last_api_response_total_tokens=184680 '
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

- [ ] **Step 3：验证测试先失败**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
FileNotFoundError
```

### Task 2：实现日志解析和数据模型

**文件：**

- 创建：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：写最小实现**

创建主模块：

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import fcntl
import json
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

- [ ] **Step 2：跑测试**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
OK
```

### Task 3：实现 SQLite 读取和 session 文件定位

**文件：**

- 修改：`$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- 修改：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：追加测试**

测试要覆盖：

- 只读取 `target='codex_core::compact_remote'` 且 `level='ERROR'` 的日志。
- 只读取 `id > since_id` 的日志。
- 能从 `~/.codex/sessions` 或 `~/.codex/archived_sessions` 找到包含 thread id 的 JSONL 文件。

核心测试代码：

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
                (10, "ERROR", "codex_core::compact_remote", "019df873-2bae-73b2-a4a4-150660c3c570", FAILURE_BODY),
            )
            conn.commit()
            conn.close()

            events = rescue.load_recent_compact_failures(db_path, since_id=0, limit=20)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].log_id, 10)

    def test_find_session_file_locates_matching_rollout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "sessions" / "2026" / "05" / "05"
            root.mkdir(parents=True)
            target = root / "rollout-2026-05-05T22-03-10-019df873-2bae-73b2-a4a4-150660c3c570.jsonl"
            target.write_text("{}\n", encoding="utf-8")

            found = rescue.find_session_file(
                "019df873-2bae-73b2-a4a4-150660c3c570",
                search_roots=[Path(tmp) / "sessions"],
            )

        self.assertEqual(found, target)
```

- [ ] **Step 2：实现函数**

追加：

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

- [ ] **Step 3：验证**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
OK
```

### Task 4：实现 session 状态判断

**文件：**

- 修改：`$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- 修改：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：测试 active turn 和 compact marker**

需要覆盖：

- `task_started` 后没有 `task_complete` 时不能救援。
- 执行救援前记录 session 行数，执行后只认新增的 `context_compacted`。
- 如果历史里失败 `turn_id` 后已经有 `context_compacted`，可以标记为已经恢复。

核心实现：

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

- [ ] **Step 2：验证**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
OK
```

### Task 5：实现状态文件、救援决策和命令构造

**文件：**

- 修改：`$HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py`
- 修改：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：实现状态读写**

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
```

- [ ] **Step 2：实现是否允许救援**

```python
def should_rescue(
    event: CompactFailureEvent,
    state: dict[str, Any],
    now: float,
    cooldown_seconds: int,
    max_attempts: int,
) -> RescueDecision:
    if str(event.log_id) in state.get("processed_log_ids", {}):
        return RescueDecision(False, "already_processed")

    thread_state = state.get("threads", {}).get(event.thread_id, {})
    last_attempt_at = float(thread_state.get("last_attempt_at", 0))
    attempts = int(thread_state.get("attempts", 0))

    if attempts >= max_attempts:
        return RescueDecision(False, "max_attempts_reached")
    if last_attempt_at and now - last_attempt_at < cooldown_seconds:
        return RescueDecision(False, "cooldown")
    return RescueDecision(True, "eligible")
```

- [ ] **Step 3：实现命令构造**

注意：`resume` 的选项放在 session id 和 prompt 前面，更贴合当前 help。

```python
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

- [ ] **Step 4：验证**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
OK
```

### Task 6：实现救援编排和锁

**文件：**

- 修改：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：实现处理状态**

```python
def mark_processed(state: dict[str, Any], event: CompactFailureEvent, status: str, now: float) -> None:
    state.setdefault("processed_log_ids", {})[str(event.log_id)] = {"status": status, "updated_at": now}
    thread_state = state.setdefault("threads", {}).setdefault(event.thread_id, {})
    thread_state["last_attempt_at"] = now
    thread_state["attempts"] = int(thread_state.get("attempts", 0)) + 1
```

- [ ] **Step 2：实现每个 thread 的文件锁**

```python
def acquire_thread_lock(lock_dir: Path, thread_id: str):
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_file = (lock_dir / f"{thread_id}.lock").open("a+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        return None
    return lock_file
```

- [ ] **Step 3：实现单个事件救援**

```python
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

- [ ] **Step 4：验证**

运行：

```bash
python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py
```

预期：

```text
OK
```

### Task 7：实现 CLI 参数入口

**文件：**

- 修改：`$HOME/.codex/compact-rescue/codex_compact_rescue.py`

- [ ] **Step 1：实现参数解析**

```python
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rescue Codex remote compact failures in-place.")
    parser.add_argument("--once", action="store_true", help="Scan once and exit.")
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
```

- [ ] **Step 2：实现主流程**

```python
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

### Task 8：创建可执行入口

**文件：**

- 创建：`$HOME/.codex/bin/codex-compact-rescue`

- [ ] **Step 1：创建 wrapper**

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

- [ ] **Step 2：赋予执行权限**

运行：

```bash
chmod +x $HOME/.codex/bin/codex-compact-rescue
```

- [ ] **Step 3：验证 help**

运行：

```bash
$HOME/.codex/bin/codex-compact-rescue --help
```

预期：

```text
usage:
```

### Task 9：真实 dry-run

**文件：**

- 只读：`$HOME/.codex/logs_2.sqlite`
- 只读：`$HOME/.codex/sessions/**`
- 只读：`$HOME/.codex/archived_sessions/**`

- [ ] **Step 1：扫描本机失败日志**

运行：

```bash
$HOME/.codex/bin/codex-compact-rescue --once --since-id 0
```

预期输出之一：

```text
<log_id> <thread_id> dry_run
```

或：

```text
<log_id> <thread_id> already_compacted
```

dry-run 不能执行 `codex exec resume`。

### Task 10：单 thread 真实救援

**文件影响：**

- Codex CLI 会向原 session JSONL 追加维护 turn。
- 写入 `$HOME/.codex/compact-rescue/state.json`。
- 写入 `$HOME/.codex/compact-rescue/last-message-<thread_id>.txt`。

- [ ] **Step 1：从 dry-run 结果选一个未恢复 thread**

选择条件：

- 不是 `already_compacted`。
- 不是 `active_turn`。
- 是最近一次 compact 失败。

- [ ] **Step 2：执行救援**

示例：

```bash
$HOME/.codex/bin/codex-compact-rescue \
  --once \
  --execute \
  --thread 019df873-2bae-73b2-a4a4-150660c3c570 \
  --model gpt-5.4-mini \
  --reasoning medium
```

预期：

```text
<log_id> 019df873-2bae-73b2-a4a4-150660c3c570 rescued
```

如果返回：

```text
executed_unverified
```

等待 30 秒后再查 session JSONL，不要立刻重复救援。

- [ ] **Step 3：确认 compact marker**

运行：

```bash
rg -n '"context_compacted"' $HOME/.codex/sessions $HOME/.codex/archived_sessions
```

预期：

```text
目标 thread 在救援之后出现新的 context_compacted
```

### Task 11：可选 launchd 自动化

只有在单 thread 真实救援成功后再启用。

**文件：**

- 创建：`$HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist`

plist 内容：

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

加载：

```bash
launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/com.local.codex-compact-rescue.plist
launchctl enable gui/$(id -u)/com.local.codex-compact-rescue
```

验证：

```bash
launchctl print gui/$(id -u)/com.local.codex-compact-rescue
```

---

## 4. 验收标准

| 验收项 | 命令 | 通过标准 |
| --- | --- | --- |
| 单元测试 | `python3 -m unittest $HOME/.codex/compact-rescue/tests/test_codex_compact_rescue.py` | 输出 `OK` |
| CLI help | `$HOME/.codex/bin/codex-compact-rescue --help` | 显示 usage |
| dry-run 安全性 | `$HOME/.codex/bin/codex-compact-rescue --once` | 不调用 `codex exec resume` |
| 单 thread 救援 | `$HOME/.codex/bin/codex-compact-rescue --once --execute --thread <thread_id>` | 输出 `rescued` 或 `executed_unverified` |
| 压缩成功标记 | `rg -n '"context_compacted"' $HOME/.codex/sessions $HOME/.codex/archived_sessions` | 目标 thread 有新增 marker |
| Goal 隔离 | 检查构造命令 | 包含 `--disable goals` |

---

## 5. 上线顺序

1. 先实现脚本和单元测试。
2. 跑真实 dry-run，不执行救援。
3. 只选一个 thread 做真实救援。
4. 确认原 Desktop 会话能继续工作。
5. 确认 session JSONL 有新增 `context_compacted`。
6. 再考虑启用 `launchd` 自动扫描。
7. 同一 thread 两次失败后停止自动重试，标记为 `needs_manual_review`。

---

## 6. 不做的事

第一版不做这些：

- 不修改 `~/.codex/config.toml`。
- 不默认安装 `launchd`。
- 不创建新 handoff 会话。
- 不尝试 HTTPS 透明代理。
- 不自动切换用户默认模型。
- 不在 active turn 中插入救援。

---

## 7. 最终判断

这个方案可行，并且适合先实现。

它不能做到完全无痕，因为 CLI resume 会产生一个维护 turn；但它满足最关键的约束：仍然使用原 thread、原 session 文件、原 Desktop 会话上下文，并且通过 `context_compacted` 验证是否真的恢复到了可继续工作的状态。
