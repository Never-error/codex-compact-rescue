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
  - `build` for constructing the patched bundled CLI.
  - `install` for backing up and replacing the bundled CLI.
  - `restore` for rollback from backup.
  - `verify` for hash, marker-string, and local-log checks.

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
  - Unix/macOS/Linux: `scripts/build.sh`, `install.sh`, `restore.sh`, `verify.sh`
  - Windows PowerShell: `scripts/build.ps1`, `install.ps1`, `restore.ps1`, `verify.ps1`

- Release packaging:
  - `release/package.sh`
  - `release/RELEASE_NOTES.md`
  - Generates platform archives and `checksums.txt`.

- Tests:
  - `tests/test_scripts.sh`
  - Covers install, verify, restore, package, and checksum behavior with fake binaries.

## Current Priority

1. Run a full Rust build against a clean upstream checkout.
2. Add CI that validates `git apply --check`, shell tests, and release packaging.
3. Add platform-specific Codex app path discovery.
4. Publish the first GitHub release with macOS, Linux, and Windows patcher assets.
