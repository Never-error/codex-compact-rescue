# Codex Compact Rescue

Codex Compact Rescue is an unofficial, local-first recovery project for Codex
sessions that fail during remote context compaction.

The local proof of concept was implemented by patching the Codex Desktop bundled
CLI at the compact-failure path: when remote compact fails on a larger model,
the same turn retries compaction with a smaller fallback model, installs the
compacted history, emits the normal compaction events, and continues the
original conversation.

> This repository does not include or distribute patched Codex binaries. It is a
> documentation and implementation-plan repository that describes the behavior,
> verification workflow, and safer portable alternatives.

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
distinguishes two compatible recovery paths:

- **Internal fallback compact model:** retry the failed compact operation in the
  same turn with a fallback model such as `gpt-5.4-mini`, then install compacted
  history and emit the normal compaction events. This is the path used by the
  local patched proof of concept.
- **CLI original-session rescue:** detect compact failures from local logs and
  resume the same thread with a maintenance-only turn that uses a smaller model
  to trigger compaction. This is the safer portable fallback design documented
  for open-source implementation.

The first path is closest to native automatic compaction. The second path is more
portable because it can be built as a local command-line tool without shipping
modified application binaries.

## Local Patch Behavior

The internal patch is intended to behave like native automatic compaction:

```text
remote compact with gpt-5.5 fails
-> same turn retries compact with fallback model
-> compacted history is installed
-> context_compacted / thread compacted event is emitted
-> original turn continues
```

Operationally, that means the patched Codex binary is a local machine artifact:

1. Back up the original bundled CLI from the Codex app.
2. Replace the bundled CLI with a patched build.
3. Keep normal user turns on the configured default model.
4. Use the fallback model only for the failed compact retry path.
5. Verify behavior from local logs and session JSONL markers.

The repository intentionally avoids publishing the modified binary. A public
implementation should ship source code, patch notes, tests, and runbooks rather
than an opaque application replacement.

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

This repository currently contains the local patch background, feasibility
analysis, implementation plan, and operating runbook. The implementation plan is
also written so it can be executed task-by-task into a standalone Python
standard-library CLI for users who do not want to replace their local Codex
binary.

## License

MIT. See [LICENSE](LICENSE).
