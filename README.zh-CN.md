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

## 用 Agent 安装

把这段交给能访问目标机器的本地 coding agent：

```text
项目地址：https://github.com/Never-error/codex-compact-rescue

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

1. 识别平台。
2. 定位已安装的 Codex App。
3. 定位 bundled Codex CLI。
4. 替换前停止 Codex Desktop。
5. 用带时间戳的文件名备份当前 bundled CLI。
6. 为精确匹配的 Codex 版本构建或安装 patched bundled CLI。
7. 只替换 bundled CLI 文件。
8. 保留可执行权限。
9. 启动 Codex Desktop。
10. 验证补丁 marker 字符串。
11. 等 compact failure 发生后验证 fallback runtime 日志。
12. 记录回滚命令和备份路径。

## Release 包契约

Release 资产是平台 patcher 包，不是修改后的 Codex App 整包：

```text
codex-compact-fallback-vX.Y.Z.patch
codex-compact-fallback-macos-universal.tar.gz
codex-compact-fallback-windows-x64.zip
codex-compact-fallback-linux-x64.tar.gz
checksums.txt
RELEASE_NOTES.md
```

每个平台包提供：

```text
install
restore
verify
build
patches/
docs/
README.md
README.zh-CN.md
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

备份并替换：

```bash
scripts/install.sh \
  --codex-bin "$CODEX_BIN" \
  --patched-bin ./dist/macos/codex \
  --backup-dir "$APP_PATH/Contents/Resources" \
  --yes
```

验证安装后的 binary：

```bash
scripts/verify.sh --codex-bin "$CODEX_BIN"
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
release/package.sh --version v0.1.0 --platform macos-universal --out-dir dist/release
release/package.sh --version v0.1.0 --platform linux-x64 --out-dir dist/release
release/package.sh --version v0.1.0 --platform windows-x64 --out-dir dist/release
```

## 运行时验证

补丁存在和补丁触发是两个不同检查。

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
