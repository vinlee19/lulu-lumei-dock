# Prompt Library Design Document

> 从会话历史中提取用户提问，构建可浏览、可搜索、可复用的 Prompt 库。

## 0. 修订记录（2026-09-05，对照实现回填）

本文是 MVP（v0.30.0）的设计；之后两批工作有意偏离了其中几条，实现以下面为准：

- **§1.3 / §5.4 「发送到终端」改为直接启动会话**：实现是 `cd '<cwd>' && claude '<prompt>'`
  （`PromptLaunchCommand`），不再是"复制 + 开终端让用户手动粘贴"。用户明确点了"启动"，
  多一步粘贴只是摩擦；prompt 走 POSIX 单引号转义，多行用 `$'\n'` 拼接以适配 AppleScript
  `do script`。只开放 claude / codex（其余 CLI 是否接受位置参数 prompt 未实勘）。
- **§3.4 步骤 4 的 stale 标记没有做；「删除」改为软删除**：`prompts.hidden_at`（幂等补列，
  不升 schema 版本）。硬删会被会话下一次增量提取的 upsert 原样复活，所以移除必须像收藏一样
  是留在行上的用户事实；所有读路径按 `hidden_at IS NULL` 过滤。会话消失的行仍然保留。
- **阶段三 #14「自动标签」实现为复用价值分类而不是标签**：`PromptClassifier` 内存派生五类
  （noise / trivial / followup / instruction / paste），阈值来自本机 2,395 条实勘（≤12 字符的
  418 条全是"继续"类；12.4% 是 `<command-name>` 等伪用户消息；最长一条 1.98MB 日志粘贴）。
  分类不入库，阈值迭代不需要刷库。噪音在采集端就剥掉（`TurnSlicer.realPrompt`），
  存量噪音行只隐藏不删。
- **§3.9 / 阶段二 #13「内容分组」实现为「高频重复」段**：归一化指纹（前 512 字符）聚类、
  ≥3 次成组，除噪除琐碎后再聚，带 ×N / 跨项目 / N 次费劲徽章。
- **阶段二 #10 详情页多出两个动作**：「升级为技能」（任意源，写完整 SKILL.md）与「升级为指令」
  （claude 追加 `~/.claude/CLAUDE.md`、codex 追加 `AGENTS.md` / `AGENTS.override.md`，都落指令页；
  落点由 `PromptInstructionDestination` 裁定，正文由 `EurekaInstall.PromptGraduationDocument` 生成）。
  最初 Claude 分支写 `~/.claude/memories/<slug>.md`，但官方 `.claude` 目录参考与 memory 文档里
  没有这个目录 —— Claude Code 只加载 CLAUDE.md 系列、`.claude/rules/` 与 `projects/<project>/memory/`
  自动记忆 —— 写进去 Claude 永远读不到，故改为追加 CLAUDE.md。（Eureka「新建记忆」仍写
  `~/.claude/memories/`，那是 Eureka 私有笔记，与本条无关，待另行决定。）
- **新增评价体系**（本文未规划）：`prompt_eval` 派生表（schema v24），设计见
  `docs/superpowers/plans/2026-08-24-prompt-evaluation.md`，方法论调研见
  `docs/research/2026-08-24-prompt-evaluation-methods.md`。
- **未做**：阶段三 #15 会话详情页的"本会话的 prompt"卡（详情页 TOC 已列出全部用户消息，
  算部分替代）、#16 热门 prompt 排行（周报的"复用最多"是部分替代）。§7 的两条测试
  （FTS 命中 prompt、命令面板含 `.prompt`）在 `KnowledgeLinkTests` 里补齐。

## 1. 背景与目标

### 1.1 问题

开发者每天向多个 AI Agent（Claude、Codex、ZCode 等）发送大量 prompt。这些 prompt 散落在各个会话的 transcript 里，用完即弃。当遇到类似任务时，开发者只能凭记忆翻找历史会话，或者从头重写。

### 1.2 目标

把过去发送过的 prompt 变成**可复用的资产**：

- **聚合**：从所有 Agent 的会话中提取用户提问，统一呈现
- **搜索**：按关键词、来源、项目、时间快速定位历史 prompt
- **复用**：一键复制到剪贴板，或直接在新终端里启动新会话
- **回溯**：跳转到 prompt 所属的原始会话上下文
- **收藏**：标记常用 prompt，按分类组织

### 1.3 非目标

- 不做 prompt 版本管理（不是 prompt 编辑器）
- 不做 prompt 执行/注入到运行中的 Agent（只做复制和启动）
- 不做 prompt 分享/协作（个人工具）
- 不替代会话浏览（会话页签仍是完整的 transcript 查看入口）

## 2. 数据来源分析

### 2.1 可提取的来源

`TranscriptReader.load(session:)` 已支持 14 个 Agent 源。其中用户提问（`role == .user`）可提取的有 12 个：

| 来源 | 提取方式 | 备注 |
|---|---|---|
| Claude | JSONL 逐行解析 | ✅ |
| Codex | JSONL rollout 解析 | ✅ |
| OpenCode | SQLite messages 表 | ✅ 共享 DB |
| Grok | JSONL + events.jsonl | ✅ |
| Kimi | JSONL 解析 | ✅ |
| Gemini | JSONL 解析（去重） | ✅ |
| Qwen | JSONL 解析 | ✅ |
| Hermes | SQLite messages 表 | ✅ 共享 DB |
| CodeBuddy | JSONL 解析 | ✅ |
| Qoder | JSONL 解析（Claude 式封装） | ✅ |
| Cursor | SQLite cursorDiskKV | ✅ 共享 DB |
| ZCode | SQLite（复用 opencode loader） | ✅ 共享 DB |
| Antigravity | protobuf 二进制 | ❌ 不可提取 |
| Trae | SQLCipher 加密 | ❌ 不可提取 |

### 2.2 提取逻辑

复用 `TranscriptReader.load(session:).messages`，过滤 `role == .user`。这与 `TranscriptSearchIndexer.docs(for:)`（`TranscriptSearchIndexer.swift:63-76`）的逻辑完全一致，只是去掉 assistant 分支：

```swift
let messages = TranscriptReader.load(session: session).messages
let prompts = messages.compactMap { message -> ExtractedPrompt? in
    guard message.role == .user else { return nil }
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return ExtractedPrompt(
        sessionId: session.id,
        source: session.source,
        messageIdx: message.id,
        text: text,
        timestamp: message.timestamp,
        cwd: session.cwd
    )
}
```

### 2.3 会话发现

复用 `SessionBrowserService` 已建立的会话索引（`sessionsById`），不需要独立的发现逻辑。Prompt 提取在会话扫描完成后触发，读取 `service.transcript` 或按需调用 `TranscriptReader.load`。

## 3. 架构设计

### 3.1 模块归属

遵循项目的单向依赖规则（`CLAUDE.md:56`）：

```
app -> EurekaIngest -> EurekaStore -> EurekaKit
```

| 层 | 模块 | 职责 |
|---|---|---|
| **EurekaKit** | `Models/PromptEntry.swift` | 纯值类型定义 |
| **EurekaStore** | `PromptsRepo.swift` + Schema | SQLite 持久化 |
| **EurekaIngest** | `PromptExtractor.swift` | 从 transcript 提取 prompt |
| **EurekaApp** | `PromptsService.swift` + `PromptsView.swift` | 服务层 + UI |

### 3.2 存储策略：SQLite 表

不采用 Plans 的"物化到 .md 文件"模式，原因：

1. Prompt 是消息级数据（短文本、数量大），不是文件级产物
2. 需要持久化用户标注（收藏、标签、使用次数），文件模式不适合存这些
3. SQLite 支持高效去重、增量更新、结构化查询
4. 与 `knowledge_fts` 共享搜索基础设施

### 3.3 数据模型

#### PromptEntry（EurekaKit 纯值类型）

```swift
public struct PromptEntry: Equatable, Sendable, Identifiable {
    /// 主键：source + sessionId + messageIdx 的确定性哈希
    public let id: String
    public let source: AgentSource
    public let sessionId: String
    /// 在 transcript 中的消息序号，用于跳转回会话
    public let messageIdx: Int
    public let text: String
    public let timestamp: Date?
    public let cwd: String?
    /// 首行摘要（列表展示用）
    public var title: String { /* text 首行，截断到 60 字 */ }
    /// 用户标注
    public var tags: [String]
    public var favorite: Bool
    /// 复用次数（每次复制/发送时 +1）
    public var useCount: Int
    public var lastUsedAt: Date?
}
```

`id` 的生成规则：`"\(source.rawValue):\(sessionId):\(messageIdx)"`，确定性、跨扫描稳定。

#### SQLite Schema

```sql
-- Schema.swift 新增，version 22 -> 23
-- 派生表（可从 transcript 重建），加入 DROP 块
CREATE TABLE IF NOT EXISTS prompts (
    id TEXT PRIMARY KEY,          -- "source:sessionId:msgIdx"
    source TEXT NOT NULL,
    session_id TEXT NOT NULL,
    message_idx INTEGER NOT NULL,
    text TEXT NOT NULL,
    timestamp REAL,
    cwd TEXT,
    favorite INTEGER NOT NULL DEFAULT 0,
    tags TEXT NOT NULL DEFAULT '[]',  -- JSON array
    use_count INTEGER NOT NULL DEFAULT 0,
    last_used_at REAL,
    first_seen REAL NOT NULL,       -- 首次提取时间（用于排序）
    updated_at REAL NOT NULL        -- 最后更新时间
);
CREATE INDEX IF NOT EXISTS idx_prompts_source ON prompts(source);
CREATE INDEX IF NOT EXISTS idx_prompts_session ON prompts(session_id);
CREATE INDEX IF NOT EXISTS idx_prompts_favorite ON prompts(favorite);
CREATE INDEX IF NOT EXISTS idx_prompts_first_seen ON prompts(first_seen DESC);
```

注意：`favorite`、`tags`、`use_count`、`last_used_at` 是**用户写入的事实**，提取时保留已有值。提取流程用 `INSERT OR IGNORE` 写入新行（不覆盖已有用户标注），`text`/`timestamp` 用 `UPDATE` 刷新（会话可能追加内容）。

#### FTS 集成

扩展 `knowledge_fts` + `knowledge_docs`，`kind = "prompt"`：

```sql
-- knowledge_docs 已有列：id, kind, path, source, title, project, size, mtime
-- prompt 的 path = prompt.id（"source:sessionId:msgIdx"）
-- prompt 的 title = prompt.title（首行摘要）
-- prompt 的 project = prompt.cwd 的 lastPathComponent
```

这样 `KnowledgeSearchRepo.search()` 和 `CommandPaletteService` 无需改动搜索逻辑，只需在 `kind` 映射里加一个 `"prompt"` 分支。

### 3.4 提取流程

#### PromptExtractor（EurekaIngest）

```swift
public enum PromptExtractor {
    public struct ExtractResult {
        public let prompts: [PromptEntry]
        public let scannedSessions: Int
    }

    /// 从给定会话列表提取所有用户 prompt。
    /// 用 SessionBrowserService 已加载的 transcript 缓存优先，缺的按需 load。
    public static func extract(
        sessions: [AgentSessionInfo]
    ) -> ExtractResult {
        var prompts: [PromptEntry] = []
        for session in sessions {
            let messages = TranscriptReader.load(session: session).messages
            for message in messages where message.role == .user {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                prompts.append(PromptEntry(
                    id: "\(session.source.rawValue):\(session.id):\(message.id)",
                    source: session.source,
                    sessionId: session.id,
                    messageIdx: message.id,
                    text: text,
                    timestamp: message.timestamp,
                    cwd: session.cwd,
                    tags: [], favorite: false, useCount: 0, lastUsedAt: nil
                ))
            }
        }
        return ExtractResult(prompts: prompts, scannedSessions: sessions.count)
    }
}
```

#### 增量扫描

采用 `transcript_fts` 的 fingerprint 模式（`SearchRepo.fileFingerprints()`）：

1. 扫描前读取 `prompts` 表中已有的 `(session_id, source) -> (count, max_first_seen)` 映射
2. 对每个会话，比较 `lastActiveAt` 与上次扫描时间；未变化则跳过
3. 变化的会话：删除该 `session_id` 的旧行，重新提取写入
4. 已不在会话列表中的 `session_id`：保留行（标记 `stale`，不自动删除--用户的收藏可能指向已结束的会话）

这比 Plans 的全量 materialize 轻得多：只重解析变化的会话，且复用 `TranscriptReader` 已有的解析能力。

### 3.5 服务层

#### PromptsService（EurekaApp）

镜像 `PlansService` 的结构：

```swift
final class PromptsService: ObservableObject {
    @Published private(set) var prompts: [PromptEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanPhase: String?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var totalCount = 0
    @Published private(set) var favoriteCount = 0
    var searchText: String = "" { didSet { rebuild() } }
    var focusId: String?

    private let queue = DispatchQueue(label "com.vinlee.eureka.prompts", .userInitiated)
    private let store: EurekaStore
    private let sessionBrowser: SessionBrowserService
    private var all: [PromptEntry] = []

    // 依赖注入：需要 SessionBrowserService 的会话列表
    init(store: EurekaStore, sessionBrowser: SessionBrowserService) { ... }

    /// 幂等刷新：force=false 时仅首次执行
    func refresh(force: Bool = false) { ... }

    /// 列表过滤：搜索 + 收藏过滤 + 来源过滤
    private func rebuild() { ... }

    /// 供 CommandPaletteService 消费的全量快照
    func knowledgeSnapshot() -> [PromptEntry] { all }

    // 用户操作
    func toggleFavorite(_ id: String) { ... }
    func setTags(_ id: String, tags: [String]) { ... }
    func incrementUseCount(_ id: String) { ... }
    func delete(_ id: String) { ... }  // 从库中移除（不删源会话）

    // 跨页跳转
    func revealPrompt(_ id: String) { focusId = id }
    func consumeFocus() { ... }
}
```

关键差异于 PlansService：

1. **依赖 SessionBrowserService**：提取需要会话列表。扫描时机跟随会话扫描完成（Combine 订阅 `sessionBrowser.$scanning` 或 `sessionBrowser.$lastScanAt`）。
2. **用户可写入**：`favorite`/`tags`/`delete` 直接写 SQLite，不经过文件系统。
3. **不物化到磁盘**：没有 staging 目录，没有 .md 文件。

### 3.6 UI 层

#### PromptsView

复用 `SkillMemoryView`/`PlansView` 的布局骨架：

```
┌──────────────────────────────────────────────────┐
│  Prompt 库                  [搜索...] [刷新] [布局] │
│  ────────────────────────────────────────────────  │
│  📊 统计卡：总计 342 · 收藏 12 · 本周新增 28        │
│  ────────────────────────────────────────────────  │
│  [全部] [收藏] [Claude] [Codex] [ZCode] ...        │  ← 来源筛选 + 收藏筛选
│  ────────────────────────────────────────────────  │
│  ┌─────────────────────────────────────────────┐   │
│  │ ⭐ 修复用户认证模块的 JWT 过期逻辑           │   │
│  │ Claude · auth-service · 08-22 14:30          │   │  ← 列表行
│  │ #重构 #认证                  已用 3 次       │   │
│  └─────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────┐   │
│  │    写一个单元测试覆盖边界情况                │   │
│  │ Codex · ci · 08-21 09:15                     │   │
│  └─────────────────────────────────────────────┘   │
│  ...                                               │
└──────────────────────────────────────────────────┘
```

#### PromptDetailView

点击列表行进入详情：

```
┌──────────────────────────────────────────────────┐
│ ← ⭐ 修复用户认证模块的 JWT 过期逻辑              │
│ ────────────────────────────────────────────────  │
│  Claude Code · auth-service                       │
│  2026-08-22 14:30:12 · 会话 sess_6e8             │
│  ────────────────────────────────────────────────  │
│                                                   │
│  我们的 JWT token 在过期后没有自动刷新，导致       │
│  用户在长时间使用后被登出。请检查 auth/middleware  │
│  里的 token 验证逻辑，添加 refresh token 机制。    │
│  需要覆盖的边界情况：                              │
│  1. token 即将过期但仍在使用                       │
│  2. refresh token 也已过期                         │
│  3. 并发请求同时刷新                               │
│                                                   │
│  ────────────────────────────────────────────────  │
│  标签：[重构] [认证] [+ 添加标签]                 │
│  ────────────────────────────────────────────────  │
│  [📋 复制] [▶ 发送到终端] [↗ 在会话中查看]        │
│  ────────────────────────────────────────────────  │
│  已使用 3 次 · 最后使用 08-22 15:00               │
└──────────────────────────────────────────────────┘
```

三个操作按钮：

1. **复制**：`NSPasteboard.general.setString(prompt.text)` + `useCount += 1`
2. **发送到终端**：复制 + 打开 Terminal.app（复用 `resumeInTerminal` 的 osascript 机制，但不带 `--resume`，只粘贴 prompt 供用户确认后回车）
3. **在会话中查看**：`NotificationCenter.post(name: .eurekaRevealSession, object: sessionId)` + `sessionBrowser.revealMessage(sessionId:messageIdx:)`

#### 侧边栏集成

在 `PopoverRootView.swift` 的侧边栏"知识库"分组加入新 Tab：

```
知识库
  技能
  记忆
  指令
  计划
  Agent
  MCP
  Prompt 库    ← 新增
```

### 3.7 命令面板集成

`CommandPalette.Kind` 新增 `.prompt` 分支：

```swift
// EurekaKit/CommandPalette.swift
enum Kind: String, CaseIterable {
    case session, skill, memory, instruction, plan, prompt  // ← 新增
    // ...
}
```

`CommandPaletteService.perform(_:)` 的 metadata pass 增加：

```swift
// 从 promptsService.knowledgeSnapshot() 搜索 title/text
for prompt in promptsService.knowledgeSnapshot() {
    if prompt.title.lowercased().contains(lowered) || prompt.text.lowercased().contains(lowered) {
        hits.append(.init(kind: .prompt, key: prompt.id,
                          title: prompt.title,
                          subtitle: prompt.source.displayName,
                          snippet: nil))
    }
}
```

FTS pass 的 kind 映射增加：

```swift
"prompt" -> .prompt
```

路由：

```swift
case .prompt:
    NotificationCenter.default.post(name: .eurekaRevealPrompt, object: hit.key)
```

`PopoverRootView` 消费：

```swift
.eurekaRevealPrompt -> navigation.tab = .prompts; promptsService.revealPrompt(id)
```

### 3.8 全文搜索集成

扩展现有 `KnowledgeSearchIndexer`：

```swift
// KnowledgeSearchIndexer.swift
static func docs(skills:memories:plans:prompts:) -> [Doc] {
    // ... 现有 skills/memories/plans ...
    for prompt in prompts {
        docs.append(Doc(
            kind: "prompt",
            path: prompt.id,          // 用 prompt.id 作为 path
            source: prompt.source.rawValue,
            title: prompt.title,
            project: prompt.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent },
            size: Int64(prompt.text.utf8.count),
            mtime: prompt.timestamp?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        ))
    }
}
```

`AppDelegate.reindexKnowledge()` 扩展：在 skills + plans 都扫描完成后，加入 `promptsService.knowledgeSnapshot()` 作为第三输入。保持"三方都扫描完才索引"的防护逻辑。

### 3.9 去重策略

同一 prompt 文本可能跨会话重复出现（用户复制粘贴复用）。去重策略：

- **存储层不去重**：每条 `(source, sessionId, messageIdx)` 是独立的库条目，保留来源上下文
- **展示层可选聚合**：列表默认按时间倒序展示全部条目；提供"按内容分组"视图，相同文本的条目折叠成一组，显示"出现 N 次 · Claude×2 · Codex×1"

这比存储层去重更灵活：用户可以看到同一个 prompt 在不同 Agent 上的效果差异。

## 4. 实现计划

### 阶段一：最小可用（MVP）

目标：能浏览、搜索、复制历史 prompt。

| 步骤 | 文件 | 工作量 |
|---|---|---|
| 1. 数据模型 | `EurekaKit/Models/PromptEntry.swift` | 小 |
| 2. Schema + Repo | `EurekaStore/Schema.swift` + `PromptsRepo.swift` | 中 |
| 3. 提取器 | `EurekaIngest/PromptExtractor.swift` | 小 |
| 4. 服务层 | `EurekaApp/PromptsService.swift` | 中 |
| 5. UI 列表 | `EurekaApp/StatusBar/PromptsView.swift` | 中 |
| 6. 侧边栏集成 | `PopoverRootView.swift` | 小 |
| 7. 命令面板 | `CommandPalette.swift` + `CommandPaletteService.swift` | 小 |
| 8. FTS 集成 | `KnowledgeSearchIndexer.swift` + `AppDelegate.swift` | 小 |

### 阶段二：复用增强

| 步骤 | 描述 |
|---|---|
| 9. 收藏 + 标签 | SQLite 写入 + UI 交互 |
| 10. 详情页 | PromptDetailView + 跨页跳转 |
| 11. 发送到终端 | osascript 打开 Terminal + 粘贴 |
| 12. 使用计数 | 复制/发送时自增 |
| 13. 内容分组视图 | 相同文本折叠展示 |

### 阶段三：体验打磨

| 步骤 | 描述 |
|---|---|
| 14. 自动标签 | 从 prompt 文本启发式推断类别（调试/重构/测试/架构） |
| 15. 会话产出关联 | 在会话详情页显示"本会话的 prompt"卡（类似现有的"本会话产出"） |
| 16. 热门 prompt 排行 | 按使用次数 + 频率排序的推荐区 |

## 5. 关键设计决策

### 5.1 为什么选 SQLite 而非物化文件

Plans 选择物化 `.md` 文件是因为 plan 本身就是文档形态（有标题、步骤列表、checklist），用户可能想用外部编辑器打开。Prompt 是短文本消息，没有文档结构，且数量大（一个活跃开发者一个月可能产生上千条），文件系统不适合存这么多小文件。SQLite 的去重、增量更新、标签查询、收藏过滤都是原生能力。

### 5.2 为什么复用 knowledge_fts 而非新建 FTS 表

`knowledge_fts` 的 `kind` 列已经支持多类型（skill/memory/instruction/plan）。加一个 `"prompt"` 不需要 schema 变更，且让命令面板的搜索自动覆盖 prompt，无需在 `CommandPaletteService` 里加第二条 FTS 查询路径。

### 5.3 为什么保留已结束会话的 prompt

用户收藏的 prompt 可能来自很久以前的会话，甚至源文件已被删除。删除这些行会让收藏指向空指针。策略是：提取扫描时不删除"会话已不存在"的行，只在用户主动删除单个 prompt 时才删行。这跟 `SearchRepo.prune` 的"文件没了就删"不同，因为 prompt 库是用户策展的，不是纯派生索引。

### 5.4 发送到终端的实现

不直接在终端里执行 prompt（那等于自动启动一个 Agent 会话，超出了观测工具的边界）。而是：

1. 把 prompt 复制到剪贴板
2. 打开 Terminal.app（osascript `do script ""` 创建新窗口）
3. 用户手动 `⌘V` 粘贴、按回车

这样用户有机会在执行前确认/修改 prompt，且不会意外启动 Agent。

### 5.5 扫描时机

跟随 `SessionBrowserService` 的扫描周期，不独立扫描。`SessionBrowserService.refresh()` 完成后（`scanning` 从 true 变 false），触发 `PromptsService.refresh()`。首次扫描在 App 启动后的 warm-up 序列里排在使用量扫描之后。

## 6. 风险与约束

| 风险 | 缓解 |
|---|---|
| 大量会话导致首次提取慢 | 增量扫描：只重解析 `lastActiveAt` 变化的会话；首次扫描在后台队列，不阻塞 UI |
| `TranscriptReader.load` 对共享 DB 源（opencode/hermes/cursor/zcode）的并发读取 | SQLite 读操作天然并发安全（WAL 模式）；提取在串行队列上执行 |
| Schema 升级（22→23）触发派生表重建 | `prompts` 表加入 DROP 块；重建时自动从 transcript 重新提取；用户标注（favorite/tags/useCount）会丢失——需要在迁移时保留 |
| 用户标注在 schema 重建时丢失 | **关键约束**：`prompts` 表不能是纯派生表。迁移策略：schema bump 时先 `ALTER TABLE prompts RENAME TO prompts_old`，建新表，再 `INSERT INTO prompts SELECT * FROM prompts_old`，最后 `DROP TABLE prompts_old` |

### 6.1 用户标注的持久性

`favorite`、`tags`、`use_count`、`last_used_at` 是用户写入的事实数据，不能因派生表重建而丢失。因此 `prompts` 表的迁移策略与纯派生表（`transcript_fts`、`usage_records` 等）不同：

- **提取数据**（`text`、`timestamp`、`source`、`session_id`、`message_idx`、`first_seen`）：派生，可从 transcript 重建
- **用户标注**（`favorite`、`tags`、`use_count`、`last_used_at`）：事实，必须跨迁移保留

Schema 迁移代码：

```swift
// Schema.swift migrate() 中，version >= 23 时
if current < 23 {
    // 保留用户标注：重命名旧表，建新表，迁回数据
    db.execute("ALTER TABLE prompts RENAME TO prompts_old_backup")
    // ... CREATE TABLE prompts (new schema) ...
    db.execute("""
        INSERT INTO prompts
        (id, source, session_id, message_idx, text, timestamp, cwd,
         favorite, tags, use_count, last_used_at, first_seen, updated_at)
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen, updated_at
        FROM prompts_old_backup
    """)
    db.execute("DROP TABLE prompts_old_backup")
}
```

因此 `prompts` 表**不加入** DROP 块（lines 37-50），而是用 additive migration。

## 7. 测试策略

| 测试 | 模块 | 覆盖点 |
|---|---|---|
| 提取正确性 | `eureka-tests` | 给定 mock transcript，验证提取出的 prompt 列表 |
| 去重/增量 | `eureka-tests` | 同一会话二次扫描，不产生重复行 |
| 用户标注持久 | `eureka-tests` | 标注后重新提取，标注不丢失 |
| 搜索 | `eureka-tests` | FTS 命中 prompt 文本 |
| 收藏过滤 | `eureka-tests` | 只返回 `favorite == true` |
| 命令面板 | `eureka-tests` | `CommandPalette.merge` 包含 `.prompt` kind |

---

*文档版本：2026-08-23 · 基于 v0.29.0 代码库分析*
