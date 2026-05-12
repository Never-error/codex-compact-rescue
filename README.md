# Codex gpt-5.5 Compact Fallback Patch

This project is focused on an unofficial patched Codex Desktop bundled binary
that makes `gpt-5.5` remote compact failures recoverable.

The patch targets the compact failure path inside the Codex CLI bundled with
Codex Desktop. When remote compact fails on `gpt-5.5`, the same turn retries the
compact operation with a fallback model, installs the compacted history, emits
the normal compacted-thread events, and continues the original conversation.

```text
remote compact with gpt-5.5 fails
-> retry compact in the same turn with fallback model
-> install compacted history
-> emit context_compacted / thread compacted
-> continue the original turn
```

> This repository does not publish the patched binary. It documents the patch
> behavior, local install workflow, verification commands, upgrade risks, and
> implementation notes needed to reproduce the behavior.

## Background

Codex Desktop and Codex CLI can automatically compact long conversations when
the thread approaches the model context limit. On some local runs, remote compact
requests using `gpt-5.5` failed with errors shaped like:

```text
stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses/compact)
```

When this happens, the user-facing turn can appear disconnected or stalled even
though the underlying session still exists. The patched-binary approach keeps
the recovery at the original failure site instead of asking the user to manually
start a new thread or run a separate handoff flow.

## Patch Scope

The main project scope is the internal fallback compact path:

- Default conversation model can remain `gpt-5.5`.
- Only failed remote compact operations switch to the fallback compact model.
- The fallback retry stays inside the same turn.
- Successful fallback installs compacted history into the original thread.
- The original Codex conversation continues after compaction.

Out of scope for the main patch:

- Publishing patched Codex application binaries.
- Changing normal user turns to a smaller model.
- Creating a new handoff session after compact failure.
- Requiring users to manually resume a thread after every compact failure.

## Patched Binary Workflow

The patched Codex binary is a local machine artifact:

1. Back up the original bundled CLI from the Codex app.
2. Replace the bundled CLI with a patched build.
3. Keep normal user turns on the configured default model.
4. Use the fallback model only for the failed compact retry path.
5. Verify behavior from local logs and session JSONL markers.

Example local paths on macOS:

```text
/Applications/Codex.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex.backup-<timestamp>
```

The repository intentionally avoids publishing the modified binary. A public
implementation should ship source patches, patch notes, tests, and runbooks
rather than an opaque application replacement.

## Repository Layout

```text
.
├── README.md
├── LICENSE
├── docs/
│   ├── operations-zh.md
│   ├── patched-binary-zh.md
│   └── superpowers/plans/
│       ├── 2026-05-10-codex-compact-rescue.md
│       └── 2026-05-10-codex-compact-rescue-zh.md
└── .gitignore
```

`README.md`, `docs/patched-binary-zh.md`, and `docs/operations-zh.md` describe
the patched-binary workflow. The older plan files preserve the broader
investigation, including the external CLI rescue design, but that design is now
secondary to the patched-binary path.

## Verification

Check whether the installed bundled CLI still contains the patch markers:

```bash
shasum -a 256 /Applications/Codex.app/Contents/Resources/codex
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

Check whether fallback compact was actually triggered:

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

Check whether ordinary compaction succeeded in a session:

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

Check that Codex is using HTTP Responses instead of repeatedly retrying
WebSocket transport:

```bash
rg -n 'model_provider|supports_websockets|responses_websockets' "$HOME/.codex/config.toml"
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

## Upgrade And Rollback

Codex Desktop upgrades can overwrite the bundled CLI. After every app upgrade,
re-run the binary and log verification commands above.

Rollback is file-based:

1. Quit Codex Desktop.
2. Restore the backed-up original bundled CLI.
3. Reopen Codex Desktop.
4. Verify the binary hash and app behavior again.

## Appendix: CLI Rescue

An external CLI rescue layer was investigated earlier. It is not the main
project focus, but it remains useful as a portable fallback for users who do not
want to replace the bundled binary.

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
- Prefer fallback only for failed remote compact retry, not for normal user
  turns.
- Keep backup and rollback instructions next to any local binary replacement.

## Status

This repository is centered on the `gpt-5.5` compact fallback patched-binary
approach. The CLI rescue material is retained as historical investigation and a
secondary fallback design.

## License

MIT. See [LICENSE](LICENSE).
