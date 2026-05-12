# Codex gpt-5.5 Compact Fallback Patch 操作说明

本文记录本项目主线：替换 Codex Desktop 内置的 `codex` CLI，让 `gpt-5.5`
remote compact 失败时在同一个 turn 内 fallback 到较小模型重试。命令默认在
macOS 本机执行，并使用 `$HOME` 避免暴露个人路径。

## 1. 问题现象

典型失败表现是 Codex 在长会话自动压缩时断流：

```text
stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses/compact)
```

如果 WebSocket 链路也不稳定，还可能先看到多次重连：

```text
Reconnecting... 2/5
Reconnecting... 3/5
Reconnecting... 4/5
Reconnecting... 5/5
timeout waiting for child process to exit
```

这个项目关注的是 Codex 自身 compact 出错点的 recoverable fallback：尽量保持原
thread，不把用户迁移到新会话。

## 2. 补丁目标行为

目标不是外部救援，而是内部补丁：

```text
remote compact with gpt-5.5 fails
-> same turn 内部切到 fallback model
-> retry compact
-> install compacted history
-> emit context_compacted / thread compacted
-> continue 原 turn
```

补丁只应该影响 compact fallback 路径，不应该把正常用户 turn 都切到小模型。

## 3. 推荐 HTTP Responses 配置

如果 WebSocket 重试影响稳定性，可以把 Codex 固定到 HTTP Responses API：

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

验证配置：

```bash
rg -n '^(model_provider|model = )|supports_websockets|responses_websockets|responses_websockets_v2|\[model_providers\.openai_http\]' "$HOME/.codex/config.toml"
```

## 4. 判断是否真的发生过 compact

普通成功压缩会写入 session JSONL：

```bash
rg -n '"context_compacted"|type":"compacted"' "$HOME/.codex/sessions"
```

如果这个命令有输出，说明 session 历史里存在成功压缩边界。它只能证明压缩发生过，不能证明 fallback 补丁路径触发过。

## 5. 判断 fallback 补丁是否触发

fallback 路径应当留下更具体的日志，例如：

```text
retrying remote compaction with fallback model
remote compaction failed
```

可以从 SQLite 日志检查 compact 模块：

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
   order by id desc
   limit 50;"
```

结论口径要区分清楚：

- 有 `context_compacted`：普通压缩成功发生过。
- 有 fallback 日志：fallback compact 模型路径触发过。
- 只有 HTTP Responses 请求：只能说明 WebSocket 绕过配置生效，不能说明 compact fallback 触发。

## 6. 本机 patched binary 安装形态

本机补丁的安装点是 Codex Desktop bundled CLI：

```bash
/Applications/Codex.app/Contents/Resources/codex
```

替换前必须备份：

```bash
cp /Applications/Codex.app/Contents/Resources/codex \
  /Applications/Codex.app/Contents/Resources/codex.backup-$(date +%Y%m%d-%H%M%S)
```

验证补丁是否仍在当前 Codex App 内：

```bash
shasum -a 256 /Applications/Codex.app/Contents/Resources/codex
strings /Applications/Codex.app/Contents/Resources/codex | rg 'retrying remote compaction with fallback model|gpt-5.4-mini|gpt-5.5'
```

验证补丁是否真正触发，不能只看普通 `context_compacted`。应优先看 compact 模块
是否出现 fallback 日志：

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" \
  "select id, datetime(timestamp, 'unixepoch'), level, target, feedback_log_body
   from logs
   where target = 'codex_core::compact_remote'
     and feedback_log_body like '%fallback model%'
   order by id desc
   limit 20;"
```

公开仓库不发布这个替换后的二进制，只记录行为、验证方法和可复现实现计划。

## 7. 附录：CLI 原地救援命令形态

CLI 原地救援不是当前项目主线，只作为不替换 binary 时的备选方案。

维护 turn 应当使用较小模型，并明确禁止继续项目工作：

```bash
codex exec resume <thread_id> \
  "[codex-compact-rescue] This is a maintenance turn, not task execution. Do not run tools. Do not update, complete, or create any goal. Do not continue project work. Reply only: compact-ok. If the system triggers automatic context compaction, wait for compaction to finish before replying." \
  -m gpt-5.4-mini \
  -c 'model_reasoning_effort="medium"' \
  --disable goals \
  --skip-git-repo-check \
  --json
```

自动化实现时必须默认 dry-run。只有显式 `--execute` 才能真正恢复 thread。

## 8. 外部救援自动化的安全门

实现 CLI 救援层时至少要有这些保护：

- 按 thread 加锁，避免两个救援进程同时写同一会话。
- 判断 session tail，发现还有未结束 turn 时跳过。
- 记录已处理 log id，避免同一次失败被重复救援。
- 每个 thread 设置冷却时间，避免短时间反复触发。
- 救援后必须看到新的 `context_compacted` 才能标记成功。
- 维护 turn 必须 `--disable goals`，避免污染用户原本的 Goal 状态。

## 9. 回滚和升级

如果采用应用内补丁或本地二进制替换，必须保留原始文件备份。升级 Codex App 后应重新验证：

```bash
shasum -a 256 /Applications/Codex.app/Contents/Resources/codex
strings /Applications/Codex.app/Contents/Resources/codex | rg 'fallback model|gpt-5.4-mini|gpt-5.5'
```

如果 hash 变化或关键字符串不存在，说明升级可能覆盖了本地补丁，需要重新评估补丁是否仍适配新版本。

## 10. 不要提交的内容

公开仓库不要包含：

- `~/.codex/logs_2.sqlite`
- `~/.codex/sessions/**/*.jsonl`
- OAuth token、GitHub token、OpenAI token
- 私有项目 prompt、完整会话、内部路径截图
- 修改后的 Codex App 二进制

公开内容应保留为：实现计划、通用操作说明、测试样例和不含敏感信息的工具代码。
