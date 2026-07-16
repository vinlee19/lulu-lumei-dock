# Eureka 设计文档

> 由批准的实现计划整理（2026-06-10）。完整计划含风险清单见
> `~/.claude/plans/macos-1-claude-code-wiggly-globe.md`。

## 目标

1. **灵动岛通知**：Claude Code / Codex CLI 任务运行中顶部常驻小胶囊（任务数+计时）；
   完成/等待确认/出错时展开卡片（简述+耗时），数秒自动收起、悬停暂停、点击详情；无任务完全隐藏。
2. **余额**：本地用量统计（今日/本周 token+估算费用）+ 订阅限额余量（5h/周窗口）。
3. **菜单栏**：历史、用量/限额面板、设置、hooks 一键装卸。
4. **对用户友好**：不抢焦点、动画流畅、多任务合并不刷屏、过期积压事件不弹窗、中文 UI。

## 架构

```
Claude Code hooks ──┐                            ┌─ 灵动岛 NSPanel（compact/expanded）
Codex notify ───────┤→ eureka-relay → spool 目录  │
                    │   (原子写 JSON)     ↓        ├─ NSStatusItem + NSPopover
Codex rollout tail ─┘               SpoolConsumer │   (历史/用量/限额/设置)
Claude transcript 扫描 ────────────→ TaskStore 状态机
Codex rollout token_count ─────────→ UsageEngine / RateLimitProviders
                                         ↓
                                   SQLite (历史/用量/扫描状态)
```

### 关键决策

- **事件传输 = spool 目录**：relay 写 `tmp/` 后 rename 原子落入
  `~/Library/Application Support/Eureka/events/`，app 用 DispatchSource 监听。
  app 没起时事件天然排队；重启可重放；`ls`+`cat` 即可调试。
  **超过 5 分钟的积压事件只入历史/用量，不触发岛动画。**
- **自研 NSPanel 灵动岛**（不用 DynamicNotchKit——它是一次性弹出模型，没有常驻 compact 态）：
  panel 固定 expanded 最大尺寸，展开/收起全靠 SwiftUI spring 动画 + hitTest 让透明区点击穿透。
- **零第三方依赖**；SQLite 用系统 libsqlite3 + 薄封装，可直接 `sqlite3` 查库调试。
- **relay 稳定路径**：hooks/notify 配置永远只写
  `~/Library/Application Support/Eureka/bin/eureka-relay`，app 启动按 hash 同步，升级不断链。
- **relay 硬约束**：永远 exit 0、stdout 绝对静默（UserPromptSubmit 的 stdout 会注入模型上下文）、
  <50ms、stdin 限读 1MB。
- **Claude OAuth usage 接口（非官方）默认关闭、opt-in**，任何失败 → 返回 nil → UI 整块隐藏。
- **Keychain 经 `/usr/bin/security` 子进程读取**（避开 ad-hoc 重签后 ACL 反复弹窗）。

## 模块（SwiftPM targets，依赖单向：app → {Ingest,Usage,Install} → Store → Kit）

| Target | 职责 |
|---|---|
| EurekaKit | 纯领域层：TaskEvent/AgentTask/TaskStore 状态机/IslandState 投影/IslandGeometry 纯函数 |
| EurekaStore | SQLite + 三仓库（task_history / usage_records / scan_state） |
| EurekaIngest | SpoolConsumer、ClaudeHookDecoder、CodexRolloutTailer、ClaudeErrorSniffer |
| EurekaUsage | 双 transcript 扫描器（增量+去重）、PricingTable、RateLimitProvider 协议与两实现 |
| EurekaInstall | settings.json 深合并 / config.toml 行级编辑、备份、diff 预览、装卸状态 |
| eureka (app) | AppKit 外壳：灵动岛 NSPanel、NSStatusItem+Popover、设置、RelaySyncer |
| eureka-relay | claude-hook / codex-notify / inject 三子命令，写 spool |
| eureka-tests | 自建断言 harness（CLT 无 XCTest） |

## 已验证的数据源格式（本机真实样例核对）

- **Claude transcript** `~/.claude/projects/<encoded>/*.jsonl`：
  - assistant 行：`message.usage{input_tokens,output_tokens,cache_creation_input_tokens,
    cache_read_input_tokens,cache_creation{ephemeral_1h_input_tokens,ephemeral_5m_input_tokens}}`、
    `message.model`、`requestId`、`sessionId`、`isSidechain`；**(requestId,message.id) 流式重复严重，
    必须跨文件持久化去重**（resume/fork 会把旧行复制进新文件）
  - `{"type":"ai-title","aiTitle":"...","sessionId":"..."}` 现成任务标题
  - `{"type":"system","subtype":"turn_duration","durationMs":...}` 官方耗时（可校验 hook 配对计时）
  - API 错误行：`message.model=="<synthetic>"`、`isApiErrorMessage:true`、`apiErrorStatus`、`error`
- **Codex rollout** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`（行 = `{timestamp,type,payload}`）：
  - `session_meta`（id/cwd/cli_version）、`event_msg/task_started`（turn_id、started_at 秒级 epoch）、
    `event_msg/user_message`、`event_msg/task_complete`（turn_id、last_agent_message）、`turn_aborted`
  - `event_msg/token_count`：`info.total_token_usage{input_tokens,cached_input_tokens,output_tokens,
    reasoning_output_tokens,total_tokens}` + `rate_limits{primary{used_percent,window_minutes=300,
    resets_at},secondary{...=10080},plan_type}` → 限额零网络请求；用量按相邻差值法记账
- **Claude hooks**（官方文档核对）：UserPromptSubmit(prompt)/Stop/Notification(message,
  notification_type: permission_prompt|idle_prompt|...)/SessionStart(source)/SessionEnd(reason)/
  PostToolUse；stdin JSON 含 session_id/transcript_path/cwd
- **Codex 外部 notify 仅 `agent-turn-complete`**（approval 不触发外部 notify）→
  rollout tailer 为主事件源，notify 仅低延迟冗余（按 turn_id 去重）
- **opencode 单一 SQLite 库** `~/.local/share/opencode/opencode.db`（WAL，**只读**打开，绝不写）：
  - `session`(id,parent_id,directory,title,agent,model,cost,tokens_input/output/reasoning/
    cache_read/cache_write,time_created/time_updated **毫秒**)——顶层会话（parent_id 空）进浏览列表，
    子会话=子 agent。会话/技能/agent 路径走 XDG（`~/.config/opencode/{skills,agents}`），非 ~/Library。
  - `message.data`(JSON) assistant：`tokens{input,output,reasoning,cache{read,write}}`、`time{created,
    completed}`、`modelID/providerID`、`finish`——用量扫描按 message.rowid 水位增量、只结算已完成消息
    （无跨文件去重需求，reasoning 计入 output 侧）
  - `event`(append-only；rowid 单调)：`session.created.1`/`session.updated.1`/`message.updated.1`/
    `message.part.updated.1`，`data` 含 `sessionID` + `info`/`part`。**opencode 无 hook/notify 子进程回调**，
    实时靠尾随 event 表（首扫定基线不重放；子会话事件按 session.parent_id 过滤）。**无订阅限额概念**（BYO provider）

## 任务状态机

- key = `source:sessionId`；状态 `running / waiting(permission|idle) / finished(success|error|interrupted)`
- Claude：UserPromptSubmit→running；Notification→waiting；PostToolUse 心跳→waiting 复位 running；
  Stop→finished(success)（ErrorSniffer 嗅 transcript 尾部可升级为 error）；SessionEnd→清理/interrupted
- Codex：task_started→running；task_complete→finished(success)；turn_aborted→interrupted；error→error
- 兜底：running 超 4h 无心跳 → interrupted（防 hook 丢失泄漏）

## 里程碑

M0 骨架 → M1 端到端最小链路（relay→spool→状态栏计数）→ M2 真实 Claude hooks →
M3 灵动岛 MVP → M4 状态完整+Codex → M5 用量引擎 → M6 限额面板 → M7 产品化打包 → M8 打磨。
每个里程碑有独立验证方式（详见计划）。
