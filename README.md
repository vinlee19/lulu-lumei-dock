# Eureka ✦

macOS 菜单栏应用：把本地 **Claude Code** 与 **Codex CLI** 的任务装进一座「灵动岛」——
运行中常驻计时、完成/出错/等待确认弹卡提醒，配上 ccusage 级精度的用量账本、
订阅限额余量、项目会话管理，以及一点点对熬夜程序员的关心。

零第三方依赖 · 全部数据本地 · Swift 5.10 + SwiftPM（无需完整 Xcode）

| | |
|---|---|
| ![compact](docs/images/island-compact.png) | ![finished](docs/images/island-finished.png) |
| 运行中：来源徽标（✳ Claude / ⌨ Codex）+ 计数 + 计时 | 完成卡：耗时 / 会话名 / 项目 / 来源角标 |
| ![tasklist](docs/images/island-tasklist.png) | ![wellness](docs/images/island-wellness.png) |
| 任务列表：当前工具 / ctx 占用 / 空闲会话分组 | 健康提示：vibe coding 太久会被温柔提醒 |

## 功能总览

- **灵动岛通知**
  - 任务运行中顶部常驻小胶囊（与刘海融合 / 可拖拽到任意位置，吸附复位）
  - 完成 / 出错 / 中断弹卡自动收起（悬停暂停），等待权限/输入橙卡常驻直到处理
  - 多任务合并计数、完成卡排队逐显、点胶囊展开任务列表（当前工具、上下文占用 ctx%、空闲会话）
  - 时间显示可切换：已持续时长 ↔ 会话最初开始时间（跨 resume 链取真实创建时刻）
  - Claude / Codex 来源徽标全岛统一（橙色八芒星 / 青色终端）
- **菜单栏**：`▶2 · 36%` —— 任务计数 + 双源 5h 限额取最大值，60% 橙 / 85% 红，悬停看明细
- **用量账本**（与 ccusage 对拍偏差 0.00%）：今日 / 本周 / 本月，按来源与按项目（仓库根归组），
  估算费用（含缓存分价），近 30 天 CSV 导出
- **限额余量**：Codex 5h/周窗口（本地 rollout 快照，零网络）；Claude 订阅限额（非官方接口，
  默认关闭、设置页 opt-in，失效自动隐藏）
- **会话管理**：按项目折叠浏览全部会话（Claude + Codex），ai-title 命名、对话数、
  transcript 大小、会话级费用，搜索 + 时间/大小排序，一键拷贝 `claude --resume` 命令
- **健康提示**：连续活跃超 2 小时（可调）、并发 ≥5 个会话、深夜还在跑任务时的贴心关怀卡
- **数据健康仪表盘**：5 个数据源的心跳/产出/失败状态，轮询停摆直接红灯
- **不依赖 hooks 也能工作**：transcript/rollout 常驻监视兜底——装 hooks 前开的老会话同样可见

## 快速上手

```bash
make install          # 打包并安装到 ~/Applications
open ~/Applications/Eureka.app
```

首次启动自动打开设置页 → 点「**一键安装/更新**」写入 Claude hooks 与 Codex notify
（写入前自动备份 `*.bak.eureka.*`，可随时「全部卸载」恢复原样）。
之后任何 claude / codex 任务都会出现在灵动岛上。建议顺手打开「登录时自动启动」。

> Claude 订阅限额（限额页手动开启）首次会弹一次钥匙串授权，选「始终允许」即可；
> 该数据走非官方接口，官方变更后会自动整块隐藏，不影响其他功能。

## 交互速查

| 操作 | 效果 |
|---|---|
| 点胶囊 | 展开进行中任务列表（含空闲会话） |
| 点卡片 | 切到下一条通知 / 收起 |
| 悬停卡片 | 暂停自动收起 |
| 按住岛拖动 | 移到任意位置（含外接屏），拖回顶部中央自动吸附复位 |
| 任务列表右上角 ⏱ | 切换 耗时 ↔ 开始时间 |
| 菜单栏 ✦ 左键 | 打开面板（历史 / 会话 / 用量 / 限额 / 设置） |
| 菜单栏 ✦ 右键 | 退出 |

## 配置与数据

所有数据在 `~/Library/Application Support/Eureka/`：

| 路径 | 用途 |
|---|---|
| `eureka.sqlite` | 历史 / 用量 / 会话统计（可直接 `sqlite3` 查询） |
| `events/` | 事件队列（hooks → relay 落盘，app 消费） |
| `bin/eureka-relay` | hooks/notify 引用的稳定路径（升级 app 自动同步） |
| `pricing.json`（可选） | 覆盖内置价格表（USD/百万 token，前缀匹配） |
| `context-windows.json`（可选） | 按模型覆盖上下文窗口大小，如 `{"claude-opus": 1000000}` |

隐私：除「Claude 订阅限额」这一项 opt-in 功能会携带钥匙串中的 OAuth token
访问 Anthropic 接口外，**没有任何数据离开本机**。

## CLI

```bash
eureka --install-claude-hooks     # 安装/更新 Claude hooks（写前备份）
eureka --uninstall-claude-hooks
eureka --install-codex-notify     # 安装 Codex notify
eureka --uninstall-codex-notify
eureka --hooks-status             # 双侧安装状态
eureka --usage-snapshot           # 全量扫描并输出今日用量 JSON（对拍脚本用）
eureka --limits-snapshot          # 限额快照（--claude 同时测非官方接口）
eureka --render-previews [目录]    # 离屏渲染灵动岛各形态 PNG
eureka-relay inject --event stop --session demo   # 注入测试事件
```

## 开发

```bash
make build      # 编译（Command Line Tools 即可，无需完整 Xcode）
make test       # 106 个单测（自建 runner，CLT 无 XCTest）
make run        # 开发模式直跑
make demo       # 注入伪造事件，演示灵动岛全场景
make app        # 打包 dist/Eureka.app（ad-hoc 签名）
Scripts/check-usage-against-ccusage.sh   # 用量统计与 ccusage 对拍
```

架构详见 [docs/design.md](docs/design.md)。一句话版：hooks/notify 只调用一个静默的
`eureka-relay` 把事件原子写入 spool 目录；app 端 5 个数据源
（spool 消费、Codex rollout 监视、Claude transcript 监视、双用量扫描器）汇入
`TaskStore` 状态机与 SQLite；灵动岛、菜单栏、面板都是状态的投影。
模块依赖单向：`app → {Ingest, Usage, Install} → Store → Kit`，relay 独立零依赖。

调试小抄：
- 演示健康提示卡：`defaults write com.vinlee.eureka wellnessDemo -bool true` 后重启
- 事件没反应先看 设置 → 数据健康（哪个源红灯/失败计数）
- relay 错误日志：`~/Library/Application Support/Eureka/relay-error.log`

## 已知边界

- Codex 的「等待审批」状态不展示（rollout 不持久化审批事件）
- Claude 订阅限额依赖非官方接口，可能随官方变更失效（失效即隐藏）
- ctx% 对 Claude 是估算值（窗口大小按模型配置表，默认 fable=1M、其余 200k，可覆盖）
- 费用为本地按公开价目估算，与账单可能有出入

## 卸载

设置页「全部卸载」移除 hooks/notify 配置（自动恢复备份语义），然后删除
`~/Applications/Eureka.app` 与 `~/Library/Application Support/Eureka/` 即可，
不留任何残余。
