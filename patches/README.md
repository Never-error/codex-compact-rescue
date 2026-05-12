# Patches

Source-level patches for the Codex CLI compact fallback behavior live here.

Current patch:

- `openai-codex-compact-fallback.patch`
- Target file: `openai/codex` `codex-rs/core/src/compact_remote.rs`
- Verified target blob: `cc31d50b13268417fa34d8262a7c3682cda8912e`
- Checked date: 2026-05-12
- Locally observed Codex Desktop bundled CLI: `codex-cli 0.130.0-alpha.5`

Run `git apply --check patches/openai-codex-compact-fallback.patch` against the
target checkout before building.

Patch files must:

- Name the compatible upstream Codex CLI version or commit.
- Modify the remote compact failure path, not normal user turns.
- Use an explicit fallback compact model.
- Emit a stable marker string for verification.
- Avoid embedding local paths, tokens, session content, or binaries.
