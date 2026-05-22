# gpt-5.5 Compact Fallback Patched Binary

这份文档专门描述本项目的主线：替换 Codex Desktop 内置的 `codex` CLI，让
`gpt-5.5` remote compact 失败时在同一个 turn 内部自动 fallback 到较小模型重试。

## 1. 补丁目标

目标行为：

```text
remote compact with gpt-5.5 fails
-> same turn 内部切到 fallback model
-> retry compact
-> install compacted history
-> emit context_compacted / thread compacted
-> continue 原 turn
```

这不是新建会话，也不是让用户手动 `/compact`，也不是外部维护 turn。补丁应该尽量
接近 Codex 自带自动压缩的体验。

## 2. 本机安装形态

macOS Codex Desktop 的 bundled CLI 位于：

```bash
/Applications/Codex.app/Contents/Resources/codex
```

安装补丁前必须备份原始文件。macOS Codex Desktop 推荐使用封装脚本，让备份保存在
App bundle 外部，并自动完成版本、marker、签名状态和运行态检查：

```bash
APP_PATH="/Applications/Codex.app"

scripts/patch-macos-codex-app.sh \
  --app-path "$APP_PATH" \
  --patched-bin ./dist/macos/codex \
  --upstream-ref rust-v0.133.0-alpha.1 \
  --move-bundle-backups \
  --yes
```

脚本内部采用 no-resign 替换，不对 Codex.app 做 ad-hoc re-sign。公开仓库不发布
patched binary，只记录补丁行为、验证方法和可复现实现计划。

## 3. 验证补丁是否还在

查看 hash：

```bash
shasum -a 256 /Applications/Codex.app/Contents/Resources/codex
```

查看补丁字符串：

```bash
strings /Applications/Codex.app/Contents/Resources/codex | \
  rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

如果 Codex App 升级后 hash 变化，或者关键字符串消失，说明补丁可能被覆盖。

## 4. 验证补丁是否触发

普通 `context_compacted` 只能证明压缩成功发生过，不能证明 fallback 路径触发过。
判断 fallback 是否触发，要看 compact 模块日志：

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

判断普通压缩是否成功：

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

结论口径：

- 看到 `context_compacted`：说明普通压缩边界存在。
- 看到 `retrying remote compaction with fallback model`：说明补丁 fallback 路径触发。
- 两者都看到，并且原 turn 继续：说明补丁行为符合目标。

## 5. HTTP Responses 配置

如果 Codex 反复 WebSocket reconnect，可以固定到 HTTP Responses：

```toml
model_provider = "openai_http"

[model_providers.openai_http]
name = "OpenAI"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false

[features]
responses_websockets = false
responses_websockets_v2 = false
```

验证：

```bash
rg -n '^(model_provider|model = )|supports_websockets|responses_websockets|responses_websockets_v2|\[model_providers\.openai_http\]' "$HOME/.codex/config.toml"
```

这项配置只解决 WebSocket 传输重试问题，不等于 compact fallback 补丁已经触发。

## 6. 升级和回滚

Codex App 升级可能覆盖 bundled CLI。升级后要重新验证：

```bash
shasum -a 256 /Applications/Codex.app/Contents/Resources/codex
strings /Applications/Codex.app/Contents/Resources/codex | rg 'fallback model|gpt-5.4-mini|gpt-5.5'
```

回滚步骤：

1. 退出 Codex Desktop。
2. 把备份文件恢复到 `/Applications/Codex.app/Contents/Resources/codex`。
3. 重新打开 Codex Desktop。
4. 再跑 hash 和字符串验证。

## 7. 不发布的内容

公开仓库不要放：

- patched Codex binary
- `~/.codex/logs_2.sqlite`
- `~/.codex/sessions/**/*.jsonl`
- OAuth token、GitHub token、OpenAI token
- 私有项目 prompt、完整会话、内部路径截图

公开内容应聚焦补丁机制、验证方法、可复现实现说明和风险边界。
