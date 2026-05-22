# Codex gpt-5.5 Compact Fallback Patch

语言：[English](README.md) | 简体中文

项目地址：https://github.com/Never-error/codex-compact-rescue

这个项目提供 Codex Desktop `gpt-5.5` remote compact 失败的源码补丁、安装脚本、
验证脚本和 release 打包流程。

补丁目标是在 Codex 自己的 compact 出错路径里完成恢复：当 `gpt-5.5` remote
compact 失败时，同一个 turn 内切换到 fallback model 重试，安装 compacted
history，发出正常 compacted-thread 事件，然后继续原对话。

```text
remote compact with gpt-5.5 fails
-> same turn 内部切到 fallback model
-> retry compact
-> install compacted history
-> emit context_compacted / thread compacted
-> continue 原 turn
```

本仓库面向 patcher 风格发布，不分发修改后的 Codex App 整包。

## 兼容性

当前源码补丁：

- 补丁文件：`patches/openai-codex-compact-fallback.patch`
- 上游目标：`openai/codex` 的 `codex-rs/core/src/compact_remote.rs`
- 检查日期：2026-05-23
- 本机观测到的 Codex Desktop bundled CLI：`codex-cli 0.133.0-alpha.1`

已验证的上游兼容性：

| 上游 ref | 目标 blob | 结果 |
| --- | --- | --- |
| `main` | `30d1e5f0e84129ac5d3da3f327c8a24c6a199717` | `patch_applies_with_drift` |
| `rust-v0.133.0` | `c7ba1a314f611d59a0181403115a051f2ff32b3b` | `patch_applies_with_drift` |
| `rust-v0.133.0-alpha.1` | `c7ba1a314f611d59a0181403115a051f2ff32b3b` | `patch_applies_with_drift` |
| `rust-v0.131.0-alpha.18` | `cc31d50b13268417fa34d8262a7c3682cda8912e` | `patch_applies` |
| `rust-v0.130.0` | `35b8a01fc32fff7944b75670acbd5e33dff161af` | `patch_applies_with_drift` |

构建前必须先对你的 OpenAI Codex checkout 运行 `git apply --check`。如果上游
compact 实现已经变化，应停止并重新 rebase 补丁，不要强行应用。

可以用下面的命令检查目标文件 blob：

```bash
git -C /path/to/openai/codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
```

也可以运行仓库自带的兼容性检查：

```bash
scripts/check-upstream-compat.sh --ref rust-v0.133.0-alpha.1
```

## 快速开始

从 release 页面下载平台包：

https://github.com/Never-error/codex-compact-rescue/releases

按平台选择资产：

```text
macOS:   codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
Linux:   codex-compact-fallback-vX.Y.Z-linux-x64.tar.gz
Windows: codex-compact-fallback-vX.Y.Z-windows-x64.zip
```

release 包只包含脚本和源码补丁，不包含 patched Codex binary。需要先在本机构建
patched CLI，再安装到 Codex Desktop App 内。

macOS 示例：

```bash
tar -xzf codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
cd codex-compact-fallback-vX.Y.Z-macos-universal

git clone https://github.com/openai/codex /tmp/openai-codex
git -C /tmp/openai-codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
scripts/build.sh --source-dir /tmp/openai-codex --out-dir dist/macos

APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"

scripts/patch-macos-codex-app.sh \
  --app-path "$APP_PATH" \
  --patched-bin dist/macos/codex \
  --upstream-ref rust-v0.133.0-alpha.1 \
  --move-bundle-backups \
  --yes

scripts/verify.sh \
  --codex-bin "$CODEX_BIN" \
  --expect-marker present \
  --upstream-ref rust-v0.133.0-alpha.1
```

Linux 使用同一套 `scripts/build.sh`、`scripts/install.sh` 和
`scripts/verify.sh` 流程，但需要传入你本机 Linux 安装实际使用的 Codex CLI 路径。

Windows：

```powershell
Expand-Archive .\codex-compact-fallback-vX.Y.Z-windows-x64.zip
cd .\codex-compact-fallback-vX.Y.Z-windows-x64

git clone https://github.com/openai/codex C:\temp\openai-codex
git -C C:\temp\openai-codex rev-parse HEAD:codex-rs/core/src/compact_remote.rs
.\scripts\build.ps1 -SourceDir C:\temp\openai-codex -OutDir .\dist\windows

.\scripts\install.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -PatchedBin ".\dist\windows\codex.exe" -Yes
.\scripts\verify.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -ExpectMarker present -UpstreamRef rust-v0.133.0-alpha.1
```

## 用 Agent 安装

把这段交给能访问目标机器的本地 coding agent：

```text
项目地址：https://github.com/Never-error/codex-compact-rescue

在这台机器上安装 Codex gpt-5.5 compact fallback patch。

规则：
- 不要发布、上传或泄漏任何 Codex binary。
- 自动识别平台和已安装的 Codex App 路径。
- 检查 OpenAI Codex checkout 是否匹配文档里的兼容目标。
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

1. 识别平台。
2. 定位已安装的 Codex App。
3. 定位 bundled Codex CLI。
4. 用 `git apply --check` 检查补丁兼容性。
5. 替换前停止 Codex Desktop。
6. 用带时间戳的文件名备份当前 bundled CLI。
7. 为精确匹配的 Codex 版本构建或安装 patched bundled CLI。
8. 只替换 bundled CLI 文件。
9. 保留可执行权限。
10. 启动 Codex Desktop。
11. 验证补丁 marker 字符串。
12. 等 compact failure 发生后验证 fallback runtime 日志。
13. 记录回滚命令和备份路径。

## Release 包契约

Release 资产是平台 patcher 包，不是修改后的 Codex App 整包：

```text
codex-compact-fallback-vX.Y.Z-macos-universal.tar.gz
codex-compact-fallback-vX.Y.Z-linux-x64.tar.gz
codex-compact-fallback-vX.Y.Z-windows-x64.zip
checksums.txt
```

每个平台包提供：

```text
scripts/build.sh
scripts/install.sh
scripts/patch-macos-codex-app.sh
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

安装器必须在替换前备份用户当前 bundled CLI。回滚命令必须不依赖网络即可恢复备份。

## 从源码构建

把源码补丁应用到本地 OpenAI Codex checkout，并构建 `codex` CLI：

```bash
scripts/build.sh \
  --source-dir /path/to/openai/codex \
  --patch-file patches/openai-codex-compact-fallback.patch \
  --out-dir dist/macos
```

构建脚本会执行：

```bash
git apply --check patches/openai-codex-compact-fallback.patch
git apply patches/openai-codex-compact-fallback.patch
cargo build -p codex-cli --bin codex --release
```

脚本既可以接收上游仓库根目录，也可以接收 `codex-rs/` workspace 目录。
如果 Rust 构建时 LiveKit WebRTC 预编译包下载超时，可以先手动下载并解压匹配
平台的包，再把 `LK_CUSTOM_WEBRTC` 指向解压后的 triple 目录：

```bash
export LK_CUSTOM_WEBRTC=/path/to/mac-arm64-release
scripts/build.sh \
  --source-dir /path/to/openai/codex \
  --patch-file patches/openai-codex-compact-fallback.patch \
  --out-dir dist/macos
```

Windows 用户可以使用 PowerShell 版本：

```powershell
.\scripts\build.ps1 -SourceDir C:\path\to\openai\codex -OutDir .\dist\windows
```

## macOS

Codex Desktop 的 bundled CLI 路径：

```bash
APP_PATH="/Applications/Codex.app"
CODEX_BIN="$APP_PATH/Contents/Resources/codex"
BACKUP_BIN="$APP_PATH/Contents/Resources/codex.backup-$(date +%Y%m%d-%H%M%S)"
```

当前 Codex Desktop 对 App bundle 签名检查更严格。安装脚本默认拒绝修改
`/Applications/Codex.app`，必须显式选择 macOS App 模式：

- `--macos-app-mode no-resign`：只替换 bundled CLI，不重签外层 App；这样会让
  `CodeResources` 与文件内容不一致。
- `--macos-app-mode adhoc-resign`：替换 bundled CLI 后对外层 `.app` 做 ad-hoc
  签名；GUI 可能因为不再满足 OpenAI designated requirement 而启动失败。

在作为日常 App 使用前，应先在你的 Codex Desktop 精确版本上验证该模式，并保留
官方 App 恢复路径。

macOS Codex Desktop 推荐使用 App 感知的封装脚本：

```bash
scripts/patch-macos-codex-app.sh \
  --app-path "$APP_PATH" \
  --patched-bin ./dist/macos/codex \
  --upstream-ref rust-v0.133.0-alpha.1 \
  --move-bundle-backups \
  --yes
```

这个脚本内部使用 `scripts/install.sh --macos-app-mode no-resign`，并把这次实际
踩过的检查流程固化进去：

- 当前 bundled CLI 会备份到 App bundle 外部；
- 可选把 `Contents/Resources/codex.backup-*` 旧备份搬出 App bundle，避免影响签名
  校验和官方更新；
- 检查 patched binary 与当前安装的 `codex-cli` 版本一致；
- 替换前后都检查 fallback marker 字符串；
- 记录替换前后的签名状态，但不对 App 做 ad-hoc re-sign；
- 检查运行中的 `app-server` 是否还在使用旧 inode；
- 输出可直接执行的 rollback 命令。

如果是在外部终端执行，可以在 `--yes` 前加 `--quit-app`，让脚本先退出 Codex 和
Sparkle updater 进程。如果是在 Codex Desktop 自己里面执行，不要加 `--quit-app`，
安装完成后手动重启 Codex。

底层安装脚本仍然可用于非 macOS App bundle 的场景：

```bash
scripts/install.sh \
  --codex-bin "$CODEX_BIN" \
  --patched-bin ./dist/macos/codex \
  --backup-dir "$APP_PATH/Contents/Resources" \
  --macos-app-mode no-resign \
  --yes
```

no-resign 替换完成后，`codesign --verify --deep --strict /Applications/Codex.app`
预期会报告 `Contents/Resources/codex` sealed resource invalid。不要使用
`--macos-app-mode adhoc-resign`，除非你已经验证当前 Codex Desktop 版本在 ad-hoc
签名后仍能正常打开。

验证安装后的 binary：

```bash
scripts/verify.sh \
  --codex-bin "$CODEX_BIN" \
  --expect-marker present \
  --upstream-ref rust-v0.133.0-alpha.1
```

回滚：

```bash
scripts/restore.sh --codex-bin "$CODEX_BIN" --backup "$BACKUP_BIN" --yes
```

## Windows

使用 PowerShell 脚本，并传入本机 Codex bundled CLI 路径：

```powershell
.\scripts\install.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -PatchedBin ".\dist\windows\codex.exe" -Yes
.\scripts\verify.ps1 -CodexBin "C:\Path\To\Codex\codex.exe"
.\scripts\restore.ps1 -CodexBin "C:\Path\To\Codex\codex.exe" -Backup "C:\Path\To\Codex\codex.exe.backup-YYYYMMDD-HHMMSS" -Yes
```

## 打包 Release

生成平台 patcher 归档和 checksum 文件：

```bash
release/package.sh --version v0.1.1 --platform macos-universal --out-dir dist/release
release/package.sh --version v0.1.1 --platform linux-x64 --out-dir dist/release
release/package.sh --version v0.1.1 --platform windows-x64 --out-dir dist/release
```

## 运行时验证

补丁存在、上游兼容性和补丁触发是三个不同检查。

运行升级后体检：

```bash
scripts/verify.sh \
  --codex-bin /Applications/Codex.app/Contents/Resources/codex \
  --expect-marker any \
  --upstream-ref rust-v0.133.0-alpha.1
```

检查补丁 marker 字符串：

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

检查 fallback compact 是否触发：

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

检查普通 compact 是否成功：

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

检查 Codex 是否配置为 HTTP Responses：

```bash
rg -n 'model_provider|supports_websockets|responses_websockets' "$HOME/.codex/config.toml"
```

## 仓库结构

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
│   ├── patch-macos-codex-app.sh
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

`patches/`、`scripts/` 和 `release/` 包含可复现的补丁和打包流程。`docs/` 包含
操作文档。

## 安全边界

- 不发布 patched Codex App 整包。
- 不提交本地 session JSONL 文件或 SQLite 日志。
- 不暴露 token、账号标识、私有 prompt 或完整本地对话历史。
- fallback 只作用于 failed remote compact retry。
- 正常用户 turn 继续使用当前默认模型。
- 替换 bundled CLI 前必须创建可回滚备份。

## License

MIT. See [LICENSE](LICENSE).
