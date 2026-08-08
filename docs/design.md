# Eureka 设计文档

> 由批准的实现计划整理（2026-06-10）。完整计划含风险清单见
> `~/.claude/plans/macos-1-claude-code-wiggly-globe.md`。

## 目标

1. **灵动岛通知**：Claude Code / Codex CLI 任务运行中顶部常驻小胶囊（任务数+计时）；
   完成/等待确认/出错时展开卡片（简述+耗时），数秒自动收起、悬停暂停、点击详情；无任务完全隐藏。
   四类卡的停留时长 = 用户设置的基准秒数（默认 6，设置页 3–15）+ 各自偏移：完成 +0 / 等待 +4 /
   健康提示 +5 / 安全告警 +6。偏移定义在 `IslandState.Card.autoDismissExtraSeconds`，
   入卡计时与悬停后重排计时**共用**它（两处曾各写一份 switch，漏改一边就会让卡片退回常驻）。
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

### Claude 记忆库 `~/.claude/projects/<encoded>/memory/`（本机 11 个库 / 97 个文件实勘）

- 布局：`MEMORY.md`（索引，一行一条钩子）+ 每条记忆一个 `*.md`。Qwen 的
  `~/.qwen/projects/<encoded>/memory/` 同构（本机三个库各只有一份空 MEMORY.md → UI 标「仅索引」）。
- frontmatter：`name` / `description` + **嵌套** `metadata{node_type,type,originSessionId,modified}`。
  `type` 四类 user/feedback/project/reference，缺省归 `other`（本机 97 个里 9 个没写）。
  解析复用 `parseFrontmatterFields` —— 它把嵌套子键当顶层键收下，记忆索引**有意**依赖这一点。
- **`originSessionId` 指向写下这条记忆的会话**（84/97 有），但同目录 `<uuid>.jsonl`
  只剩 37 个 —— 会话会被删/轮转。所以 `MemoryEntry.originSessionPath` 为 nil 即「不可跳转」，
  UI 必须置灰而不是给一个跳到空页面的入口。
- 正文 `[[wiki 链接]]`：本机 115 处、113 处能解析到同库文件。匹配键要同时试**文件 basename**
  （下划线）与 frontmatter **name**（连字符），故归一时 `_` 视作 `-`。解析不到的不造边、只计数
  （其中 2 处是正文把 `[[…]]` 当强调号用）。
- **目录名编码有损、不可反解**：`/`、`.`、`_` 三种字符**都**变 `-`（实勘 11 个目录全对，
  例：`…/metricflow-ci/metric_flow/…/test_parameter` → `…-metric-flow-…-test-parameter`）。
  项目名只能**正向**编码已知仓库根来比对（`resolveProjectName`），比不上再读一份 transcript 头部取 cwd；
  按 `-` 切末段是错的（`aftership-semantic-layer` 会变成 `layer`）。
- 图谱（`EurekaKit/MemoryGraph{,Layout}.swift`，纯函数、可单测、可离屏渲染）：
  节点=索引/分类/条目/来源会话，边=收录/引用/来源；排版是均匀网格（列=分类泳道+会话道，
  行=索引/泳道头/条目），**水平段只走行 gutter、竖直段只走列 gutter** ⇒「边不穿节点」可证。
  泳道塞不进视口时画布变宽由调用方横向滚动，只有节点数超上限才降级不画。

### Codex 记忆 `~/.codex/memories/`（**只有全局，没有项目级**；本机实勘）

- 开关：`config.toml` 的 `[features] memories = true` + `[memories] generate_memories/use_memories`。
- 位置唯一：`~/.codex/memories/`，是 Codex 自建的 **git 仓库**（baseline commit `Initialize Codex git baseline`）。
  各仓库下**没有** `.codex/memories`；`.codex-global-state.json` 里也没有任何 per-project memory 键。
- **项目归属写在内容里，不在目录上**：`MEMORY.md` 每个 Task Group 带 `applies_to: cwd=…`，
  `raw_memories.md` 每条带 `cwd:`/`rollout_path:`/`thread_id:`。与 Claude 的「一项目一目录」正相反，
  所以 Codex 这边**没有**可折叠成「记忆库」的结构。
- 三层管道（文件 mtime 依次递增可印证）：`raw_memories.md`（stage-1 原始，按 thread 合并）→
  `MEMORY.md`（Task Group 结构化，引用 rollout summary 作证据）→ `memory_summary.md`（用户画像+偏好）。
- ⚠️ **这个目录只有顶层三份是记忆**，绝不能递归扫（递归会把 20 个文件全算成记忆，其中 17 个不是）：
  `rollout_summaries/*.md` 是每次会话的摘要（MEMORY.md 的证据附件）、`extensions/` 是教 Codex
  怎么维护记忆的元指令、`skills/` 里躺着**技能**（实勘 `publish-draft-pr`，归技能扫描收走）。

### 记忆 vs 指令：两个页签，两套统计

- **记忆** = agent 自己攒下来的：Claude/Qwen 的项目记忆库、`~/.claude/memories`、
  Codex `memories/` 顶层三份、Hermes `memories/{MEMORY,USER}.md`、grok/codebuddy/qoder 的记忆目录、
  Trae `~/.trae-cn/memory/{user_profile.md, projects/<encoded>/{project_memory.md, <YYYYMMDD>/topics.md}}`。
- **指令** = 用户写给 agent 的规则：`CLAUDE.md` / `AGENTS.md`（含 `AGENTS.override.md` 优先级）/
  `GEMINI.md` / `QWEN.md` / `<repo>/.cursor/rules/*.mdc` / Hermes `SOUL.md`（人格身份）/
  Trae `<dataFolder>/user_rules.md` + `<dataFolder>/user_rules/*.md` + `<repo>/.trae/rules/*.md`。
- 两者混在一个数字里会让「记忆有多少」失去意义（本机 105 记忆 vs 19 指令），所以分页签、分统计口径。
  Hermes 是唯一需要在同一目录里分开判的：`memories/MEMORY.md` 与 `USER.md` 是它自记 → 记忆；
  `SOUL.md` 是人格设定 → 指令。

### 会话发现的成本与节奏（实测，2026-07-30）

发现 = 遍历各源会话目录 + 逐个读文件头拿 cwd/标题。它是**索引链路的主要成本**，必须共享与限频。

- 修复前：`AgentSessionDiscovery.forIndexing()` **72.8 s**（269 会话 / 1095 MB），而用量 60 s 定时器
  每轮都调 → 后台队列永不空闲，应用长跑平均 CPU **29.5%**。
- 成本几乎全在 **Codex 一家**：65.09 s / 121 会话（Claude 94 个只要 0.41 s，其余 10 源合计 0.6 s）。
  根因是 `headInfo` 为了等 `user_message` 一路读到文件末尾 —— 而 24% 的 rollout 压根没有用户消息，
  单文件最大 70 MB。修法：定长头部（64 KB 探测 + 1 MB 上限）、字节预筛后再 JSON、游标逐行不用 `split`。
- 修复后：`forIndexing()` **1.9 s**、`recentCwds()` **3.5 s**（原 58.3 s）。
- 节奏：用量 / 限额 / 历史 60 s；**全文索引与逐轮诊断 5 分钟**（`UsageService.indexInterval`）——
  它们不是实时数据，跑得再密也只是重复付发现成本。知识库四个服务共享 `ProjectScopeDiscovery` 的
  60 s TTL 缓存（预热时它们会连着要四次）。

顺带修掉一个**正确性** bug：resume/fork 的 rollout 里有第二条 `session_meta`，旧代码扫到末尾时会用它
覆盖 id，于是 121 个文件只解析出 91 个唯一 id —— 30 个会话在列表、`turn_metrics`、`fts_docs` 里互相覆盖。
现在只认第一条，并靠 schema v18 强制重扫（指纹没变不会自动重建）。

### 跨源配置一致性（`EurekaIngest/ConsistencyChecker.swift`）

审计页顶部一张卡，报三类能自动判定的横向缺口：项目指令文件配了一半、某源缺了别处已配的技能、
记忆库索引漂移。**阈值口径由单测钉住**，因为这块的风险不是算错而是报太多：

- 指令：只认「用户已在 ≥2 个仓库用过」的文件名；无指令的仓库只有**有记忆库**的才算活跃项目 ——
  `ProjectResolver` 会把 `~/.slock/agents/<uuid>` 这类 sandbox cwd 认成仓库根（实测 17 个里 5 个）。
- 技能：**按源聚合**，且只报「只差这一个源」的技能。逐条列会刷出 25 行说同一件事；
  而「claude 48 个、cursor 23 个」这种差异多半是故意的，报了也没有可执行动作。
- 收紧前后：18 项 → **5 项**（3 个仓库指令缺口 + 1 个源技能缺口 + 1 个库漂移）。

### Trae（CN 3.3.84 / 国际版 3.5.35 实勘）

**会话正文读不到，这是硬结论。** `~/Library/Application Support/Trae CN/ModularData/ai-agent/database.db`
前 16 字节是随机 salt（SQLCipher），`sqlite3` 报 `file is not a database`；`state.vscdb` 里只有 UI 状态
（`memento/icube-ai-agent-storage` 的 currentSessionId、`ai-chat:sessionRelation:modelMap` 的模型名），
没有消息。全机没有任何明文转录。所以 **没有正文 / token / 成本 / 限额**。

- **hooks（只有 CN 有）**：全局 `~/.trae-cn/hooks.json` + 项目 `<repo>/.trae/hooks.json`。
  路径出处是前端资产表 `{assetType:"hook",projectRelPath:".trae/hooks.json",globalRelPath:"hooks.json"}`，
  global 根 = `pathService.userHome` + `productService.dataFolderName`（`.trae-cn`）。
  载荷与输出契约都是 Claude 那套（`hook_event_name` / `session_id` / `cwd` / `tool_input` /
  `tool_response`；`hookSpecificOutput` / `permissionDecision` / `additionalContext` / `stopReason`），
  二进制里还带 `import_claude_folders` / `global_import_claude_enabled` / `CLAUDE_PROJECT_DIR`
  —— 它是刻意做的 Claude 兼容。事件名：`UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop` /
  `PreCompact` / `PostCompact`；**没有** `SessionEnd` / `Notification`（→ 等待授权对 Trae 不可见）。
  **没有** `transcript_path`。
- **记忆库（只有 CN 有）**：`~/.trae-cn/memory/user_profile.md`、
  `memory/projects/<encoded>--p<N>-<hash>/project_memory.md`、
  `.../<YYYYMMDD>/topics.md`、`.../<YYYYMMDD>/session_memory_<sessionId>.jsonl`。
  `topics.md` 实勘是**单行无换行**的 `[session_id: <id> | topic_summary_time: yyyy-MM-dd HH:mm:ss]<叙述>`，
  多个块可能紧邻相连 → 必须用「下一个块头的起点」定界，不能按行切。
  `session_memory_*.jsonl` 每回合一行（`intent` / `actions` / `outcome` / `learned` /
  `message_summary_time` / `compact_summary_meta.created_at_ms`），只取时间戳。
- **cwd 反查**：`<appSupport>/User/workspaceStorage/<hash>/workspace.json` 的 `folder` 字段
  （`file://` URI）是唯一非有损来源；记忆库目录名要**正向编码**这些真实路径去比对。
- **技能**：`<dataFolder>/skills`、`builtin_skills`、`builtin/global/skills`（后两处内容不同，
  都要扫）、`<repo>/.trae/skills`；文件是标准 `SKILL.md` + `name`/`description` frontmatter。
- **计划**：`<repo>/.trae/documents/plan_<yyyyMMdd>_<HHmmss>.md`，本就是 markdown，
  同 Hermes 就地索引不物化；同目录还有别的文档，按 `plan_` 前缀收窄。
- **明确不用的数据源**：`logs/<启动时间>/Modular/ai-agent_*_stdout.log` 里确实有完整生命周期
  （`[ChatService] chat start`、`service:"chat", method:"chat"`、`[Hooks] … hook completed`），
  但它是内部 Rust tracing、100MB/1.5h、目录名每次启动变、格式随版本改 —— 不作为数据源。

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
