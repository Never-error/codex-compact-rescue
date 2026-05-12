# Codex gpt-5.5 Compact Fallback Patch

Unofficial patch workflow for making Codex Desktop `gpt-5.5` remote compact
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

> This repository does not publish patched Codex application binaries. The
> intended release shape is a patcher-style package: source patch, installer,
> verifier, rollback script, and checksums.

## Quick Start For Agents

Use this prompt when another coding agent or model needs to install or maintain
the patch on a local machine:

```text
Install the Codex gpt-5.5 compact fallback patch on this machine.

Rules:
- Do not publish, upload, or leak any Codex binary.
- Detect the platform and installed Codex app path.
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

1. Confirm the installed Codex app path.
2. Confirm the bundled CLI path.
3. Stop Codex Desktop before replacement.
4. Create a timestamped backup of the original bundled CLI.
5. Build or obtain the patched bundled CLI for the exact Codex version.
6. Replace only the bundled CLI file.
7. Preserve executable permissions.
8. Start Codex Desktop.
9. Verify patch marker strings.
10. Verify fallback runtime logs after a compact failure occurs.

## macOS Install Shape

Expected local paths:

```bash
APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"
BACKUP_BIN="$APP_PATH/Contents/Resources/codex.backup-$(date +%Y%m%d-%H%M%S)"
```

Backup and replace:

```bash
cp "$CODEX_BIN" "$BACKUP_BIN"
install -m 0755 ./dist/macos/codex "$CODEX_BIN"
```

Verify the installed binary:

```bash
shasum -a 256 "$CODEX_BIN" "$BACKUP_BIN"
strings "$CODEX_BIN" | rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

Rollback:

```bash
install -m 0755 "$BACKUP_BIN" "$CODEX_BIN"
```

## Runtime Verification

Patch presence and patch trigger are different checks.

Patch presence:

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

Fallback trigger:

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

Ordinary compact success:

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

Transport check for HTTP Responses:

```bash
rg -n 'model_provider|supports_websockets|responses_websockets' "$HOME/.codex/config.toml"
```

## Release Shape

The target release format is platform patcher packages, not complete modified
Codex apps:

```text
codex-compact-fallback-vX.Y.Z.patch
codex-compact-fallback-macos-universal.tar.gz
codex-compact-fallback-windows-x64.zip
codex-compact-fallback-linux-x64.tar.gz
checksums.txt
RELEASE_NOTES.md
```

Each platform package should contain:

```text
install
restore
verify
build
patches/
docs/
```

## Repository Layout

```text
.
├── README.md
├── LICENSE
├── docs/
│   ├── operations-zh.md
│   └── patched-binary-zh.md
└── .gitignore
```

`docs/superpowers/` has been intentionally removed. This repository should read
like an open-source patch project, not a record of internal agent planning.

## Current Status

This repository is being shaped into a patcher-style project. Release-grade
patch content still needs to be added under `patches/`, and platform installer
scripts still need to be added under `scripts/`.

Until those assets exist, agents should not claim this repository is a
one-command installer. The README currently defines the behavior contract,
installation shape, verification workflow, release shape, and safety rules.

## Safety Rules

- Do not publish patched Codex application binaries.
- Do not include local tokens, account identifiers, raw session contents, or
  private project prompts in public artifacts.
- Treat `~/.codex/logs_2.sqlite` and `~/.codex/sessions/**/*.jsonl` as local
  evidence sources, not files to commit.
- Prefer fallback only for failed remote compact retry, not for normal user
  turns.
- Keep backup and rollback instructions next to any local binary replacement.

## Chinese / 中文

本项目专注于一个非官方补丁流程：让 Codex Desktop 在 `gpt-5.5` remote compact
失败时，可以在同一个 turn 内自动 fallback 到较小模型重试，并继续原对话。

目标行为：

```text
remote compact with gpt-5.5 fails
-> same turn 内部切到 fallback model
-> retry compact
-> install compacted history
-> emit context_compacted / thread compacted
-> continue 原 turn
```

这个仓库不发布修改后的 Codex App 整包，也不发布 patched Codex binary。目标发布
形态是 patcher 包：源码补丁、安装脚本、验证脚本、回滚脚本和校验文件。

### 给 Agent 的快速部署提示

把这段交给本地 coding agent：

```text
在这台机器上安装 Codex gpt-5.5 compact fallback patch。

规则：
- 不要发布、上传或泄漏任何 Codex binary。
- 自动识别平台和已安装的 Codex App 路径。
- 替换任何文件前，必须备份现有 bundled Codex CLI。
- 只安装带 remote compact fallback 行为的 patched bundled CLI。
- 正常用户 turn 继续使用当前默认模型。
- 只有 remote compact 失败时才使用 fallback model。
- 用 hash 和补丁 marker 字符串验证安装结果。
- 用本地 Codex 日志验证运行行为，不暴露 session 内容。
- 输出回滚说明和备份路径。

期望行为：
remote compact with gpt-5.5 fails
-> same turn 内部切到 fallback model
-> retry compact
-> install compacted history
-> emit context_compacted / thread compacted
-> continue 原 turn
```

Agent 执行清单：

1. 确认已安装 Codex App 路径。
2. 确认 bundled CLI 路径。
3. 替换前退出 Codex Desktop。
4. 为原 bundled CLI 创建带时间戳的备份。
5. 为精确匹配的 Codex 版本构建或取得 patched bundled CLI。
6. 只替换 bundled CLI 文件。
7. 保留可执行权限。
8. 启动 Codex Desktop。
9. 验证补丁 marker 字符串。
10. 等 compact failure 发生后验证 fallback runtime 日志。

### macOS 安装形态

```bash
APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"
BACKUP_BIN="$APP_PATH/Contents/Resources/codex.backup-$(date +%Y%m%d-%H%M%S)"
```

备份并替换：

```bash
cp "$CODEX_BIN" "$BACKUP_BIN"
install -m 0755 ./dist/macos/codex "$CODEX_BIN"
```

验证：

```bash
shasum -a 256 "$CODEX_BIN" "$BACKUP_BIN"
strings "$CODEX_BIN" | rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

回滚：

```bash
install -m 0755 "$BACKUP_BIN" "$CODEX_BIN"
```

### 运行时验证

补丁存在和补丁触发是两件事。

补丁是否存在：

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

fallback 是否触发：

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

普通 compact 是否成功：

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

### 当前状态

这个仓库正在整理成 patcher 风格项目。后续还需要补：

- `patches/`：真实源码级补丁。
- `scripts/`：各平台 install / restore / verify / build 脚本。
- release asset：各平台 patcher 包、checksum、release notes。

在这些内容补齐前，不能声称这是一个一键安装器。当前 README 的作用是让其他
agent/模型快速理解补丁目标、安装边界、验证方式和安全规则。

## License

MIT. See [LICENSE](LICENSE).
