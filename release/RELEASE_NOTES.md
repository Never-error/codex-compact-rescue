# Release Notes v0.1.1

## Codex gpt-5.5 Compact Fallback Patch

This release refreshes upstream compatibility handling after the official Codex
App and `openai/codex` prerelease updates.

## Compatibility

- Stable `rust-v0.133.0`: `patch_applies_with_drift`
- Historical stable `rust-v0.130.0`: `patch_applies_with_drift`
- Prerelease `rust-v0.133.0-alpha.1`: `patch_applies_with_drift`
- Prerelease `rust-v0.131.0-alpha.18`: `patch_applies`
- Current `main`: `patch_applies_with_drift`
- Locally observed Codex Desktop bundled CLI: `codex-cli 0.133.0-alpha.1`

## Changes

- Add `scripts/patch-macos-codex-app.sh`, a macOS Codex.app workflow wrapper
  that performs external backups, version checks, marker verification,
  no-resign installation, signature state capture, running `app-server` inode
  checks, and rollback command output.
- Add `scripts/check-upstream-compat.sh` for source-level compatibility checks.
- Add a GitHub Actions workflow template for upstream compact patch drift under
  `docs/github-actions/`.
- Expand `scripts/verify.sh` and `scripts/verify.ps1` into post-update health
  checks with app version, CLI version, hash, marker status, install state, and
  optional upstream compatibility output.
- Refresh English and Simplified Chinese README quick-start guidance.

## Assets

- Source patch under `patches/`
- Build, install, macOS app patch, restore, and verify scripts under `scripts/`
- Upstream compatibility checker under `scripts/`
- Operator documentation under `docs/`
- English and Simplified Chinese README files
- SHA-256 checksums in `checksums.txt`

## Validation

- The source patch applies cleanly to `codex-rs/core/src/compact_remote.rs` for
  `main`, `rust-v0.133.0`, `rust-v0.133.0-alpha.1`,
  `rust-v0.131.0-alpha.18`, and `rust-v0.130.0`.
- Script tests cover install, verify, restore, package creation, and checksum
  generation with local fake binaries.
- This release does not include a prebuilt patched Codex binary.

## Safety

This release does not include a modified Codex application bundle. Installers
operate on a user's local Codex installation and create a backup before
replacement.

## Verification

After installation, verify marker strings:

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

Verify fallback trigger logs:

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```
