# Release Notes

## Codex gpt-5.5 Compact Fallback Patch

This release packages the source-level compact fallback patch and platform
patcher scripts.

Compatible target for this patcher release:

- `openai/codex` `codex-rs/core/src/compact_remote.rs`
- Verified target blob: `cc31d50b13268417fa34d8262a7c3682cda8912e`
- Locally observed Codex Desktop bundled CLI: `codex-cli 0.130.0-alpha.5`

## Assets

- Source patch under `patches/`
- Build, install, restore, and verify scripts under `scripts/`
- Operator documentation under `docs/`
- English and Simplified Chinese README files
- SHA-256 checksums in `checksums.txt`

## Validation

- The source patch applies cleanly to `codex-rs/core/src/compact_remote.rs`.
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
