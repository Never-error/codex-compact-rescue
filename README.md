# Codex gpt-5.5 Compact Fallback Patch

Language: English | [简体中文](README.zh-CN.md)

Repository: https://github.com/Never-error/codex-compact-rescue

Patch and packaging workflow for making Codex Desktop `gpt-5.5` remote compact
failures recoverable.

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

This repository is designed for patcher-style releases. It does not distribute
modified Codex application bundles.

## Compatibility

Current source patch:

- Patch file: `patches/openai-codex-compact-fallback.patch`
- Upstream target: `openai/codex` `codex-rs/core/src/compact_remote.rs`
- Checked date: 2026-05-15
- Locally observed Codex Desktop bundled CLI: `codex-cli 0.130.0-alpha.5`

Verified upstream compatibility:

| Upstream ref | Target blob | Result |
| --- | --- | --- |
| `main` | `cc31d50b13268417fa34d8262a7c3682cda8912e` | `patch_applies` |
| `rust-v0.131.0-alpha.18` | `cc31d50b13268417fa34d8262a7c3682cda8912e` | `patch_applies` |
| `rust-v0.130.0` | `35b8a01fc32fff7944b75670acbd5e33dff161af` | `patch_applies_with_drift` |

Always run `git apply --check` against your OpenAI Codex checkout before
building. If the upstream compact implementation changed, stop and rebase the
patch instead of forcing it.

You can check the target file blob with:

```bash
git -C /path/to/openai/codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
```

You can run the repository compatibility checker with:

```bash
scripts/check-upstream-compat.sh --ref rust-v0.131.0-alpha.18
```

## Quick Start

Download a package from the release page:

https://github.com/Never-error/codex-compact-rescue/releases

Choose the asset for your platform:

```text
macOS:   codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
Linux:   codex-compact-fallback-vX.Y.Z-linux-x64.tar.gz
Windows: codex-compact-fallback-vX.Y.Z-windows-x64.zip
```

The release packages contain scripts and the source patch. They do not contain
a patched Codex binary. Build the patched CLI locally, then install it into the
Codex Desktop app.

macOS example:

```bash
tar -xzf codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
cd codex-compact-fallback-vX.Y.Z-macos-universal

git clone https://github.com/openai/codex /tmp/openai-codex
git -C /tmp/openai-codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
scripts/build.sh --source-dir /tmp/openai-codex --out-dir dist/macos

APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"

scripts/install.sh \
  --codex-bin "$CODEX_BIN" \
  --patched-bin dist/macos/codex \
  --backup-dir "$APP_PATH/Contents/Resources" \
  --yes

scripts/verify.sh \
  --codex-bin "$CODEX_BIN" \
  --expect-marker present \
  --upstream-ref rust-v0.131.0-alpha.18
```

Linux uses the same `scripts/build.sh`, `scripts/install.sh`, and
`scripts/verify.sh` flow, but you must pass the Codex CLI path used by your
Linux installation.

Windows:

```powershell
Expand-Archive .\codex-compact-fallback-vX.Y.Z-windows-x64.zip
cd .\codex-compact-fallback-vX.Y.Z-windows-x64

git clone https://github.com/openai/codex C:\temp\openai-codex
git -C C:\temp\openai-codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
.\scripts\build.ps1 -SourceDir C:\temp\openai-codex -OutDir .\dist\windows

.\scripts\install.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -PatchedBin ".\dist\windows\codex.exe" -Yes
.\scripts\verify.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -ExpectMarker present -UpstreamRef rust-v0.131.0-alpha.18
```

## Install With An Agent

Use this prompt with a local coding agent that has access to the target machine:

```text
Project repository: https://github.com/Never-error/codex-compact-rescue

Install the Codex gpt-5.5 compact fallback patch on this machine.

Rules:
- Do not publish, upload, or leak any Codex binary.
- Detect the platform and installed Codex app path.
- Check that the OpenAI Codex checkout matches the documented compatibility target.
- Back up the existing bundled Codex CLI before replacing anything.
- Install only a patched bundled CLI that adds remote compact fallback behavior.
- Keep normal user turns on the configured default model.
- Use the fallback model only when remote compact fails.
- Verify the installed binary by hash and patch marker strings.
- Verify runtime behavior from local Codex logs without exposing session content.
- Provide rollback instructions and the backup path.

Expected behavior:
remote compact with gpt-5.5 fails
-> retry compact in the same turn with fallback model
-> install compacted history
-> emit context_compacted / thread compacted
-> continue the original turn
```

Agent checklist:

1. Detect the platform.
2. Locate the installed Codex app.
3. Locate the bundled Codex CLI.
4. Check patch compatibility with `git apply --check`.
5. Stop Codex Desktop before replacement.
6. Back up the existing bundled CLI with a timestamped filename.
7. Build or install the patched bundled CLI for the exact Codex version.
8. Replace only the bundled CLI file.
9. Preserve executable permissions.
10. Start Codex Desktop.
11. Verify patch marker strings.
12. Verify fallback runtime logs after a compact failure occurs.
13. Record the rollback command and backup path.

## Release Package Contract

Release assets are platform patcher packages, not complete modified Codex apps:

```text
codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
codex-compact-fallback-vX.Y.Z-linux-x64.tar.gz
codex-compact-fallback-vX.Y.Z-windows-x64.zip
checksums.txt
```

Each platform package provides:

```text
scripts/build.sh
scripts/install.sh
scripts/restore.sh
scripts/verify.sh
scripts/check-upstream-compat.sh
scripts/build.ps1
scripts/install.ps1
scripts/restore.ps1
scripts/verify.ps1
patches/
docs/
README.md
README.zh-CN.md
RELEASE_NOTES.md
```

The installer must back up the user's current bundled CLI before replacement.
The restore command must be able to put that backup back without requiring
network access.

## Build From Source

Apply the source patch to a local OpenAI Codex checkout and build the `codex`
CLI:

```bash
scripts/build.sh \
  --source-dir /path/to/openai/codex \
  --patch-file patches/openai-codex-compact-fallback.patch \
  --out-dir dist/macos
```

The build script runs:

```bash
git apply --check patches/openai-codex-compact-fallback.patch
git apply patches/openai-codex-compact-fallback.patch
cargo build -p codex-cli --bin codex --release
```

Windows users can use the PowerShell equivalent:

```powershell
.\scripts\build.ps1 -SourceDir C:\path\to\openai\codex -OutDir .\dist\windows
```

## macOS

Codex Desktop stores the bundled CLI here:

```bash
APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"
BACKUP_BIN="$APP_PATH/Contents/Resources/codex.backup-$(date +%Y%m%d-%H%M%S)"
```

Backup and replace:

```bash
scripts/install.sh \
  --codex-bin "$CODEX_BIN" \
  --patched-bin ./dist/macos/codex \
  --backup-dir "$APP_PATH/Contents/Resources" \
  --yes
```

Verify the installed binary:

```bash
scripts/verify.sh \
  --codex-bin "$CODEX_BIN" \
  --expect-marker present \
  --upstream-ref rust-v0.131.0-alpha.18
```

Rollback:

```bash
scripts/restore.sh --codex-bin "$CODEX_BIN" --backup "$BACKUP_BIN" --yes
```

## Windows

Use the PowerShell scripts with the Codex bundled CLI path for your installation:

```powershell
.\scripts\install.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -PatchedBin ".\dist\windows\codex.exe" -Yes
.\scripts\verify.ps1 -CodexBin "C:\Path\To\Codex\codex.exe"
.\scripts\restore.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -Backup "C:\Path\To\Codex\codex.exe.backup-YYYYMMDD-HHMMSS" -Yes
```

## Package A Release

Create platform patcher archives and a checksum file:

```bash
release/package.sh --version v0.1.1 --platform macos-universal --out-dir dist/release
release/package.sh --version v0.1.1 --platform linux-x64 --out-dir dist/release
release/package.sh --version v0.1.1 --platform windows-x64 --out-dir dist/release
```

## Runtime Verification

Patch presence, upstream compatibility, and patch trigger are separate checks.

Run the post-update health check:

```bash
scripts/verify.sh \
  --codex-bin /Applications/Codex.app/Contents/Resources/codex \
  --expect-marker any \
  --upstream-ref rust-v0.131.0-alpha.18
```

Check patch marker strings:

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

Check whether fallback compact was triggered:

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

Check whether ordinary compaction succeeded:

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

Check whether Codex is configured for HTTP Responses:

```bash
rg -n 'model_provider|supports_websockets|responses_websockets' "$HOME/.codex/config.toml"
```

## Repository Layout

```text
.
├── README.md
├── README.zh-CN.md
├── LICENSE
├── ROADMAP.md
├── docs/
│   ├── operations-zh.md
│   └── patched-binary-zh.md
├── patches/
│   ├── README.md
│   └── openai-codex-compact-fallback.patch
├── scripts/
│   ├── build.sh
│   ├── install.sh
│   ├── restore.sh
│   ├── verify.sh
│   ├── build.ps1
│   ├── install.ps1
│   ├── restore.ps1
│   └── verify.ps1
├── release/
│   ├── README.md
│   ├── RELEASE_NOTES.md
│   └── package.sh
└── tests/
```

`patches/`, `scripts/`, and `release/` contain the reproducible patch and
packaging workflow. `docs/` contains operator documentation.

## Safety

- Do not publish patched Codex application bundles.
- Do not commit local session JSONL files or SQLite logs.
- Do not expose tokens, account identifiers, private prompts, or full local
  conversation history.
- Keep fallback scoped to failed remote compact retry.
- Keep normal user turns on the configured default model.
- Always create a rollback backup before replacing a bundled CLI.

## License

MIT. See [LICENSE](LICENSE).
