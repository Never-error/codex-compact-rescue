# Roadmap

This file tracks implementation work for turning the repository into a complete
patcher project. The README is the public user entrypoint; this roadmap is for
development status and release planning.

## Required Project Assets

- `patches/`
  - Source-level patch for the Codex CLI compact failure path.
  - Version or commit compatibility notes.
  - Patch marker string used by verification scripts.

- `scripts/`
  - `scripts/build.sh` and `scripts/build.ps1` for constructing the patched
    bundled CLI.
  - `scripts/install.sh` and `scripts/install.ps1` for backing up and replacing
    the bundled CLI.
  - `scripts/restore.sh` and `scripts/restore.ps1` for rollback from backup.
  - `scripts/verify.sh` and `scripts/verify.ps1` for hash, marker-string, and
    local-log checks.
  - `scripts/check-upstream-compat.sh` for validating upstream patch drift.

- `docs/github-actions/`
  - Upstream compatibility workflow template.
  - Move the template into `.github/workflows/` with a token that has
    `workflow` scope to enable scheduled checks.

- `release/`
  - Platform package builder.
  - `checksums.txt` generator.
  - release notes template.
  - packaging matrix for macOS, Windows, and Linux.

## Acceptance Criteria

- A clean clone can build a patcher package without local private files.
- The patch is source-reviewable.
- Installers never upload or publish Codex binaries.
- Installers always create a backup before replacement.
- Verification distinguishes patch presence from fallback trigger.
- Release archives contain scripts, patch files, documentation, and checksums.

## Implemented Project Structure

- Source-level patch:
  - `patches/openai-codex-compact-fallback.patch`
  - Targets `codex-rs/core/src/compact_remote.rs`.
  - Adds fallback retry from `gpt-5.5` to `gpt-5.4-mini`.
  - Emits `retrying remote compaction with fallback model` for verification.

- Platform scripts:
  - Unix/macOS/Linux: `scripts/build.sh`, `scripts/install.sh`,
    `scripts/restore.sh`, `scripts/verify.sh`
  - Windows PowerShell: `scripts/build.ps1`, `scripts/install.ps1`,
    `scripts/restore.ps1`, `scripts/verify.ps1`

- Release packaging:
  - `release/package.sh`
  - `release/RELEASE_NOTES.md`
  - Generates platform archives and `checksums.txt`.

- Tests:
  - `tests/test_scripts.sh`
  - Covers install, verify, restore, package, and checksum behavior with fake binaries.

## Current Priority

1. Run a full Rust build against a clean upstream checkout for each supported
   Codex release target.
2. Enable the upstream compatibility workflow from `docs/github-actions/` once
   GitHub credentials with `workflow` scope are available.
3. Add platform-specific Codex app path discovery so install commands need fewer
   manual paths.
4. Decide whether future releases should include root-level wrapper commands in
   addition to the existing `scripts/` entrypoints.
