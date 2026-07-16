# lulu-lumei-dock ✦

**A macOS menu-bar "Dynamic Island" for your local AI coding agents.**
**把本地 AI 编码助手装进 macOS 菜单栏的一座「灵动岛」。**

Surfaces live task activity, a ccusage-accurate usage ledger, subscription rate‑limit
gauges, session/skill/agent/memory management, an audit trail and cloud backup — for
**Claude Code · Codex CLI · opencode · Grok · Antigravity**, all in one overlay.

`Swift 5.10 + SwiftPM` · `zero third‑party dependencies` · `all data stays local`
· builds with Command Line Tools (no full Xcode needed)

> **About the name / 关于名字** — the project (this repo) is **lulu-lumei-dock**. It is
> built on the internal **Eureka** codebase, so Swift module names (`EurekaKit`, …), the app
> bundle (`Eureka.app`) and the on‑disk data directory (`~/Library/Application Support/Eureka/`)
> keep the `Eureka` prefix for compatibility. Renaming those would break the relay stable path
> and existing installs, so they are intentionally left as‑is.

**Jump to · 快速跳转:** [English](#english) · [中文](#中文)

|  |  |
|---|---|
| ![compact](docs/images/island-compact.png) | ![finished](docs/images/island-finished.png) |
| **Running** — source badge (✳ Claude / ⌨ Codex) + count + timer<br>运行中：来源徽标 + 计数 + 计时 | **Finished** — duration / session / project / source<br>完成卡：耗时 / 会话 / 项目 / 来源 |
| ![tasklist](docs/images/island-tasklist.png) | ![wellness](docs/images/island-wellness.png) |
| **Task list** — current tool / ctx% / idle sessions<br>任务列表：当前工具 / 上下文占用 / 空闲会话 | **Wellness** — a gentle nudge after long vibe‑coding<br>健康提示：熬夜编码时的温柔提醒 |

---

## English

### What is this?

`lulu-lumei-dock` is a native macOS menu‑bar app that watches the local logs of your AI coding
agents and turns them into a live **Dynamic Island** overlay near the notch, plus a full panel
with usage analytics, rate limits, and management for sessions, skills, agents and memory.

It works with five agents out of the box — **Claude Code, Codex CLI, opencode, Grok, and
Antigravity** — and needs **no network** for its core features: everything is derived by reading
local transcript / rollout / session files. The only opt‑in network feature is the Claude
subscription rate‑limit gauge (an unofficial endpoint, off by default).

It also works **without installing any hooks** — transcript/rollout watchers are the fallback, so
sessions opened before hooks were installed are still visible.

### Features

**Dynamic Island notifications**
- A compact capsule pins to the top while tasks run (fuses with the notch, or drag it anywhere and
  it snaps back to center).
- Finished / errored / interrupted cards auto‑dismiss (hover to pause); waiting‑for‑permission /
  input cards stay until you deal with them.
- Multi‑task merged counts, queued finished cards shown one by one, click the capsule to expand the
  task list (current tool, context usage `ctx%`, idle sessions).
- Toggle time display: elapsed duration ↔ the session's original start time (resolved across resume
  chains to the true creation moment).
- Unified per‑source brand marks across the whole island (Claude star, Codex pinwheel, Grok slash,
  opencode terminal, Antigravity chevrons).

**Menu bar** — e.g. `▶2 · 37%`: active task count + the max of your subscription limits (Codex 5h /
Grok weekly / Claude), colored 60% amber / 85% red, with a tooltip breakdown.

**Usage ledger** (0.00% diff vs. `ccusage`) — today / this week / this month / custom range, broken
down by source, model, project (grouped to repo root) and session; estimated cost (with separate
cache pricing); a day/hour trend chart; a weekday×hour activity heatmap; and a
**skills / plugins** tab counting `skill` / `mcp` / `agent` / `command` / `tool` invocations. Export
the last 30 days to CSV.

**Skills** — browse, create, edit, and enable/disable skills across all five tools (enable/disable is
non‑destructive: the skill folder is moved to a sibling `*.eureka-disabled` directory). Plus a
dedicated **usage‑analytics** view (list ↔ stats toggle):
- Three rankings: **recently used / most used / longest unused**, each with last‑active time and
  cumulative count.
- Every list row shows its **last‑active** time.
- A **detail page** per skill: description, a cross‑tool **configuration matrix** (which of
  Claude/Codex/Grok/Antigravity/opencode has it, and whether it is user‑authored or tool‑bundled,
  shown as brand logos), and invocation stats — **count, trigger‑time tokens, and a daily trend**.
- Note on data: per‑skill invocation data is only recoverable for **Claude** (its transcript records
  `Skill` calls with usage on the same record). Trigger‑time tokens ≈ the context size at the moment
  of invocation, not the skill's full execution cost — this is labeled in the UI.

**Memory** — browse and edit `CLAUDE.md` / `AGENTS.md` and per‑project / per‑user memory files across
tools, with in‑app markdown preview + edit (atomic save with timestamped backup).

**Agent** — manage agent / subagent definitions across tools, mirroring the skills workflow.

**Plans** — browse and manage agent plan documents.

**Limits** — subscription rate‑limit gauges:
- **Codex** and **Grok** read a local snapshot (Codex from the newest rollout's `rate_limits`; Grok
  from `~/.grok/logs/unified.jsonl` billing entries) — **zero network**, hidden when unavailable.
- **Claude** is opt‑in (off by default) and uses an unofficial endpoint; any failure hides the whole
  block. Enabling it prompts a one‑time Keychain authorization (choose "Always Allow").

**Audit** — an append‑only trail of agent tool calls (full commands / file paths, no output bodies),
with risk flagging.

**Backup** — optional cloud backup of your local data to an S3‑compatible bucket (SigV4 signed).

**Health & wellness** — a data‑health dashboard shows heartbeat / output / failure status of every
data source (a stalled poller turns red), plus gentle wellness cards after long continuous activity,
many concurrent sessions, or late‑night runs.

### Supported agents

| Agent | Live tasks | Usage/tokens | Rate limits | Sessions | Skills / Memory / Agents |
|---|---|---|---|---|---|
| **Claude Code** | ✅ | ✅ | ✅ (opt‑in) | ✅ | ✅ |
| **Codex CLI** | ✅ | ✅ | ✅ (local) | ✅ | ✅ |
| **opencode** | ✅ | ✅ | — | ✅ | ✅ |
| **Grok** | ✅ | activity only¹ | ✅ (local) | ✅ | ✅ |
| **Antigravity** | ✅ | activity only¹ | — | ✅ | ✅ |

¹ Grok is subscription‑based and Antigravity stores conversations as protobuf, so neither exposes
per‑request token accounting locally — only activity (invocations / sessions) is available.

### Quick start

```bash
make install                 # build release + install to /Applications/Eureka.app
open /Applications/Eureka.app
```

On first launch the Settings tab opens — click **一键安装/更新 (Install / Update)** to write Claude
hooks and Codex notify (a `*.bak.eureka.*` backup is made first; "Uninstall all" restores it any
time). After that, any `claude` / `codex` task shows up on the island. Consider enabling
"Launch at login".

### Interaction cheatsheet

| Action | Effect |
|---|---|
| Click the capsule | Expand the running‑task list (incl. idle sessions) |
| Click a card | Advance to the next notification / dismiss |
| Hover a card | Pause auto‑dismiss |
| Drag the island | Move anywhere (incl. external displays); drop near top‑center to snap back |
| ⏱ in the task list | Toggle elapsed ↔ start time |
| Menu‑bar ✦ left‑click | Open the panel (history / sessions / usage / limits / settings …) |
| Menu‑bar ✦ right‑click | Quit |

### Configuration & data

All data lives in `~/Library/Application Support/Eureka/`:

| Path | Purpose |
|---|---|
| `eureka.sqlite` | history / usage / sessions / audit (inspect directly with `sqlite3`) |
| `events/` | event spool (hooks → relay writes here atomically, app consumes) |
| `bin/eureka-relay` | the stable path referenced by hooks/notify (re‑synced by hash on launch) |
| `pricing.json` (optional) | override the built‑in price table (USD / million tokens, prefix match) |
| `context-windows.json` (optional) | override per‑model context window size, e.g. `{"claude-opus": 1000000}` |

**Privacy:** apart from the opt‑in "Claude subscription limits" feature (which sends a Keychain OAuth
token to Anthropic), **no data ever leaves your machine**.

### CLI

```bash
eureka --install-claude-hooks      # install/update Claude hooks (backs up first)
eureka --uninstall-claude-hooks
eureka --install-codex-notify      # install Codex notify
eureka --uninstall-codex-notify
eureka --hooks-status              # install state for both sides
eureka --usage-snapshot            # full scan → today's usage JSON (used by the ccusage diff)
eureka --limits-snapshot [--claude]# rate-limit snapshot (Codex + Grok local; --claude also hits the unofficial API)
eureka --audit-snapshot            # dump the agent tool-call audit trail (--risk-only / --limit N)
eureka --render-previews [dir]     # offscreen-render every island state to PNG
eureka-relay inject --event stop --session demo   # inject a test event into the spool
```

### Development

```bash
make build      # debug build (Command Line Tools is enough — no full Xcode)
make test       # runs the full hand-rolled test suite (276 tests; CLT has no XCTest)
make run        # run the GUI in dev mode
make demo       # inject fake events to show every island state
make app        # release build → dist/Eureka.app (ad-hoc signed)
make install    # app + install to /Applications/Eureka.app
make clean      # rm -rf .build dist
Scripts/check-usage-against-ccusage.sh   # diff usage totals vs. ccusage (expect 0.00%)
```

There is no test filter — the runner (`Tests/EurekaTestsRunner/main.swift`) calls each suite
sequentially. To run a subset, comment out suite calls in `main.swift`.

### Architecture

Data flows one direction: **external agents → relay → spool → app state machine → SQLite + UI
projections.**

```
Claude Code hooks ──┐                                   ┌─ Dynamic Island NSPanel (compact/expanded)
Codex notify ───────┤→ eureka-relay → events/ spool ────│
                    │   (atomic JSON write)    ↓         ├─ NSStatusItem + NSPopover
Codex rollout tail ─┘                    SpoolConsumer   │   (history / sessions / skills / usage / limits / …)
Claude transcript watch ──────────────→ TaskStore (state machine)
usage scanners (Claude/Codex/opencode/Grok) ──────────→ SQLite (history / usage / tool_calls / audit)
```

- **`eureka-relay`** is a tiny, fully independent binary: it always `exit 0`, keeps stdout silent,
  runs in <50ms, and writes to `tmp/` then atomically `rename`s into the spool. Hooks/notify configs
  only ever reference the stable path `~/Library/Application Support/Eureka/bin/eureka-relay`, which
  the app re‑syncs by hash on launch so upgrades never break the link.
- **Module dependency graph** (SwiftPM targets, strictly one‑directional):
  `app → {EurekaIngest, EurekaUsage, EurekaInstall, EurekaSync} → EurekaStore → EurekaKit`.
  `eureka-relay` is dependency‑free.
- **SQLite** uses the system `libsqlite3` so the DB stays `sqlite3`‑inspectable. Usage tables are
  *derived* (rebuilt from transcripts on a schema‑version bump); `task_history` / `audit_events` /
  sync tables are *facts* and are never dropped.

Full design doc: [docs/design.md](docs/design.md).

### Known limitations

- Codex's "waiting for approval" state isn't shown (rollouts don't persist approval events).
- Claude subscription limits rely on an unofficial endpoint and may break with official changes
  (it hides itself when it does).
- Per‑skill invocation data (count / tokens / trend) is **Claude‑only**; Codex/Grok/opencode/
  Antigravity don't tag skill invocations in their logs.
- `ctx%` for Claude is an estimate (window size from a per‑model table; overridable).
- Costs are local estimates against public price lists and may differ from your bill.

### Uninstall

Use Settings → "Uninstall all" to remove hooks/notify (restoring backups), then delete
`/Applications/Eureka.app` and `~/Library/Application Support/Eureka/`. Nothing is left behind.

---

## 中文

### 这是什么

`lulu-lumei-dock` 是一个原生 macOS 菜单栏应用：它监视本地 AI 编码助手的日志,把任务活动实时装进刘海
旁的一座「灵动岛」,并提供一个完整面板——用量分析、订阅限额,以及会话 / 技能 / agent / 记忆的管理。

开箱支持五种助手——**Claude Code、Codex CLI、opencode、Grok、Antigravity**,核心功能**零网络**:
一切都靠读取本地 transcript / rollout / session 文件推导。唯一的联网功能是 Claude 订阅限额(非官方
接口,默认关闭,可在设置里 opt‑in)。

而且**不装 hooks 也能用**——transcript/rollout 常驻监视兜底,装 hooks 之前开的老会话同样可见。

### 功能总览

**灵动岛通知**
- 任务运行中顶部常驻小胶囊(与刘海融合,也可拖到任意位置,松手自动吸附回中央)。
- 完成 / 出错 / 中断卡片自动收起(悬停暂停);等待权限 / 输入的橙卡常驻直到你处理。
- 多任务合并计数、完成卡排队逐显,点胶囊展开任务列表(当前工具、上下文占用 `ctx%`、空闲会话)。
- 时间显示可切换:已持续时长 ↔ 会话最初开始时间(跨 resume 链取真实创建时刻)。
- 全岛统一的来源徽标(Claude 八芒星 / Codex 风车 / Grok 斜杠方 / opencode 终端 / Antigravity 人字)。

**菜单栏** —— 例如 `▶2 · 37%`:活跃任务数 + 订阅限额取最大值(Codex 5h / Grok 周 / Claude),
60% 橙、85% 红,悬停看明细。

**用量账本**(与 `ccusage` 对拍偏差 0.00%)—— 今日 / 本周 / 本月 / 自定义区间,按来源、模型、项目
(归组到仓库根)、会话拆分;估算费用(缓存分价);日 / 小时趋势图;周×小时活跃热力图;以及一个
**技能 / 插件** 页,统计 `skill` / `mcp` / `agent` / `command` / `tool` 的调用次数。近 30 天可导出 CSV。

**Skills(技能)** —— 跨全部五种工具浏览、新建、编辑、启用 / 停用技能(启停非破坏:把技能目录移到同级
`*.eureka-disabled`)。并新增专用的**使用分析**视图(列表 ↔ 统计分段):
- 三档排行:**最近使用 / 最常使用 / 最久未使用**,各带最近活跃时间与累计次数。
- 每个列表行显示**最近活跃**时间。
- 每个技能的**详情页**:描述、跨工具**配置矩阵**(Claude/Codex/Grok/Antigravity/opencode 里哪些装了、
  各自是自建还是工具内置,以品牌 logo 展示)、以及调用统计——**次数、触发时 token、按天趋势**。
- 数据说明:逐技能调用数据只有 **Claude** 可得(它的 transcript 把 `Skill` 调用与用量记在同一条)。
  触发时 token ≈ 调用当轮的上下文规模,而非技能整段执行开销——UI 已明确标注。

**Memory(记忆)** —— 跨工具浏览、编辑 `CLAUDE.md` / `AGENTS.md` 与项目级 / 用户级记忆文件,应用内
markdown 预览 + 编辑(原子写入,写前留时间戳备份)。

**Agent** —— 跨工具管理 agent / 子代理定义,与技能一套工作流。

**Plans** —— 浏览与管理 agent 的计划文档。

**限额** —— 订阅额度余量:
- **Codex** 与 **Grok** 读本地快照(Codex 取最新 rollout 的 `rate_limits`;Grok 取
  `~/.grok/logs/unified.jsonl` 的账单行)——**零网络**,无数据即隐藏。
- **Claude** 为 opt‑in(默认关),走非官方接口,任何失败即整块隐藏。首次启用会弹一次钥匙串授权
  (选「始终允许」)。

**审计** —— agent 工具调用的追加式流水(完整命令 / 文件路径,不含输出正文),带风险标记。

**备份** —— 可选:把本地数据备份到 S3 兼容的云存储(SigV4 签名)。

**健康关怀** —— 数据健康仪表盘展示每个数据源的心跳 / 产出 / 失败状态(轮询停摆直接红灯);外加连续
活跃过久、并发会话过多、深夜还在跑任务时的温柔提示卡。

### 支持的助手

| 助手 | 实时任务 | 用量/token | 限额 | 会话 | 技能/记忆/Agent |
|---|---|---|---|---|---|
| **Claude Code** | ✅ | ✅ | ✅(opt‑in) | ✅ | ✅ |
| **Codex CLI** | ✅ | ✅ | ✅(本地) | ✅ | ✅ |
| **opencode** | ✅ | ✅ | — | ✅ | ✅ |
| **Grok** | ✅ | 仅活动量¹ | ✅(本地) | ✅ | ✅ |
| **Antigravity** | ✅ | 仅活动量¹ | — | ✅ | ✅ |

¹ Grok 是订阅制、Antigravity 会话是 protobuf,两者本地都不暴露 per‑request token 账,只能给活动量
(调用 / 会话)。

### 快速上手

```bash
make install                 # 构建 release 并安装到 /Applications/Eureka.app
open /Applications/Eureka.app
```

首次启动自动打开设置页 → 点「**一键安装/更新**」写入 Claude hooks 与 Codex notify(写前自动备份
`*.bak.eureka.*`,可随时「全部卸载」恢复原样)。之后任何 `claude` / `codex` 任务都会出现在灵动岛上。
建议顺手打开「登录时自动启动」。

### 交互速查

| 操作 | 效果 |
|---|---|
| 点胶囊 | 展开进行中任务列表(含空闲会话) |
| 点卡片 | 切到下一条通知 / 收起 |
| 悬停卡片 | 暂停自动收起 |
| 按住岛拖动 | 移到任意位置(含外接屏),拖回顶部中央自动吸附复位 |
| 任务列表右上角 ⏱ | 切换 耗时 ↔ 开始时间 |
| 菜单栏 ✦ 左键 | 打开面板(历史 / 会话 / 用量 / 限额 / 设置 …) |
| 菜单栏 ✦ 右键 | 退出 |

### 配置与数据

所有数据都在 `~/Library/Application Support/Eureka/`:

| 路径 | 用途 |
|---|---|
| `eureka.sqlite` | 历史 / 用量 / 会话 / 审计(可直接 `sqlite3` 查询) |
| `events/` | 事件队列(hooks → relay 原子落盘,app 消费) |
| `bin/eureka-relay` | hooks/notify 引用的稳定路径(启动按 hash 自动同步) |
| `pricing.json`(可选) | 覆盖内置价格表(USD / 百万 token,前缀匹配) |
| `context-windows.json`(可选) | 按模型覆盖上下文窗口大小,如 `{"claude-opus": 1000000}` |

**隐私:** 除「Claude 订阅限额」这一 opt‑in 功能会携带钥匙串中的 OAuth token 访问 Anthropic 外,
**没有任何数据离开本机**。

### CLI

```bash
eureka --install-claude-hooks      # 安装/更新 Claude hooks(写前备份)
eureka --uninstall-claude-hooks
eureka --install-codex-notify      # 安装 Codex notify
eureka --uninstall-codex-notify
eureka --hooks-status              # 双侧安装状态
eureka --usage-snapshot            # 全量扫描并输出今日用量 JSON(对拍脚本用)
eureka --limits-snapshot [--claude]# 限额快照(Codex + Grok 本地;--claude 同时测非官方接口)
eureka --audit-snapshot            # 输出 agent 操作审计流水(--risk-only / --limit N)
eureka --render-previews [目录]     # 离屏渲染灵动岛各形态 PNG
eureka-relay inject --event stop --session demo   # 注入测试事件
```

### 开发

```bash
make build      # 调试编译(Command Line Tools 即可,无需完整 Xcode)
make test       # 跑全部自建单测(276 个;CLT 无 XCTest)
make run        # 开发模式直跑 GUI
make demo       # 注入伪造事件,演示灵动岛全场景
make app        # 打包 dist/Eureka.app(ad‑hoc 签名)
make install    # 打包并安装到 /Applications/Eureka.app
make clean      # rm -rf .build dist
Scripts/check-usage-against-ccusage.sh   # 用量与 ccusage 对拍(期望 0.00%)
```

没有测试过滤器——runner(`Tests/EurekaTestsRunner/main.swift`)顺序调用每个 suite;要只跑子集,
在 `main.swift` 里注释掉对应调用即可。

### 架构

数据单向流动:**外部助手 → relay → spool → app 状态机 → SQLite + UI 投影。**

```
Claude Code hooks ──┐                                   ┌─ 灵动岛 NSPanel(收起/展开)
Codex notify ───────┤→ eureka-relay → events/ spool ────│
                    │   (原子 JSON 写)         ↓         ├─ NSStatusItem + NSPopover
Codex rollout 监视 ─┘                    SpoolConsumer   │   (历史 / 会话 / 技能 / 用量 / 限额 / …)
Claude transcript 监视 ────────────────→ TaskStore(状态机)
用量扫描器(Claude/Codex/opencode/Grok) ────────────→ SQLite(历史 / 用量 / tool_calls / 审计)
```

- **`eureka-relay`** 是一个极小、完全独立的二进制:永远 `exit 0`、stdout 绝对静默、<50ms 完成、
  先写 `tmp/` 再原子 `rename` 进 spool。hooks/notify 配置只引用稳定路径
  `~/Library/Application Support/Eureka/bin/eureka-relay`,app 启动按 hash 重新同步,升级不断链。
- **模块依赖图**(SwiftPM target,严格单向):
  `app → {EurekaIngest, EurekaUsage, EurekaInstall, EurekaSync} → EurekaStore → EurekaKit`;
  `eureka-relay` 零依赖。
- **SQLite** 用系统 `libsqlite3`,DB 始终可 `sqlite3` 直查。用量表是*派生表*(schema 升级时从
  transcript 重建);`task_history` / `audit_events` / 备份表是*事实表*,绝不 DROP。

完整设计文档见 [docs/design.md](docs/design.md)。

### 已知边界

- Codex 的「等待审批」状态不展示(rollout 不持久化审批事件)。
- Claude 订阅限额依赖非官方接口,可能随官方变更失效(失效即隐藏)。
- 逐技能调用数据(次数 / token / 趋势)**仅 Claude**;Codex/Grok/opencode/Antigravity 的日志不标记
  技能调用。
- Claude 的 `ctx%` 为估算值(窗口大小按模型配置表,可覆盖)。
- 费用为本地按公开价目估算,与账单可能有出入。

### 卸载

设置页「全部卸载」移除 hooks/notify(自动恢复备份),然后删除 `/Applications/Eureka.app` 与
`~/Library/Application Support/Eureka/` 即可,不留任何残余。
