# 研发流程

[English](DEVELOPMENT_WORKFLOW.md) · 简体中文

每个改动从 issue 到发版都要经过的研发闭环。它与以下文档互补：
[CONTRIBUTING.zh-CN.md](../CONTRIBUTING.zh-CN.md)（如何提 issue、提案和 PR）、
[`AGENTS.md`](../AGENTS.md)（提交、PR 与发版规范）、[`CLAUDE.md`](../CLAUDE.md)（架构与关键不变量）。
构建命令见 [BUILD.md](BUILD.md)。

> 以英文版 [DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md) 为准；两者冲突时以英文版为准，并请提 PR 同步。

## 目录

1. [生命周期总览](#1-生命周期总览)
2. [分支与工作树](#2-分支与工作树)
3. [实现改动](#3-实现改动)
4. [测试](#4-测试)
5. [本地验证关卡](#5-本地验证关卡)
6. [安全地使用真实数据](#6-安全地使用真实数据)
7. [提交](#7-提交)
8. [PR 与评审](#8-pr-与评审)
9. [合并与发版](#9-合并与发版)
10. [完成定义（DoD）](#10-完成定义dod)
11. [AI 编码代理](#11-ai-编码代理)

## 1. 生命周期总览

```
 Issue ──► （必要时：提案 + 设计文档）──► 分支 / 工作树
                                              │
             ┌────────────────────────────────┘
             ▼
   实现 + 测试 ──► 本地验证关卡 ──► 草稿 PR（可选）
                                       │
                                       ▼
   发版 ◄── Squash 合并到 main ◄── 评审 ◄── Ready for review
```

| 阶段 | 出口条件 |
|---|---|
| Issue | 问题达成共识；已指派负责人。 |
| 提案 | 维护者标记为 *Accepted*（仅在[需要提案](../CONTRIBUTING.zh-CN.md#何时必须提案)时）。 |
| 实现 | 在独立分支上完成代码与测试。 |
| 验证 | 本地通过全部[关卡](#5-本地验证关卡)。 |
| 评审 | ≥ 1 个 approve，所有讨论已解决。 |
| 合并 | 已 squash 合并；`main` 构建与测试全绿。 |
| 发版 | 按 `AGENTS.md` 推送 `vX.Y.Z` tag；CI 发布。 |

## 2. 分支与工作树

- `main` 始终可发布。任何人都不直接推送 `main`；一切改动都通过 squash 合并的 PR 进入。
- 在短生命周期分支上工作，命名为 `<type>/<简短-kebab-描述>`（`fix/opencode-watermark`、
  `docs/contributing-guide`）。合并后删除分支。
- 保持分支基于 `main` rebase（`git fetch && git rebase origin/main`）。不要把 `main` merge 进特性分支。
- **每个任务优先使用独立的 git worktree**，让并行工作（包括 AI 代理会话）永不共享工作目录：

  ```bash
  git worktree add .worktrees/<branch> -b <branch> origin/main
  cd .worktrees/<branch>
  ```

  `.worktrees/` 与 `.claude/worktrees/` 已被 git 忽略。完成后移除：
  `git worktree remove .worktrees/<branch>`。
- **堆叠工作**：B 依赖尚未合并的 A 时，从 A 拉出 B，B 的 PR 以 A 为目标并写明 `Depends on #A`，
  A 合并后把 B 改为指向 `main`。
- 在共享的检出目录中只暂存自己的改动（`git add -p`）——绝不使用 `git add -A` / `git add .`。

## 3. 实现改动

写代码前，重读 `CLAUDE.md` 中与所改模块相关的部分。尤其注意：

- **遵守模块依赖方向**：`app → {EurekaIngest, EurekaUsage, EurekaSync} → EurekaStore → EurekaKit`。
  `EurekaKit` 保持纯净（无 IO、无 AppKit）。`EurekaInstall` 只依赖 `EurekaKit`。`eureka-relay` 零依赖。
- **遵守关键不变量**。改动触及任何一条时需要提案，且 PR 必须说明该不变量如何依然成立。
- **外部 Agent 的数据只读。** 以只读方式打开它们的数据库，且绝不使用 `immutable=1`；除 hook 安装器外
  绝不写入它们的 transcript 或配置——安装器只增删带 relay 名称的条目，并先做备份。
- **代码与日志中不出现密钥。** 凭证来自环境变量或钥匙串，且绝不打印。
- **文案与注释**：
  - 用户可见文案：`L10n.text("English", zhHans: "中文")` / `L10n.format`。英文为源语言和默认语言。
  - 代码注释：**只用英文**，解释"为什么"而不是"是什么"。`make lint-comments` 会在注释含中日韩文字时
    失败；字符串字面量不受限制。
- **小步、可回退。** 实验性功能优先默认关闭（参考 `AntigravityExperiment`）。
- 未经接受的提案，**不得新增依赖**。

## 4. 测试

项目使用手写测试框架（Command Line Tools 不带 XCTest）：

- 测试套件位于 `Tests/EurekaTestsRunner/*Tests.swift`；每个套件是一个调用 `expect` / `expectEqual`
  的函数（见 `Harness.swift`）。
- **新套件必须在** `Tests/EurekaTestsRunner/main.swift` **中注册**，否则永远不会执行。
- Fixture 放在 `Tests/EurekaTestsRunner/Fixtures/`，通过 `fixtureURL` / `fixtureData` 加载。Fixture
  必须是合成数据或已完全脱敏——绝不复制真实 transcript、邮箱或 token。
- 没有测试过滤器。只想迭代某个套件时，临时注释掉 `main.swift` 里的其他调用——提交前务必恢复。
- Bug 修复先写一个能复现问题的失败测试（红 → 绿）。
- 纯逻辑（`EurekaKit`、decoder、scanner、installer）直接测试；UI 通过离屏渲染验证（见下一节）。

## 5. 本地验证关卡

在把 PR 标记为 **Ready for review** 之前运行以下检查，并把结果贴进 PR 的 *Verification* 小节。

**始终必需**

| 关卡 | 命令 | 通过条件 |
|---|---|---|
| 构建 | `make build` | 无错误；所改文件无新增 warning。 |
| 测试 | `make test` | `N passed, 0 failed`。 |
| 注释语言 | `make lint-comments` | 退出码 0。 |
| Diff 整洁 | `git diff origin/main --stat` | 只包含与本改动相关的文件。 |

**改动涉及对应领域时必需**

| 领域 | 命令 | 通过条件 |
|---|---|---|
| 用量扫描 / 定价 | `Scripts/check-usage-against-ccusage.sh` | 与 ccusage 偏差 `0.00%`。 |
| 灵动岛状态 | `make demo` 或 `swift run eureka --render-previews <dir>` | 每个状态都能渲染；PR 附截图。 |
| 侧栏 / 页面 / 设置 | `swift run eureka --render-pages <dir>` 与 `--render-shell <dir>`（加 `--style brutal`） | 附浅色 + 深色、两种风格的截图。 |
| 回合谱系图 | `swift run eureka --render-lineage <dir>` | golden 与 live 图都能渲染。 |
| Hooks / 安装器 | `swift run eureka --hooks-status` | 状态符合预期；未改动他人条目。 |
| Relay | `swift run eureka-relay inject --event stop --session demo` | 退出码 0、stdout 为空、事件出现。 |
| 限额 | `swift run eureka --limits-snapshot` | 快照可解码；失败返回 `nil` 而不是崩溃。 |
| MCP | `swift run eureka --mcp-inspect <name>` | 对测试服务器探测成功。 |
| 打包 / 发版 | `make app` | 应用组装成功并能启动。 |

## 6. 安全地使用真实数据

本机上应用的数据库和各 Agent 的文件都是真实且不可替代的历史。

- 绝不让实验、脚本或子代理直接操作线上的
  `~/Library/Application Support/Eureka/eureka.sqlite`。先复制一份再用：

  ```bash
  sqlite3 ~/Library/Application\ Support/Eureka/eureka.sqlite \
    ".backup '/tmp/eureka-copy.sqlite'"
  EUREKA_DB_PATH=/tmp/eureka-copy.sqlite swift run eureka --usage-snapshot
  ```

- 绝不手动对任何数据库执行 `DROP`、`TRUNCATE` 或无范围限定的 `DELETE`。schema 变更通过代码完成，
  并配套迁移与测试。
- Hook 安装器在修改配置前会写 `*.bak.eureka.*` 备份；新增安装器也必须保持这一行为。
- 截图和日志附到 PR 或 issue 之前先脱敏。

## 7. 提交

完整规则见 [`AGENTS.md`](../AGENTS.md#commit-messages)。简述：

- `<type>(<scope>): <imperative summary>`，英文、小写开头、无句号、≤ 72 字符；可选正文说明
  "改了什么"和"为什么"。
- 每个提交只做一件逻辑上的事；绝不把重构和行为变更混在一起。
- 机械性改动（格式化、重命名、翻译）单独提交，方便评审者跳过。
- 不要提交构建产物（`.build/`、`dist/`）、本地工作树或个人配置。

## 8. PR 与评审

1. 推送分支并用模板创建 PR——想尽早获得反馈就开**草稿**（[规则](../CONTRIBUTING.zh-CN.md#草稿-prdraft)）。
2. 填写所有小节；*Verification* 里放真实的命令输出。
3. 请求评审。回应每一条评论；由评审者 resolve 讨论。
4. 只有满足[完成定义](#10-完成定义dod)后才标记 **Ready for review**。

## 9. 合并与发版

- 获批且已 rebase 后 squash 合并；PR 标题即 `main` 上的提交。
- 用户可感知的改动在 `CHANGELOG.md` 的 `[Unreleased]` 下添加条目。
- 发版遵循 [`AGENTS.md` → Release procedure](../AGENTS.md#release-procedure)：
  changelog → 更新 `VERSION` → `make pricing-catalog` → `make build && make test` → 推送 `main`
  → 打 tag `vX.Y.Z` → CI 构建、签名并发布 → 完善 Release 页面。
- Hotfix 走同样的路径：一个 `fix(...)` PR 加一个补丁版本号。

## 10. 完成定义（DoD）

以下**全部**满足时，改动才算完成：

- [ ] 已关联 issue / 提案，且满足其验收标准。
- [ ] 代码遵守模块依赖方向和 `CLAUDE.md` 中的每一条关键不变量。
- [ ] 测试覆盖新行为；`make test` 报告 0 失败。
- [ ] `make build` 与 `make lint-comments` 通过。
- [ ] 第 5 节中相关领域的关卡通过，且 PR 中附有证据。
- [ ] 用户可见文案通过 `L10n` 本地化；注释为英文。
- [ ] 行为、命令或不变量有变化时已更新文档（`README.md`、`README.zh-CN.md`、`CLAUDE.md`、`docs/`）。
- [ ] 用户可感知的改动已更新 `CHANGELOG.md`。
- [ ] diff 中没有任何密钥、个人数据或真实 transcript。

## 11. AI 编码代理

代理（Claude Code、Codex……）遵守同样的流程：

- 在独立的工作树和分支上工作；绝不直接在 `main` 上改。
- 先读 `AGENTS.md` 和 `CLAUDE.md`；它们是规范与不变量的权威来源。
- 运行验证关卡并报告真实输出——没跑过的关卡绝不声称通过。
- 检查数据的子代理通过 `EUREKA_DB_PATH` 使用数据库副本，绝不碰线上文件。
- 只在被要求时提交，且只暂存任务涉及的文件。
