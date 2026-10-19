# 为 lulu-lumei-dock 做贡献

[English](CONTRIBUTING.md) · 简体中文

感谢参与。本文说明**如何提需求**（issue 与提案）以及**如何提交改动**（草稿 PR 与正式 PR）。
日常研发流程——分支、测试、验证关卡、发版——见
[docs/DEVELOPMENT_WORKFLOW.zh-CN.md](docs/DEVELOPMENT_WORKFLOW.zh-CN.md)。

AI 编码代理遵守完全相同的规则。`AGENTS.md` 与 `CLAUDE.md` 补充了面向代理的细节（提交规范、架构、
关键不变量），其中任何内容都不会放宽本指南。

> 英文版 [CONTRIBUTING.md](CONTRIBUTING.md) 为准；两者冲突时以英文版为准，并请提 PR 同步。

## 目录

- [基本原则](#基本原则)
- [选择合适的渠道](#选择合适的渠道)
- [Issue](#issue)
- [提案（Proposal）](#提案proposal)
- [Pull Request](#pull-request)
- [草稿 PR（Draft）](#草稿-prdraft)
- [代码评审](#代码评审)
- [编码规范速览](#编码规范速览)
- [安全](#安全)

## 基本原则

- 互相尊重，默认善意。评论代码，不评论人。
- 一个 PR 只做一件逻辑上的事。重构与行为变更绝不放在同一个 PR。
- 新建前先搜索已有 issue 和 PR。
- 非小改动先开 issue，在写代码前对齐方向。错别字、小的文档修正可以直接提 PR。
- 不要把密钥、token、API key 或个人数据（邮箱、真实会话内容、`eureka.sqlite` 导出）贴进 issue、
  PR、日志或截图。

## 选择合适的渠道

| 你想要…… | 使用 |
|---|---|
| 报告功能异常 | **Bug report** issue |
| 提一个小而独立的改进 | **Feature request** issue |
| 改动架构、数据流、关键不变量，或新增 Agent / 依赖 | **Proposal** issue + 设计文档（见[提案](#提案proposal)） |
| 尽早分享代码、确认方向 | **草稿（Draft）** PR |
| 提交已完成且已验证的工作 | **Ready for review** PR |
| 报告安全漏洞 | 私密安全通告——**绝不**公开提 issue |

## Issue

Issue 表单位于 [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/)。issue 可用中文或英文书写；
标题简短具体。

### Bug 反馈

好的 bug 报告能让别人无需追问即可复现。请包含：

- **版本**——应用版本（*设置 → 关于*，源码构建看 `VERSION`）与 macOS 版本。
- **涉及的 Agent**——Claude Code、Codex、Cursor……及其版本。
- **Hook / notify 状态**——`swift run eureka --hooks-status` 的输出，或写明"未安装 hooks"。
- **复现步骤**、**期望结果**与**实际结果**。
- **证据**——截图或日志，**去除个人信息**。

用量合计类 bug：尽量附上 `Scripts/check-usage-against-ccusage.sh` 的输出——目标是 `0.00%` 偏差。

### 功能建议

先描述**问题**，再给出建议方案与考虑过的替代方案。"作为 X 的用户，我因为 Z 无法 Y"胜过
"请加一个按钮"。如果需求涉及[提案](#提案proposal)所列范围，维护者会要求改走提案流程。

### 分诊与标签

标签由维护者添加：`bug`、`enhancement`、`documentation`、`question`、`good first issue`、
`help wanted`、`duplicate`、`invalid`、`wontfix`。提案使用 `enhancement` 标签并以 `[Proposal]`
作为标题前缀。动手前请先留言"我来做"，避免重复劳动；被指派后 14 天无进展可能会被取消指派。

## 提案（Proposal）

提案是在**实现之前**进行的轻量设计评审。

### 何时必须提案

- 新增 Agent 数据源（tailer、scanner、indexer 或 hook 安装器）。
- 修改事件管线、`TaskStore` 状态机，或 relay 的 envelope / CLI 契约。
- 修改 SQLite schema、spool 格式，或任何落盘数据。
- 触及 `CLAUDE.md` 中 *Critical invariants*（关键不变量）的任何一条。
- 新增第三方依赖（运行时目前只依赖 Sparkle——新增依赖需要充分理由）。
- 新的一级 UI 界面（侧栏页面、灵动岛状态、设置页签）或新的界面风格。
- 任何读取凭证、钥匙串条目或新外部数据库的改动。

Bug 修复、小的 UI 打磨、测试和文档**不需要**提案。

### 生命周期

```
Draft（草稿）──► Discussion（讨论）──► Accepted（接受）──► Implemented（已实现）
                                  └──► Declined / Withdrawn（拒绝 / 撤回）
```

1. **用模板开 Proposal issue**：填写动机、设计草图、影响的模块与不变量、备选方案、上线与回滚计划。
2. **写设计文档**（当 issue 容纳不下时）：`docs/specs/YYYY-MM-DD-<slug>-design.md`（该目录已有范例）。
   作为独立的 `docs(specs): …` PR 提交，或附在 issue 上。
3. **讨论**——至少一位维护者评审。未决问题写进文档，而不是散落在评论里。
4. **决定**——维护者将 issue 标记为 *Accepted* 或 *Declined*，并附一段理由。被接受的提案可在
   `docs/superpowers/plans/` 下补充实现计划。
5. **实现**——PR 引用提案（`Implements #123`）。实现中如需实质性调整设计，先更新文档。

## Pull Request

### 提交前

- [ ] 非小改动都有对应 issue（或提案），且 PR 中已关联。
- [ ] 分支已基于最新 `main`（使用 rebase，不要把 `main` merge 进来）。
- [ ] 已通过 [DEVELOPMENT_WORKFLOW.zh-CN.md](docs/DEVELOPMENT_WORKFLOW.zh-CN.md#5-本地验证关卡)
      中的本地验证关卡。

### 分支命名

`<type>/<简短-kebab-描述>`，type 取下方的提交类型——例如 `fix/codex-rollout-title`、
`feat/trae-live-cards`、`docs/contributing-guide`。

### 标题

PR 采用 **squash merge**，标题即 `main` 上的提交信息，必须遵循
[Conventional Commits](https://www.conventionalcommits.com/) 且能独立成立：

```
<type>(<scope>): <imperative summary>
```

- **Types**：`feat` `fix` `docs` `refactor` `perf` `test` `chore` `ci`
- **Scopes**：`ui` `island` `claude` `codex` `opencode` `grok` `kimi` `antigravity` `hermes`
  `codebuddy` `qoder` `cursor` `trae` `ingest` `usage` `store` `sync` `install` `updates`
  `packaging` `ci` `changelog`
- 英文、祈使语气、小写开头、结尾无句号、≤ 72 个字符。
- 标题中不要出现 `WIP` / `Draft` / `[skip ci]`——用 GitHub 的草稿状态表达。

正例：`fix(codex): read only the first session_meta in a rollout`
反例：`Fixed bugs`、`WIP: codex stuff`、`feat: Update Island.`

### 描述

打开 PR 时会自动填入 [PR 模板](.github/pull_request_template.md)。保留所有小节，不适用就写 `N/A`，
不要删除。PR 标题与正文**只用英文**。模板包含：

| 小节 | 内容 |
|---|---|
| **Summary** | 1–3 句说明改了什么，用户可感知的效果放前面。 |
| **Motivation** | 为什么改——关联 issue / 提案（`Closes #12`、`Implements #34`）。 |
| **Changes** | 按模块分组的要点（`EurekaIngest`、`EurekaApp`……）。 |
| **Verification** | 实际运行的命令及结果、手工检查，UI 改动附截图。 |
| **Risk & rollback** | 触及的不变量、迁移 / 数据影响、如何回退。 |
| **Checklist** | 完成定义（DoD）勾选项。 |

### 规模

除生成文件、fixture 和纯翻译外，改动尽量少于 400 行。更大的工作拆成**堆叠 PR（stacked PRs）**：
每个 PR 以前一个分支为目标，在描述中写明 `Depends on #N`，按顺序合并（父 PR 合并后改为指向 `main`）。

### 合并

- 只用 squash merge。squash 信息为 PR 标题加精简后的正文。
- 合并条件：至少一个 approve、所有讨论已解决、checklist 完成、分支已 rebase 到最新 `main`。
- 获得批准后由作者合并，除非作者请维护者代为合并。
- 用户可感知的改动在 `CHANGELOG.md` 的 `## [Unreleased]` 下添加条目（或由发版 PR 统一收集——
  请在描述中说明）。

## 草稿 PR（Draft）

希望在完成前获得反馈时开**草稿 PR**：验证思路、分享 spike，或暂存父 PR 尚未合并的堆叠 PR。

规则：

1. 以草稿形式创建（`gh pr create --draft`，或 *Create draft pull request*）——不要用标题里的
   `WIP:` 表达意图。
2. 标题照样遵循 Conventional Commits；描述使用同一模板，并在 *Summary* 开头加一行 **Status**：
   哪些已完成、还缺什么、希望得到哪方面的反馈。
3. 草稿 PR 允许检查失败、测试缺失。评审者只给方向层面的反馈，不逐行评审，不 approve。
4. 转为 **Ready for review** 之前：checklist 全部勾选，删除 Status 行，整理提交历史（合并 fixup），
   *Verification* 填入真实输出。
5. 30 天无活动的草稿 PR 可能被关闭；恢复工作时重新打开即可。

## 代码评审

**作者**

- 先自己审一遍 diff，对出人意料的地方主动留言说明。
- 回应每一条评论：要么推送修改，要么解释为何不改。由评审者 resolve 讨论。
- 评审期间以追加提交的方式修改（除了 rebase 到 `main`，评审中不要 force-push）；squash 时它们会被合并。

**评审者**

- 争取在 2 个工作日内首次回复。
- 按以下顺序检查：正确性与不变量（`CLAUDE.md`）、数据安全（不写外部 Agent 的文件、无密钥）、
  测试、可读性、风格。
- 非阻塞意见以 `nit:` 开头。只有阻塞问题才用 *Request changes*，并说明怎样才能解除阻塞。

## 编码规范速览

完整内容见 `CLAUDE.md`（架构与不变量）和 `AGENTS.md`（提交与发版）。

| 主题 | 规则 |
|---|---|
| 代码注释 | **只用英文**——文档注释、行内注释、`MARK`、测试注释、脚本注释。由 `make lint-comments` 强制检查。 |
| UI 文案 | 英文为源，通过 `L10n.text(_:zhHans:)` / `L10n.format`；简体中文写在 `zhHans` 参数中。不要把 `L10n.text` 缓存进 `static let`。 |
| 测试标题 | 可以保留中文（它们是字符串字面量，不是注释）。 |
| 提交、PR、Release、`CHANGELOG.md` | 只用英文。 |
| 模块边界 | `app → {EurekaIngest, EurekaUsage, EurekaSync} → EurekaStore → EurekaKit`；`EurekaKit` 无 IO、无 AppKit；`eureka-relay` 零依赖。 |
| 依赖 | 只有 Sparkle，精确锁定，仅 app target 链接。新增依赖需要已接受的提案。 |
| Relay | 始终 `exit 0`、stdout 静默、< 50 ms、不启动子进程（文档化的 notify 链式调用除外）。 |
| 测试 | 每个行为变更都要在手写测试框架（`Tests/EurekaTestsRunner`）中附带测试。 |

## 安全

- **不要**为漏洞公开提 issue。请使用 GitHub 的
  [私密漏洞报告](https://github.com/vinlee19/lulu-lumei-dock/security/advisories/new)。
- 绝不提交 `.env*` 文件、密钥、证书、token 或钥匙串导出。
- 读取凭证的代码必须通过环境变量或钥匙串获取，绝不硬编码，也不得打印到日志。

提交贡献即表示你同意以 [MIT License](LICENSE) 授权你的贡献。
