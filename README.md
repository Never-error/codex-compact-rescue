# Codex Compact Rescue

Codex Compact Rescue is an unofficial, local-first recovery plan for Codex
sessions that fail during remote context compaction.

The project documents a practical path for keeping the original Codex thread
usable when remote compact requests fail on a larger model. The main idea is to
detect compact failures, retry the compact work with a smaller fallback model,
install the compacted history, and let the original conversation continue.

> This repository does not include or distribute patched Codex binaries. It is a
> documentation and implementation-plan repository for operators who want a
> reproducible, auditable rescue layer.

## Background

Codex Desktop and Codex CLI can automatically compact long conversations when
the thread approaches the model context limit. On some local runs, remote compact
requests using `gpt-5.5` failed with errors shaped like:

```text
stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses/compact)
```

When this happens, the user-facing turn can appear disconnected or stalled even
though the underlying session still exists. Switching to a smaller model for the
compact operation has been observed to succeed more reliably, so this project
explores two compatible recovery paths:

- **Internal fallback compact model:** retry the failed compact operation in the
  same turn with a fallback model such as `gpt-5.4-mini`, then emit the normal
  compaction events.
- **CLI original-session rescue:** detect compact failures from local logs and
  resume the same thread with a maintenance-only turn that uses a smaller model
  to trigger compaction.

The first path is closest to native automatic compaction. The second path is more
portable because it can be built as a local command-line tool without shipping
modified application binaries.

## Repository Layout

```text
.
├── README.md
├── LICENSE
├── docs/
│   ├── operations-zh.md
│   └── superpowers/plans/
│       ├── 2026-05-10-codex-compact-rescue.md
│       └── 2026-05-10-codex-compact-rescue-zh.md
└── .gitignore
```

The English and Chinese plan files contain the full feasibility analysis,
implementation tasks, safety guards, and acceptance criteria. The operations
runbook gives day-to-day verification commands.

## Recommended Operating Model

1. Keep normal Codex work on the preferred model, for example `gpt-5.5`.
2. Detect compact failures from local Codex logs and session JSONL files.
3. Retry only the compact/rescue step with a smaller model.
4. Confirm that the original session records a `context_compacted` event.
5. Continue working in the same Codex conversation.

The rescue turn should be treated as infrastructure maintenance, not project
work. It should not run tools, update goals, finish goals, or create a handoff
thread.

## Manual Verification

Check that Codex is using HTTP Responses instead of repeatedly retrying
WebSocket transport:

```bash
rg -n 'model_provider|supports_websockets|responses_websockets' "$HOME/.codex/config.toml"
```

Check whether compact success events exist in recent session files:

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

Check whether remote compact failures were logged:

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select datetime(timestamp, 'unixepoch'), level, target, substr(feedback_log_body, 1, 300)
   from logs
   where target = 'codex_core::compact_remote'
   order by id desc
   limit 20;"
```

## CLI Rescue Shape

The proposed local rescue command is intentionally conservative:

```bash
codex exec resume <thread_id> \
  "[codex-compact-rescue] This is a maintenance turn, not task execution. Do not run tools. Do not update, complete, or create any goal. Do not continue project work. Reply only: compact-ok." \
  -m gpt-5.4-mini \
  -c 'model_reasoning_effort="medium"' \
  --disable goals \
  --skip-git-repo-check \
  --json
```

In an automated implementation, dry-run should be the default. Execution should
require an explicit flag, per-thread locking, cooldown, duplicate detection, and
post-run verification of a new `context_compacted` event.

## Safety Rules

- Do not publish patched Codex application binaries.
- Do not include local tokens, account identifiers, raw session contents, or
  private project prompts in public artifacts.
- Treat `~/.codex/logs_2.sqlite` and `~/.codex/sessions/**/*.jsonl` as local
  evidence sources, not files to commit.
- Prefer fallback only for compaction/rescue, not for the user's normal model.
- If a session appears to have an active unfinished turn, skip rescue.

## Status

This repository currently contains the feasibility analysis, implementation
plan, and operating runbook. The implementation plan is written so it can be
executed task-by-task into a standalone Python standard-library CLI.

## License

MIT. See [LICENSE](LICENSE).
