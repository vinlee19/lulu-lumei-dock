# 知识面联动与 ⌘K 全局搜索 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 主窗口 ⌘K 面板一次搜遍 会话/技能/记忆/指令/计划 并直达；技能详情反查最近调用会话；会话详情列出产出的记忆与计划。

**Architecture:** FTS5 统一索引（新 `knowledge_fts`/`knowledge_docs` 两表，事件驱动索引器挂在知识面扫描完成点，不吃 5 分钟定时）；`tool_calls` 升 schema v20 加 `session_id`（派生表机制自动全量回填）；`PlanEntry` 补 `sessionId`（物化器写 `sessions.json` 边车）。跨页直达全部走既有 NotificationCenter reveal 惯例。

**Tech Stack:** Swift 5.10 / SwiftPM / SwiftUI (macOS 14) / 系统 libsqlite3（FTS5 trigram）/ 手工测试 harness（`make test`）。

**Spec:** `docs/specs/2026-08-05-knowledge-linkage-and-command-palette-design.md`

**约定（全程适用）：**
- UI 字符串与代码注释用中文；commit message 用英文 conventional commits（AGENTS.md）。
- 主题化：新 UI 一律用 `Theme.*` token（`Theme.font.themed(…)` / `Theme.surface` / `Theme.cardBorder` / `Theme.brandFg`），**不写死颜色**；classic 分支行为不受影响（新增视图无 classic 逐像素约束，但要在两种风格下都不违和）。
- 每个任务结束跑 `make build`；标注了测试的任务跑 `make test`（603+ 全过）后再 commit。
- 仓库惯例：直接在 main 上做（用户记忆明确不建 worktree）。

---

### Task 1: Schema v20 —— `tool_calls.session_id` + knowledge 两表 + 仓库查询

**Files:**
- Modify: `Sources/EurekaStore/Schema.swift`
- Modify: `Sources/EurekaStore/Store.swift`（`ToolCallsRepo`）
- Create: `Tests/EurekaTestsRunner/KnowledgeLinkTests.swift`
- Modify: `Tests/EurekaTestsRunner/main.swift`

- [ ] **Step 1: 写失败测试**

新建 `Tests/EurekaTestsRunner/KnowledgeLinkTests.swift`（样板照 `AuditRepoTests.swift`）：

```swift
import EurekaKit
import EurekaStore
import Foundation

func knowledgeLinkTests(_ t: TestRunner) {
    t.suite("KnowledgeLink · tool_calls 会话维度")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-klink-\(UUID()).sqlite")
    }

    t.test("bump 带 session：recentSkillSessions 按最近时间排序且聚合次数") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 100, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 200, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-02", source: .claude, kind: "skill", name: "tdd",
            ts: 300, session: "sess-b")
        let rows = try store.toolCalls.recentSkillSessions(source: .claude, name: "tdd")
        try expectEqual(rows.count, 2)
        try expectEqual(rows[0].sessionId, "sess-b", "最近调用的会话排最前")
        try expectEqual(rows[1].sessionId, "sess-a")
        try expectEqual(rows[1].count, 2, "同会话两次 bump 应聚合")
    }

    t.test("session 维度不影响既有聚合口径") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 100, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 200, session: "sess-b")
        let stats = try store.toolCalls.skillStats(source: .claude)
        try expectEqual(stats.count, 1, "跨会话仍聚合为同一技能")
        try expectEqual(stats[0].count, 2)
    }

    t.test("空 session 的历史行不进 recentSkillSessions") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd", ts: 100)
        try expectEqual(
            try store.toolCalls.recentSkillSessions(source: .claude, name: "tdd").count, 0)
    }
}
```

在 `Tests/EurekaTestsRunner/main.swift` 的 `t.finish()` 之前追加一行：

```swift
knowledgeLinkTests(t)
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `make test`
Expected: 编译错误 `extra argument 'session' in call` / `recentSkillSessions` 不存在。

- [ ] **Step 3: Schema.swift 升 v20**

`Sources/EurekaStore/Schema.swift`：

1. 版本注释区（`:4` 上方风格）顶部加一行，并把 `:22` 的版本改为 20：

```swift
/// v20：tool_calls 主键加 session_id（技能→会话反查；派生表升级重建全量回填）；
///      新增 knowledge_fts + knowledge_docs（知识面全文搜索，扫描完成后事件驱动重索引）
static let version: Int64 = 20
```

2. `migrate` 的 DROP 块（`:29-40`）追加两行（派生表，升级重建）：

```swift
DROP TABLE IF EXISTS knowledge_fts;
DROP TABLE IF EXISTS knowledge_docs;
```

3. `tool_calls` DDL（`:109-118`）改为：

```sql
CREATE TABLE IF NOT EXISTS tool_calls (
    day TEXT NOT NULL,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    session_id TEXT NOT NULL DEFAULT '',
    count INTEGER NOT NULL DEFAULT 0,
    last_ts REAL NOT NULL DEFAULT 0,
    tokens INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, source, kind, name, session_id)
);
```

4. 在 `transcript_fts` 三件套 DDL（`:192-212`）之后追加：

```sql
-- 知识面全文搜索（技能/记忆/指令/计划正文；派生表，升级重建）。
-- 一文件一 doc、指纹列内联（与逐消息的 fts_docs 不同）。knowledge_fts.rowid == knowledge_docs.id。
CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(text, tokenize='trigram');
CREATE TABLE IF NOT EXISTS knowledge_docs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    project TEXT,
    size INTEGER NOT NULL,
    mtime REAL NOT NULL
);
```

- [ ] **Step 4: ToolCallsRepo 改造**

`Sources/EurekaStore/Store.swift` 的 `bump`（`:936-953`）加 `session` 参数（默认空串 → 其余 6 个扫描器调用点零改动）：

```swift
/// 累加计数（同 日/来源/kind/name/session 合并）；last_ts 取较大值、tokens 累加。
/// session：触发会话 id（仅 Claude 扫描器传真实值，其余默认空 —— 与逐技能数据仅 Claude 的现状一致）。
public func bump(
    day: String, source: AgentSource, kind: String, name: String,
    by count: Int = 1, ts: Double = 0, tokens: Int = 0, session: String = ""
) throws {
    guard count > 0, !name.isEmpty else { return }
    try db.run("""
    INSERT INTO tool_calls (day, source, kind, name, session_id, count, last_ts, tokens)
    VALUES (?,?,?,?,?,?,?,?)
    ON CONFLICT(day, source, kind, name, session_id) DO UPDATE SET
        count = count + excluded.count,
        last_ts = MAX(last_ts, excluded.last_ts),
        tokens = tokens + excluded.tokens
    """, [
        .text(day), .text(source.rawValue), .text(kind), .text(name), .text(session),
        .int(Int64(count)), .real(ts), .int(Int64(tokens)),
    ])
}
```

同文件 `dailySeries` 之后新增查询：

```swift
/// 某技能最近出现过的会话（全时；kind 固定 'skill'）。空 session 的历史行不计。
public func recentSkillSessions(
    source: AgentSource, name: String, limit: Int = 10
) throws -> [(sessionId: String, lastTs: Date, count: Int)] {
    try db.query("""
    SELECT session_id, MAX(last_ts), SUM(count) FROM tool_calls
    WHERE kind = 'skill' AND source = ? AND name = ? AND session_id != ''
    GROUP BY session_id ORDER BY MAX(last_ts) DESC LIMIT ?
    """, [.text(source.rawValue), .text(name), .int(Int64(limit))]) { row in
        (sessionId: row.text(0) ?? "",
         lastTs: Date(timeIntervalSince1970: row.real(1)),
         count: Int(row.int(2)))
    }
}
```

既有聚合查询（`totals` / `statsByName` / `dailySeries`）**不动**——GROUP BY 口径不含 session_id，多行自动 SUM。

- [ ] **Step 5: 跑测试确认通过**

Run: `make test`
Expected: 新增 3 条全过，其余不回归。

- [ ] **Step 6: Commit**

```bash
git add Sources/EurekaStore Tests/EurekaTestsRunner
git commit -m 'feat(store): add session dimension to tool_calls and knowledge fts tables'
```

---

### Task 2: Claude 扫描器传 session

**Files:**
- Modify: `Sources/EurekaUsage/ClaudeTranscriptScanner.swift:135-160`

- [ ] **Step 1: 两处 bump 传 session**

该函数内已有会话 id 先例（`:169` 附近 `url.deletingPathExtension().lastPathComponent`）。在事务开始前（`newCount = 0` 附近）取一次：

```swift
let sessionId = url.deletingPathExtension().lastPathComponent  // 会话 = 文件（文件名即 session id）
```

技能/工具 bump（`:143-146`）改为：

```swift
try store.toolCalls.bump(
    day: day, source: .claude, kind: call.kind, name: call.name,
    ts: ts, tokens: lineTokens, session: sessionId)
```

斜杠命令 bump（`:157-158`）改为：

```swift
try store.toolCalls.bump(
    day: command.day, source: .claude, kind: "command", name: command.name,
    session: sessionId)
```

- [ ] **Step 2: 构建 + 真数据验证**

Run: `make build && make test`
Expected: 全过（schema v20 会在下次打开库时自动重建派生表）。

Run（真数据回填验证——先触发一次全量扫描再查库）:

```bash
swift run eureka --usage-snapshot > /dev/null
sqlite3 ~/Library/Application\ Support/Eureka/eureka.sqlite \
  "SELECT COUNT(*) FROM tool_calls WHERE kind='skill' AND session_id != ''"
```

Expected: 计数 > 0（历史技能调用已带会话归属）。

- [ ] **Step 3: Commit**

```bash
git add Sources/EurekaUsage/ClaudeTranscriptScanner.swift
git commit -m 'feat(usage): attribute claude skill calls to sessions'
```

---

### Task 3: KnowledgeSearchRepo（EurekaStore）

**Files:**
- Create: `Sources/EurekaStore/KnowledgeSearchRepo.swift`
- Modify: `Sources/EurekaStore/Store.swift:6-34`（装配）
- Modify: `Tests/EurekaTestsRunner/KnowledgeLinkTests.swift`

- [ ] **Step 1: 写失败测试**

`KnowledgeLinkTests.swift` 追加：

```swift
t.test("knowledge：upsert / 搜索 / prune 全链路") {
    let path = tempStorePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try EurekaStore(path: path)
    try store.knowledge.replaceDoc(
        path: "/tmp/a/SKILL.md", kind: "skill", source: "claude",
        title: "tdd", project: nil, size: 10, mtime: 1,
        body: "红绿重构循环，测试先行")
    try store.knowledge.replaceDoc(
        path: "/tmp/b/mem.md", kind: "memory", source: "claude",
        title: "worktree 约定", project: "eureka", size: 10, mtime: 1,
        body: "main 直改不建 worktree")
    let hits = try store.knowledge.search("worktree")
    try expectEqual(hits.count, 1)
    try expectEqual(hits[0].kind, "memory")
    try expectEqual(hits[0].title, "worktree 约定")
    // 同 path 重写覆盖旧文
    try store.knowledge.replaceDoc(
        path: "/tmp/b/mem.md", kind: "memory", source: "claude",
        title: "worktree 约定", project: "eureka", size: 12, mtime: 2,
        body: "改为别的内容")
    try expectEqual(try store.knowledge.search("worktree").count, 0, "旧正文应被覆盖")
    // prune 清掉消失的文件
    try store.knowledge.prune(keeping: ["/tmp/b/mem.md"])
    try expectEqual(try store.knowledge.search("测试先行").count, 0, "被 prune 的技能不该再命中")
}

t.test("knowledge：中文双字查询走 LIKE 兜底") {
    let path = tempStorePath()
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try EurekaStore(path: path)
    try store.knowledge.replaceDoc(
        path: "/tmp/c/plan.md", kind: "plan", source: "codex",
        title: "对比度修复", project: nil, size: 10, mtime: 1, body: "修复对比度问题")
    try expectEqual(try store.knowledge.search("修复").count, 1)
}
```

Run: `make test` → Expected: 编译失败（`store.knowledge` 不存在）。

- [ ] **Step 2: 新建仓库文件**

`Sources/EurekaStore/KnowledgeSearchRepo.swift`（结构照 `SearchRepo.swift`）：

```swift
import Foundation

/// 知识面全文命中：一份文件级的搜索结果
public struct KnowledgeSearchHit: Equatable {
    public var kind: String       // skill / memory / instruction / plan
    public var path: String
    public var source: String
    public var title: String
    public var project: String?
    /// 命中正文（按索引截断上限存储；snippet 由调用层裁剪）
    public var text: String
}

/// 知识面全文搜索仓库：knowledge_fts（FTS5 trigram）+ knowledge_docs。
/// 派生数据：清空/重建随时安全，下轮知识面扫描自动恢复。
public final class KnowledgeSearchRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// 全部已索引文件的指纹（path → (size, mtime)），一次取回做增量比对
    public func fileFingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        let rows = try db.query("SELECT path, size, mtime FROM knowledge_docs") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (size: $0.1, mtime: $0.2)) })
    }

    /// 单文件重建：删旧 → 插新，单事务保证 fts 与 docs 对齐
    public func replaceDoc(
        path: String, kind: String, source: String, title: String,
        project: String?, size: Int64, mtime: Double, body: String
    ) throws {
        try db.transaction {
            try deleteDoc(path: path)
            try db.run("""
            INSERT INTO knowledge_docs (kind, path, source, title, project, size, mtime)
            VALUES (?,?,?,?,?,?,?)
            """, [
                .text(kind), .text(path), .text(source), .text(title),
                project.map { .text($0) } ?? .null, .int(size), .real(mtime),
            ])
            let rowid = db.lastInsertRowID
            try db.run(
                "INSERT INTO knowledge_fts (rowid, text) VALUES (?,?)",
                [.int(rowid), .text(body)])
        }
    }

    /// 清理已消失的文件
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query("SELECT path FROM knowledge_docs") { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.transaction { try deleteDoc(path: path) }
        }
    }

    private func deleteDoc(path: String) throws {
        try db.run(
            "DELETE FROM knowledge_fts WHERE rowid IN (SELECT id FROM knowledge_docs WHERE path = ?)",
            [.text(path)])
        try db.run("DELETE FROM knowledge_docs WHERE path = ?", [.text(path)])
    }

    /// 全文检索：≥3 字符 trigram MATCH；2 字符 LIKE 兜底（与 SearchRepo 同策略）
    public func search(_ rawQuery: String, limit: Int = 30) throws -> [KnowledgeSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        if query.count >= 3 {
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return try db.query("""
            SELECT d.kind, d.path, d.source, d.title, d.project, f.text
            FROM knowledge_fts f JOIN knowledge_docs d ON d.id = f.rowid
            WHERE knowledge_fts MATCH ?
            ORDER BY d.mtime DESC LIMIT ?
            """, [.text(phrase), .int(Int64(limit))], map: Self.hitMapper)
        }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.query("""
        SELECT d.kind, d.path, d.source, d.title, d.project, f.text
        FROM knowledge_fts f JOIN knowledge_docs d ON d.id = f.rowid
        WHERE f.text LIKE ? ESCAPE '\\'
        ORDER BY d.mtime DESC LIMIT ?
        """, [.text("%\(escaped)%"), .int(Int64(limit))], map: Self.hitMapper)
    }

    private static let hitMapper: (SQLiteRow) -> KnowledgeSearchHit = { row in
        KnowledgeSearchHit(
            kind: row.text(0) ?? "", path: row.text(1) ?? "", source: row.text(2) ?? "",
            title: row.text(3) ?? "", project: row.text(4), text: row.text(5) ?? "")
    }
}
```

注意：若 `SQLiteValue` 无 `.null` 成员，检查 `Sources/EurekaStore/SQLite.swift` 里可空绑定的既有写法（`SearchRepo.replaceDocs` 的 `.date(doc.ts)` 是可空先例），照仓库现状处理 `project` 的可空绑定。

- [ ] **Step 3: 装配进 EurekaStore**

`Sources/EurekaStore/Store.swift`：属性区（`:15` `search` 之后）加

```swift
public let knowledge: KnowledgeSearchRepo
```

`init`（`:32` `search = SearchRepo(db: db)` 之后）加

```swift
knowledge = KnowledgeSearchRepo(db: db)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `make test` → Expected: 全过。

- [ ] **Step 5: Commit**

```bash
git add Sources/EurekaStore Tests/EurekaTestsRunner
git commit -m 'feat(store): add knowledge full-text search repo'
```

---

### Task 4: `PlanEntry.sessionId` + `sessions.json` 边车

**Files:**
- Modify: `Sources/EurekaIngest/PlanMaterializer.swift`
- Modify: `Tests/EurekaTestsRunner/PlanMaterializerTests.swift`

- [ ] **Step 1: 写失败测试**

`PlanMaterializerTests.swift` 追加（照该文件既有临时目录写法）：

```swift
t.test("collect：sessions.json 边车给 staged 计划标会话") {
    let fm = FileManager.default
    let staging = fm.temporaryDirectory
        .appendingPathComponent("eureka-plan-smap-\(UUID())", isDirectory: true)
    let codexDir = staging.appendingPathComponent("codex", isDirectory: true)
    try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    try "# 标题\n\n- [x] 完成项\n".write(
        to: codexDir.appendingPathComponent("rollout-x.md"), atomically: true, encoding: .utf8)
    try #"{"rollout-x.md": "sess-42"}"#.write(
        to: codexDir.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)
    let entries = PlanMaterializer.index(
        claudePlansDir: staging.appendingPathComponent("nope"),
        stagingRoot: staging, hermesPlansDirs: [])
    let codexEntries = entries.filter { $0.source == .codex }
    try expectEqual(codexEntries.count, 1)
    try expectEqual(codexEntries[0].sessionId, "sess-42")
}
```

Run: `make test` → Expected: 编译失败（`sessionId` 不存在）。

- [ ] **Step 2: PlanEntry 加字段**

`PlanMaterializer.swift` 的 `PlanEntry`（`:57-105`）：属性区 `summary` 之后加

```swift
/// 来源会话 id（物化计划由 sessions.json 边车提供；真实文件计划为 nil）
public var sessionId: String?
```

`init` 参数表 `summary: String? = nil` 之后加 `sessionId: String? = nil`，init 体加 `self.sessionId = sessionId`。

- [ ] **Step 3: 边车读写助手**

`PlanMaterializer` 内（`writeIfChanged` `:824` 附近）加：

```swift
/// 物化目录「文件名 → 会话 id」边车（collect 读取；仅物化器知道会话归属）
static func writeSessionMap(_ map: [String: String], outDir: URL) {
    let url = outDir.appendingPathComponent("sessions.json")
    guard !map.isEmpty else { try? FileManager.default.removeItem(at: url); return }
    guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
}

static func sessionMap(dir: URL) -> [String: String] {
    let url = dir.appendingPathComponent("sessions.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return obj
}
```

- [ ] **Step 4: 四个物化器写边车**

会话 id 均在写入点作用域内：

1. **codex**（`materializeCodex`）：文件循环里积累 `var smap: [String: String] = [:]`；命中缓存跳过的文件也要进 map——从状态缓存取（`:195-212` 的 state 值同时有 `output` 与 `sessionId` 字段，遍历 state 补全）。循环结束后 `writeSessionMap(smap, outDir: outDir)`。写入行 `:207` 对应 `smap[outputName] = artifact.sessionId`。
2. **opencode**（`:386`）：循环内 `smap[sessionId + ".md"] = sessionId`，循环后写边车。
3. **grok**（`:439`）：`smap[uuid + ".md"] = uuid`。
4. **cursor**（`:557`）：`smap["\(composerId).md"] = composerId`（cursor 的会话 id 就是 composerId）。

kimi / gemini / qwen / qoder 的暂存文件名与会话映射关系未定义，**本期明确不写边车**（spec「明确不做」）。

- [ ] **Step 5: collect 读边车**

`collect(dir:source:into:)`（`:756`）签名加参数 `sessionMap: [String: String] = [:]`，构造 `PlanEntry` 时（`:765`）加 `sessionId: sessionMap[url.lastPathComponent]`。

`index(...)` 里对 staged 源调用 `collect` 的每一处（grep `collect(dir:`），staged 目录传 `sessionMap: sessionMap(dir: dir)`；claude/hermes 真实目录保持默认空（目录里没有边车文件，传了也无害——两种写法选与现状 diff 最小的）。

注意 `collect` 扫 `*.md`，`sessions.json` 不是 md 不会被误收；无需过滤。

- [ ] **Step 6: 跑测试确认通过 + Commit**

Run: `make test` → Expected: 全过。

```bash
git add Sources/EurekaIngest Tests/EurekaTestsRunner
git commit -m 'feat(ingest): carry originating session id on materialized plans'
```

---

### Task 5: 服务层访问器（snapshot / focus / 反查）

**Files:**
- Modify: `Sources/EurekaApp/SkillMemoryService.swift`
- Modify: `Sources/EurekaApp/PlansService.swift`

- [ ] **Step 1: SkillMemoryService**

`@Published` 区（`:33` 附近）加：

```swift
/// 跨页直达：待聚焦条目的文件路径（PopoverRootView 写入，对应页签消费后清空）
@Published var focusPath: String?
```

服务尾部（`reveal(path:)` `:582` 附近）加：

```swift
/// 知识面快照（全文索引用）：用户技能 + 全部记忆（含库内条目与指令）。搜索过滤前的全集。
func knowledgeSnapshot() -> (skills: [SkillEntry], memories: [MemoryEntry]) {
    (allSkills.filter { $0.origin == .user }, allMemories)
}

/// 与某会话相关的记忆（originSessionId 或 relatedSessions 命中；会话详情「本会话产出」用）
func memories(relatedTo sessionId: String) -> [MemoryEntry] {
    allMemories.filter { entry in
        entry.originSessionId == sessionId
            || entry.relatedSessions.contains { $0.sessionId == sessionId }
    }
}
```

（`allSkills`/`allMemories` 是主线程发布后的私有存量，以上均只在主线程调用——与 `rebuild()` 同一约束。）

- [ ] **Step 2: PlansService**

同样加：

```swift
@Published var focusPath: String?

/// 知识面快照（全文索引用；搜索过滤前的全集）
func knowledgeSnapshot() -> [PlanMaterializer.PlanEntry] { all }

/// 某会话产出的计划（会话详情「本会话产出」用）
func plans(forSession sessionId: String) -> [PlanMaterializer.PlanEntry] {
    all.filter { $0.sessionId == sessionId }
}

/// 按路径找条目（跨页直达消费用）
func entry(atPath path: String) -> PlanMaterializer.PlanEntry? {
    all.first { $0.path == path }
}
```

- [ ] **Step 3: 构建 + Commit**

Run: `make build` → Expected: Build complete。

```bash
git add Sources/EurekaApp/SkillMemoryService.swift Sources/EurekaApp/PlansService.swift
git commit -m 'feat(ui): expose knowledge snapshots and session lookups on services'
```

---

### Task 6: KnowledgeSearchIndexer + AppDelegate 装配

**Files:**
- Create: `Sources/EurekaApp/KnowledgeSearchIndexer.swift`
- Modify: `Sources/EurekaApp/AppDelegate.swift`
- Modify: `Tests/EurekaTestsRunner/KnowledgeLinkTests.swift`

- [ ] **Step 1: 写失败测试（纯映射逻辑）**

`KnowledgeLinkTests.swift` 追加：

```swift
t.test("indexer：条目映射成 doc（kind / title / project 各归各位）") {
    let skill = SkillEntry(
        source: .claude, name: "tdd", description: nil,
        path: "/tmp/s/SKILL.md", directory: "/tmp/s", enabled: true,
        sizeBytes: 10, modifiedAt: Date(timeIntervalSince1970: 1))
    let memory = MemoryEntry(
        source: .claude, scope: "eureka", path: "/tmp/m.md", kind: .userManaged,
        projectName: "eureka", sizeBytes: 20, modifiedAt: Date(timeIntervalSince1970: 2),
        title: "worktree 约定", summary: nil, memoryType: .other,
        originSessionId: nil, originSessionPath: nil,
        relatedSessions: [], links: [], indexedTargets: [], isIndex: false, libraryKey: nil)
    let instruction = MemoryEntry(
        source: .claude, scope: "全局", path: "/tmp/CLAUDE.md", kind: .instructions,
        projectName: nil, sizeBytes: 5, modifiedAt: Date(timeIntervalSince1970: 3),
        title: "CLAUDE", summary: nil, memoryType: .other,
        originSessionId: nil, originSessionPath: nil,
        relatedSessions: [], links: [], indexedTargets: [], isIndex: false, libraryKey: nil)
    let plan = PlanMaterializer.PlanEntry(
        source: .codex, title: "对比度修复", path: "/tmp/p.md",
        sizeBytes: 30, modifiedAt: Date(timeIntervalSince1970: 4), sessionId: "sess-1")
    let docs = KnowledgeSearchIndexer.docs(
        skills: [skill], memories: [memory, instruction], plans: [plan])
    try expectEqual(docs.count, 4)
    try expectEqual(docs.first { $0.path == "/tmp/s/SKILL.md" }?.kind, "skill")
    try expectEqual(docs.first { $0.path == "/tmp/m.md" }?.kind, "memory")
    try expectEqual(docs.first { $0.path == "/tmp/m.md" }?.project, "eureka")
    try expectEqual(docs.first { $0.path == "/tmp/CLAUDE.md" }?.kind, "instruction")
    try expectEqual(docs.first { $0.path == "/tmp/p.md" }?.kind, "plan")
}
```

注意：`MemoryEntry`/`SkillEntry` 的 memberwise init 参数以 `SkillMemoryIndexer.swift:36-140` 实际定义为准（上面按实际字段写；若 init 有默认值可省略部分参数）。测试文件需 `import EurekaIngest`。

Run: `make test` → Expected: 编译失败（`KnowledgeSearchIndexer` 不存在）。

- [ ] **Step 2: 索引器实现**

`Sources/EurekaApp/KnowledgeSearchIndexer.swift`：

```swift
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// 知识面全文索引器：挂在 SkillMemoryService / PlansService 扫描完成点（事件驱动，非定时），
/// 指纹（size+mtime）diff 增量重建。索引失败静默——面板会降级为元数据搜索，不挂功能。
final class KnowledgeSearchIndexer {
    /// 单文件正文索引截断上限（计划文档可能很大；知识面搜索按头部命中足够）
    static let bodyCap = 256 * 1024

    struct Doc: Equatable {
        var kind: String
        var path: String
        var source: String
        var title: String
        var project: String?
        var size: Int64
        var mtime: Double
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.knowledge-index", qos: .utility)
    private var store: EurekaStore?

    /// 条目 → doc 的纯映射（可测）；正文读取推迟到索引队列
    static func docs(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) -> [Doc] {
        var result: [Doc] = []
        for skill in skills {
            result.append(Doc(
                kind: "skill", path: skill.path, source: skill.source.rawValue,
                title: skill.name, project: nil,
                size: Int64(skill.sizeBytes), mtime: skill.modifiedAt.timeIntervalSince1970))
        }
        for memory in memories {
            result.append(Doc(
                kind: memory.kind == .instructions ? "instruction" : "memory",
                path: memory.path, source: memory.source.rawValue,
                title: memory.title, project: memory.projectName,
                size: Int64(memory.sizeBytes), mtime: memory.modifiedAt.timeIntervalSince1970))
        }
        for plan in plans {
            result.append(Doc(
                kind: "plan", path: plan.path, source: plan.source.rawValue,
                title: plan.title, project: plan.project,
                size: Int64(plan.sizeBytes), mtime: plan.modifiedAt.timeIntervalSince1970))
        }
        return result
    }

    func index(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) {
        let docs = Self.docs(skills: skills, memories: memories, plans: plans)
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else { return }
            let fingerprints = (try? store.knowledge.fileFingerprints()) ?? [:]
            for doc in docs {
                if let old = fingerprints[doc.path],
                   old.size == doc.size, old.mtime == doc.mtime { continue }
                guard var body = try? String(contentsOfFile: doc.path, encoding: .utf8)
                else { continue }
                if body.utf8.count > Self.bodyCap { body = String(body.prefix(Self.bodyCap)) }
                try? store.knowledge.replaceDoc(
                    path: doc.path, kind: doc.kind, source: doc.source, title: doc.title,
                    project: doc.project, size: doc.size, mtime: doc.mtime, body: body)
            }
            try? store.knowledge.prune(keeping: Set(docs.map(\.path)))
        }
    }
}
```

（自开一个 `EurekaStore` 实例是既有先例：`SessionBrowserService.swift:131`。）

- [ ] **Step 3: AppDelegate 装配**

> **勘误（Task 6 实测踩坑，2026-08-05）：** `KnowledgeSearchIndexer` 实际落在
> `Sources/EurekaIngest/KnowledgeSearchIndexer.swift`，不是本节标题写的 `Sources/EurekaApp/`——
> `eureka-tests` 依赖 `eureka`（两者都是 `.executableTarget`）时，类型检查能过，但
> `swift run eureka-tests`（`make test` 的实际路径）链接期拿不到 `eureka` 的目标码，稳定报
> `Undefined symbols`。索引器只依赖 `EurekaStore`/`Foundation`，挪去和 `SkillMemoryIndexer`/
> `PlanMaterializer` 同层即可，`AppDelegate.swift` 本就 `import EurekaIngest`，零改动可引用。
> 下面的装配代码另外补了两处生命周期修复（质量审查发现）：
> 1. `reindexKnowledge()` 必须等 `skillMemory`/`plans` 都扫完一轮才能动手——只要有一方的
>    `knowledgeSnapshot()` 还是空集，`index()` 内的 `prune` 就会把另一方已持久化的 doc
>    当"已消失"整批删掉，造成每次启动先扫完的一方触发一次误清空。
> 2. 设置页「清空全文索引」清空 `knowledge_docs`/`knowledge_fts` 后，没有定时器会重建
>    ——`UsageService` 需要一个 `onSearchIndexCleared` 回调，装配到 `reindexKnowledge()`。

`Sources/EurekaApp/AppDelegate.swift`：服务属性区（`:19` 附近）加

```swift
private let knowledgeIndexer = KnowledgeSearchIndexer()
```

cancellables 装配区（`:82-130` 一带的 `.store(in: &cancellables)` 同伴处）加：

```swift
// 知识面扫描完成 → 事件驱动重建全文索引（搜索新鲜度 = 列表新鲜度）
skillMemory.$lastScanAt.compactMap { $0 }.removeDuplicates()
    .sink { [weak self] _ in DispatchQueue.main.async { self?.reindexKnowledge() } }  // @Published 是 willSet 发射，必须推迟到 didSet 后再读守卫
    .store(in: &cancellables)
plans.$lastScanAt.compactMap { $0 }.removeDuplicates()
    .sink { [weak self] _ in DispatchQueue.main.async { self?.reindexKnowledge() } }  // @Published 是 willSet 发射，必须推迟到 didSet 后再读守卫
    .store(in: &cancellables)
// 设置页「清空全文索引」清掉 knowledge 索引后没人会自愈——补一脚重建
// （此时两个 lastScanAt 必已非 nil：清空只可能发生在启动扫描之后）
usageService.onSearchIndexCleared = { [weak self] in self?.reindexKnowledge() }
```

方法区加：

```swift
/// 两个 lastScanAt 都非 nil 才动手——只要有一方还没扫完，它的 knowledgeSnapshot() 就是空集，
/// index() 的 prune 会把另一方已持久化的全部 doc 当"已消失"删光，启动时先扫完的那个会
/// 触发一次误清空、每次启动都全量重建。
private func reindexKnowledge() {
    guard skillMemory.lastScanAt != nil, plans.lastScanAt != nil else { return }
    let snapshot = skillMemory.knowledgeSnapshot()
    knowledgeIndexer.index(
        skills: snapshot.skills, memories: snapshot.memories,
        plans: plans.knowledgeSnapshot())
}
```

`Sources/EurekaApp/UsageService.swift` 的 `clearSearchIndex()`（约 :231-236）加回调属性并在清空后触发：

```swift
/// 知识面索引被清空后的回调（AppDelegate 装配为重新触发一次 reindex——
/// 知识面侧只挂 lastScanAt 事件驱动，清空后没有定时器会自愈，必须显式踢一脚）
var onSearchIndexCleared: (() -> Void)?

func clearSearchIndex() {
    queue.async { [weak self] in
        try? self?.store?.search.clearAll()
        try? self?.store?.knowledge.clearAll()
        DispatchQueue.main.async { self?.onSearchIndexCleared?() }
    }
}
```

`Sources/EurekaStore/KnowledgeSearchRepo.swift` 的 `clearAll()` 包一层 `db.transaction`（与 `replaceDoc` 对 fts/docs 两表对齐的承诺对称，防两条 DELETE 之间被另一连接的写插入）：

```swift
public func clearAll() throws {
    try db.transaction {
        try db.execute("""
        DELETE FROM knowledge_fts;
        DELETE FROM knowledge_docs;
        """)
    }
}
```

- [ ] **Step 4: 跑测试 + 真数据验证 + Commit**

Run: `make test` → Expected: 全过。

Run: `swift run eureka` 打开主窗口逛一圈（触发预热扫描），退出后：

```bash
sqlite3 ~/Library/Application\ Support/Eureka/eureka.sqlite \
  "SELECT kind, COUNT(*) FROM knowledge_docs GROUP BY kind"
```

Expected: skill / memory / instruction / plan 四类均有行。

```bash
git add Sources/EurekaApp Tests/EurekaTestsRunner
git commit -m 'feat(ui): index knowledge files into fts after each scan'
```

---

### Task 7: reveal 通知与跨页直达消费

**Files:**
- Modify: `Sources/EurekaApp/StatusBar/UsageDashboardView.swift:1156-1159`（Notification.Name extension）
- Modify: `Sources/EurekaApp/StatusBar/PopoverRootView.swift:94-100`
- Modify: `Sources/EurekaApp/StatusBar/SkillMemoryView.swift`
- Modify: `Sources/EurekaApp/StatusBar/PlansView.swift`

- [ ] **Step 1: 通知名**

`UsageDashboardView.swift:1158` 的 extension 内追加：

```swift
/// 跨页直达：知识面条目（object = 文件路径 String；userInfo["kind"] = skill/memory/instruction）
static let eurekaRevealKnowledge = Notification.Name("eurekaRevealKnowledge")
/// 跨页直达：计划条目（object = 文件路径 String）
static let eurekaRevealPlan = Notification.Name("eurekaRevealPlan")
/// ⌘K 全局搜索面板开关（MainMenu 发、PopoverRootView 收）
static let eurekaToggleCommandPalette = Notification.Name("eurekaToggleCommandPalette")
```

- [ ] **Step 2: PopoverRootView 路由**

`.onReceive(.eurekaRevealSession)`（`:94-100`）之后追加：

```swift
.onReceive(NotificationCenter.default.publisher(for: .eurekaRevealKnowledge)) { note in
    guard let path = note.object as? String else { return }
    let kind = note.userInfo?["kind"] as? String ?? "memory"
    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
        switch kind {
        case "skill": navigation.tab = .skills
        case "instruction": navigation.tab = .instructions
        default: navigation.tab = .memory
        }
    }
    skillMemoryService.focusPath = path
}
.onReceive(NotificationCenter.default.publisher(for: .eurekaRevealPlan)) { note in
    guard let path = note.object as? String else { return }
    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { navigation.tab = .plans }
    plansService.focusPath = path
}
```

- [ ] **Step 3: SkillMemoryView 消费 focus**

视图 body 链上加（`.onAppear` 已有处附近；注意页签切换会重建视图，onChange 与 onAppear 都要消费）：

```swift
.onAppear { consumeFocus() }
.onChange(of: service.focusPath) { _, _ in consumeFocus() }
```

私有方法：

```swift
/// 跨页直达落点：按路径找到本签条目并打开详情（找不到不清空——可能属于别的签）
private func consumeFocus() {
    guard let path = service.focusPath else { return }
    if mode == .skills {
        guard let skill = service.skills.first(where: { $0.path == path }) else { return }
        detail = SkillDetailTarget(source: skill.source, name: skill.name, entry: skill)
        service.focusPath = nil
    } else {
        let pool = service.memoryEntries + service.instructions
        guard let memory = pool.first(where: { $0.path == path }) else { return }
        memoryDetail = memory
        service.focusPath = nil
    }
}
```

- [ ] **Step 4: PlansView 消费 focus**

同样：

```swift
.onAppear { consumeFocus() }
.onChange(of: service.focusPath) { _, _ in consumeFocus() }
```

```swift
private func consumeFocus() {
    guard let path = service.focusPath, let entry = service.entry(atPath: path) else { return }
    withAnimation(.easeOut(duration: 0.15)) { detail = entry }
    service.focusPath = nil
}
```

- [ ] **Step 5: 构建 + Commit**

Run: `make build` → Expected: Build complete。

```bash
git add Sources/EurekaApp/StatusBar
git commit -m 'feat(ui): add cross-page reveal routing for knowledge and plans'
```

---

### Task 8: 技能详情「最近调用会话」卡

**Files:**
- Modify: `Sources/EurekaApp/UsageService.swift`（`loadSkillWeeklyRank` 附近）
- Modify: `Sources/EurekaApp/StatusBar/SkillDetailView.swift`
- Modify: `Sources/EurekaApp/StatusBar/SkillMemoryView.swift`、`Sources/EurekaApp/StatusBar/PopoverRootView.swift:141-149`（传参链）

- [ ] **Step 1: UsageService 回调式加载器**

照 `loadSkillWeeklyRank` 的回调先例：

```swift
/// 某技能最近调用会话（详情页「最近调用会话」卡；回调回主线程）
func loadSkillSessions(
    source: AgentSource, name: String, limit: Int = 8,
    completion: @escaping ([(sessionId: String, lastTs: Date, count: Int)]) -> Void
) {
    queue.async { [weak self] in
        guard let self, let store = self.store else { return }
        let rows = (try? store.toolCalls.recentSkillSessions(
            source: source, name: name, limit: limit)) ?? []
        DispatchQueue.main.async { completion(rows) }
    }
}
```

- [ ] **Step 2: 传参链**

`SkillMemoryView` 增加存储属性（带默认值，兼容 PreviewRenderer 等既有构造点）：

```swift
var sessionBrowser: SessionBrowserService? = nil
```

`PopoverRootView.swift:141-149` 三处 `SkillMemoryView(...)` 都追加 `sessionBrowser: sessionBrowser`。`SkillMemoryView:85-89` 构造 `SkillDetailView` 处透传（`SkillDetailView` 同样加 `var sessionBrowser: SessionBrowserService? = nil`）。

- [ ] **Step 3: SkillDetailView 卡片**

状态区（`:35` 附近）加：

```swift
@State private var recentSessions: [(sessionId: String, lastTs: Date, count: Int)] = []
```

加载：`loadSeries()`（`:323`）被调用的同一 onAppear/onChange 处，追加：

```swift
usageService.loadSkillSessions(source: target.source, name: target.name) { rows in
    recentSessions = rows
}
```

（`usageService` 与 `target` 的实际属性名以 `SkillDetailView.swift:19-50` 为准；stat 查询用的 source/name 即同一对。）

`statsSection`（`:256`）末尾追加子区块：

```swift
if !recentSessions.isEmpty {
    VStack(alignment: .leading, spacing: 6) {
        sectionTitle("最近调用会话")
        ForEach(recentSessions, id: \.sessionId) { row in
            recentSessionRow(row)
        }
    }
}
```

行组件（悬空置灰惯例照 Memory 的来源会话：能解析→可点跳转，解析不到→置灰显示短 id）：

```swift
private func recentSessionRow(
    _ row: (sessionId: String, lastTs: Date, count: Int)
) -> some View {
    let info = sessionBrowser?.sessionsById[row.sessionId]
    return HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 10))
            .foregroundStyle(info == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.brandFg))
        Text(info?.displayName ?? "会话 \(row.sessionId.prefix(8))（已不可达）")
            .font(Theme.font.themed(11.5))
            .foregroundStyle(info == nil ? .secondary : .primary)
            .lineLimit(1)
        Spacer(minLength: 8)
        Text("\(row.count) 次")
            .font(Theme.font.themedMono(10.5))
            .foregroundStyle(.tertiary)
        Text(relativeFormatter.localizedString(for: row.lastTs, relativeTo: Date()))
            .font(Theme.font.themed(10.5))
            .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .onTapGesture {
        guard info != nil else { return }
        NotificationCenter.default.post(name: .eurekaRevealSession, object: row.sessionId)
    }
    .help(info == nil ? "会话记录已删除或不在当前索引范围" : "跳到该会话")
}
```

- [ ] **Step 4: 构建 + 手动验证 + Commit**

Run: `make build && make test` → Expected: 全过。
Run: `swift run eureka` → Skills 页点一个近期用过的技能 → 详情统计区出现「最近调用会话」，点击行跳到会话页并选中。

```bash
git add Sources/EurekaApp
git commit -m 'feat(ui): list recent invoking sessions on skill detail'
```

---

### Task 9: 会话详情「本会话产出」区

**Files:**
- Modify: `Sources/EurekaApp/StatusBar/SessionsView.swift`（传参）
- Modify: `Sources/EurekaApp/StatusBar/SessionDetailView.swift`
- Modify: `Sources/EurekaApp/StatusBar/PopoverRootView.swift:139-140`

- [ ] **Step 1: 传参链**

`SessionsView` 加存储属性（默认 nil，兼容既有构造点）：

```swift
var skillMemory: SkillMemoryService? = nil
var plans: PlansService? = nil
```

`PopoverRootView.swift:140` 改为：

```swift
SessionsView(service: sessionBrowser, settings: settings,
             skillMemory: skillMemoryService, plans: plansService)
```

`SessionsView` 内部构造 `SessionDetailView` 处透传（`SessionDetailView` 同样加两个默认 nil 属性）。

- [ ] **Step 2: 产出区块**

`SessionDetailView.swift`：找到 `terminalHistoryRow(session)` 的调用处（header 区内），紧随其后追加 `artifactsRow(session)`。区块实现（风格照 `terminalHistoryRow` `:218-244`）：

```swift
/// 本会话产出：记忆（originSessionId/relatedSessions 命中）+ 计划（物化边车 sessionId 命中）
@ViewBuilder
private func artifactsRow(_ session: AgentSessionInfo) -> some View {
    let memories = skillMemory?.memories(relatedTo: session.id) ?? []
    let planEntries = plans?.plans(forSession: session.id) ?? []
    if !memories.isEmpty || !planEntries.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
            Text("本会话产出")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            ForEach(memories) { memory in
                artifactLine(
                    icon: "brain", title: memory.title,
                    note: memory.kind == .instructions ? "指令" : "记忆"
                ) {
                    NotificationCenter.default.post(
                        name: .eurekaRevealKnowledge, object: memory.path,
                        userInfo: ["kind": memory.kind == .instructions ? "instruction" : "memory"])
                }
            }
            ForEach(planEntries) { plan in
                artifactLine(icon: "list.bullet.clipboard", title: plan.title, note: "计划") {
                    NotificationCenter.default.post(name: .eurekaRevealPlan, object: plan.path)
                }
            }
        }
    }
}

private func artifactLine(
    icon: String, title: String, note: String, action: @escaping () -> Void
) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundStyle(Theme.brandFg)
        Text(title)
            .font(Theme.font.themed(11))
            .lineLimit(1)
        Text(note)
            .font(Theme.font.themed(9.5))
            .foregroundStyle(.tertiary)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 8.5))
            .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .help("在对应页面打开")
}
```

- [ ] **Step 3: 构建 + 手动验证 + Commit**

Run: `make build` → Expected: Build complete。
Run: `swift run eureka` → 会话页选一个产生过记忆的会话（Memory 页任选一条有来源会话的记忆反推）→ 详情头部出现「本会话产出」，点击跳对应详情。

```bash
git add Sources/EurekaApp/StatusBar
git commit -m 'feat(ui): show session artifacts (memories and plans) in session detail'
```

---

### Task 10: CommandPaletteService（聚合逻辑，纯函数可测）

**Files:**
- Create: `Sources/EurekaApp/CommandPaletteService.swift`
- Modify: `Tests/EurekaTestsRunner/KnowledgeLinkTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
t.test("palette：合并去重（同目标取先出现者）并按组截断") {
    let a = CommandPaletteService.Hit(
        kind: .skill, key: "/tmp/s.md", title: "tdd", subtitle: "claude", snippet: nil,
        sessionId: nil, messageIdx: nil)
    let dup = CommandPaletteService.Hit(
        kind: .skill, key: "/tmp/s.md", title: "tdd", subtitle: "claude", snippet: "正文命中",
        sessionId: nil, messageIdx: nil)
    let b = CommandPaletteService.Hit(
        kind: .session, key: "sess-1", title: "会话一", subtitle: nil, snippet: nil,
        sessionId: "sess-1", messageIdx: nil)
    let merged = CommandPaletteService.merge([a, b, dup], perKindCap: 5)
    try expectEqual(merged.count, 2)
    try expectEqual(merged.filter { $0.kind == .skill }.count, 1)
}

t.test("palette：snippet 就近裁剪，命中词在窗口内") {
    let text = String(repeating: "前", count: 200) + "关键词" + String(repeating: "后", count: 200)
    let snippet = CommandPaletteService.snippet(text, query: "关键词", radius: 30)
    try expect(snippet.contains("关键词"))
    try expect(snippet.count <= 70)
}
```

Run: `make test` → Expected: 编译失败。

- [ ] **Step 2: 实现服务**

`Sources/EurekaApp/CommandPaletteService.swift`：

```swift
import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// ⌘K 全局搜索：内存元数据匹配（即时）+ FTS 正文命中（knowledge_fts / transcript_fts），
/// 250ms 防抖、≥2 字符起搜（沿用会话全文搜索惯例）。FTS 打不开时静默降级为纯元数据。
/// 线程模型与其它 service 一致：主线程读发布数据、私有队列跑 FTS、回主线程发布（不用 @MainActor）。
final class CommandPaletteService: ObservableObject {
    enum Kind: Int, CaseIterable {
        case session, skill, memory, instruction, plan

        var label: String {
            switch self {
            case .session: return "会话"
            case .skill: return "技能"
            case .memory: return "记忆"
            case .instruction: return "指令"
            case .plan: return "计划"
            }
        }
    }

    struct Hit: Identifiable, Equatable {
        var kind: Kind
        /// 去重键：知识面/计划 = 文件路径；会话 = session id
        var key: String
        var title: String
        var subtitle: String?
        /// 正文命中的上下文片段（元数据命中为 nil）
        var snippet: String?
        var sessionId: String?
        /// 会话正文命中时的消息定位
        var messageIdx: Int?
        var id: String { "\(kind.rawValue):\(key)" }
    }

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var searching = false

    private let sessionBrowser: SessionBrowserService
    private let skillMemory: SkillMemoryService
    private let plans: PlansService
    private let queue = DispatchQueue(label: "com.vinlee.eureka.palette", qos: .userInitiated)
    private var store: EurekaStore?
    private var pending: DispatchWorkItem?

    init(
        sessionBrowser: SessionBrowserService,
        skillMemory: SkillMemoryService,
        plans: PlansService
    ) {
        self.sessionBrowser = sessionBrowser
        self.skillMemory = skillMemory
        self.plans = plans
    }

    func reset() {
        query = ""
        hits = []
    }

    private func schedule() {
        pending?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        let item = DispatchWorkItem { [weak self] in self?.perform(trimmed) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func perform(_ query: String) {
        // 1) 主线程取元数据命中（services 的发布数据只能主线程读）
        let lowered = query.lowercased()
        var metadata: [Hit] = []
        for session in sessionBrowser.sessionsById.values
        where session.displayName.lowercased().contains(lowered)
            || session.id.lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .session, key: session.id, title: session.displayName,
                subtitle: session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                snippet: nil, sessionId: session.id, messageIdx: nil))
        }
        let snapshot = skillMemory.knowledgeSnapshot()
        for skill in snapshot.skills
        where skill.name.lowercased().contains(lowered)
            || (skill.description ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .skill, key: skill.path, title: skill.name,
                subtitle: skill.source.rawValue, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for memory in snapshot.memories
        where memory.title.lowercased().contains(lowered)
            || (memory.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: memory.kind == .instructions ? .instruction : .memory,
                key: memory.path, title: memory.title,
                subtitle: memory.projectName ?? memory.scope,
                snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for plan in plans.knowledgeSnapshot()
        where plan.title.lowercased().contains(lowered)
            || (plan.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .plan, key: plan.path, title: plan.title,
                subtitle: plan.project, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        // 2) FTS 下队列（正文命中），回主线程合并
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            var content: [Hit] = []
            if let store = self.store {
                for hit in (try? store.knowledge.search(query, limit: 20)) ?? [] {
                    let kind: Kind = switch hit.kind {
                    case "skill": .skill
                    case "instruction": .instruction
                    case "plan": .plan
                    default: .memory
                    }
                    content.append(Hit(
                        kind: kind, key: hit.path, title: hit.title,
                        subtitle: hit.project ?? hit.source,
                        snippet: Self.snippet(hit.text, query: query),
                        sessionId: nil, messageIdx: nil))
                }
                for hit in (try? store.search.search(query, limit: 20)) ?? [] {
                    content.append(Hit(
                        kind: .session, key: hit.sessionId,
                        title: "会话 \(hit.sessionId.prefix(8))",
                        subtitle: hit.role,
                        snippet: Self.snippet(hit.text, query: query),
                        sessionId: hit.sessionId, messageIdx: hit.messageIdx))
                }
            }
            DispatchQueue.main.async {
                guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
                else { return }  // 查询已变，丢弃过期结果
                var merged = CommandPaletteService.merge(metadata + content, perKindCap: 6)
                // 会话命中补真实名字
                merged = merged.map { hit in
                    var hit = hit
                    if hit.kind == .session, let id = hit.sessionId,
                       let info = self.sessionBrowser.sessionsById[id] {
                        hit.title = info.displayName
                    }
                    return hit
                }
                self.hits = merged
                self.searching = false
            }
        }
    }

    /// 合并去重：同 (kind, key) 取先出现者（元数据在前 → 标题命中优先），每组截断
    static func merge(_ hits: [Hit], perKindCap: Int) -> [Hit] {
        var seen = Set<String>()
        var byKind: [Kind: [Hit]] = [:]
        for hit in hits {
            guard seen.insert(hit.id).inserted else { continue }
            if byKind[hit.kind, default: []].count < perKindCap {
                byKind[hit.kind, default: []].append(hit)
            }
        }
        return Kind.allCases.flatMap { byKind[$0] ?? [] }
    }

    /// 就近裁剪：命中词前后各 radius 字符
    static func snippet(_ text: String, query: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: .caseInsensitive) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(
            range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(
            range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return String(flat[start..<end])
    }
}
```

注意：测试只调 `merge`/`snippet` 两个 static 纯函数，不构造 service 实例，无并发隔离问题。

- [ ] **Step 3: 跑测试确认通过 + Commit**

Run: `make test` → Expected: 全过。

```bash
git add Sources/EurekaApp/CommandPaletteService.swift Tests/EurekaTestsRunner
git commit -m 'feat(ui): add command palette aggregation service'
```

---

### Task 11: CommandPaletteView + ⌘K 菜单 + 浮层挂载

**Files:**
- Create: `Sources/EurekaApp/StatusBar/CommandPaletteView.swift`
- Modify: `Sources/EurekaApp/MainMenu.swift`
- Modify: `Sources/EurekaApp/StatusBar/PopoverRootView.swift`
- Modify: `Sources/EurekaApp/AppDelegate.swift`（构造与注入）

- [ ] **Step 1: MainMenu 加「查找」菜单**

`MainMenu.swift`：App 菜单块之后、窗口菜单块之前插入：

```swift
// 查找菜单：⌘K 全局搜索（动作经通知转发给 SwiftUI 层——菜单无法直接触达视图状态）
let findItem = NSMenuItem()
mainMenu.addItem(findItem)
let findMenu = NSMenu(title: "查找")
findItem.submenu = findMenu
let paletteItem = NSMenuItem(
    title: "全局搜索…",
    action: #selector(MenuActions.togglePalette(_:)),
    keyEquivalent: "k")
paletteItem.target = MenuActions.shared
findMenu.addItem(paletteItem)
```

文件尾部加：

```swift
/// 菜单动作的 NSObject 落点（菜单项必须有 target/selector；只做通知转发）
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func togglePalette(_ sender: Any?) {
        NotificationCenter.default.post(name: .eurekaToggleCommandPalette, object: nil)
    }
}
```

- [ ] **Step 2: 面板视图**

`Sources/EurekaApp/StatusBar/CommandPaletteView.swift`：

```swift
import EurekaKit
import SwiftUI

/// ⌘K 全局搜索浮层：输入框 + 按类型分组结果，↑↓ 移动 / 回车直达 / Esc 关闭。
struct CommandPaletteView: View {
    @ObservedObject var service: CommandPaletteService
    var onClose: () -> Void

    @State private var selection = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索会话 / 技能 / 记忆 / 指令 / 计划…", text: $service.query)
                    .textFieldStyle(.plain)
                    .font(Theme.font.themed(14))
                    .focused($inputFocused)
                    .onSubmit { route(at: selection) }
                if service.searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !service.hits.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(service.hits.enumerated()), id: \.element.id) { idx, hit in
                                row(hit, selected: idx == selection)
                                    .id(idx)
                                    .onTapGesture { route(at: idx) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, idx in proxy.scrollTo(idx) }
                }
            } else if service.query.count >= 2, !service.searching {
                Divider()
                Text("没有匹配结果")
                    .font(Theme.font.themed(12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 18)
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth)))
        .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
        .onAppear { inputFocused = true }
        .onChange(of: service.hits) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, service.hits.count - 1)); return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0); return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ hit: CommandPaletteService.Hit, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(hit.kind.label)
                .font(Theme.font.themed(9, .medium))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Theme.brandFill(0.10)))
                .foregroundStyle(Theme.brandFg)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(Theme.font.themed(12.5, .medium)).lineLimit(1)
                if let snippet = hit.snippet {
                    Text(snippet).font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let subtitle = hit.subtitle {
                Text(subtitle).font(Theme.font.themed(10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.tile)
                .fill(selected ? Theme.brandFill(0.12) : .clear))
        .contentShape(Rectangle())
    }

    /// 回车/点击直达：发对应 reveal 通知并关面板
    private func route(at index: Int) {
        guard service.hits.indices.contains(index) else { return }
        let hit = service.hits[index]
        switch hit.kind {
        case .session:
            if let id = hit.sessionId {
                NotificationCenter.default.post(name: .eurekaRevealSession, object: id)
            }
        case .skill:
            NotificationCenter.default.post(
                name: .eurekaRevealKnowledge, object: hit.key, userInfo: ["kind": "skill"])
        case .memory:
            NotificationCenter.default.post(
                name: .eurekaRevealKnowledge, object: hit.key, userInfo: ["kind": "memory"])
        case .instruction:
            NotificationCenter.default.post(
                name: .eurekaRevealKnowledge, object: hit.key, userInfo: ["kind": "instruction"])
        case .plan:
            NotificationCenter.default.post(name: .eurekaRevealPlan, object: hit.key)
        }
        onClose()
    }
}
```

会话正文命中的消息级定位：`route` 的 `.session` 分支在发 reveal 后追加（`revealMessage` 是 `SessionBrowserService.swift:346` 的公开方法，经通知走不通——面板持有 service 才能调；因此 `CommandPaletteView` 再接一个 `var onRevealMessage: ((String, Int) -> Void)? = nil`，`.session` 分支里 `if let idx = hit.messageIdx { onRevealMessage?(hit.sessionId!, idx) }`，由 PopoverRootView 注入 `sessionBrowser.revealMessage`）。

- [ ] **Step 3: PopoverRootView 挂浮层**

`PopoverRootView`：新增注入属性 `@ObservedObject var palette: CommandPaletteService`；body 的 `HStack`（`:82-86`）包一层 ZStack：

```swift
ZStack {
    HStack(spacing: 0) {
        sidebar
        Divider()
        content
    }
    if paletteVisible {
        Color.black.opacity(0.18)
            .ignoresSafeArea()
            .onTapGesture { closePalette() }
        VStack {
            CommandPaletteView(
                service: palette,
                onClose: { closePalette() },
                onRevealMessage: { id, idx in sessionBrowser.revealMessage(sessionId: id, messageIdx: idx) })
            .padding(.top, 90)
            Spacer()
        }
        .transition(.opacity)
    }
}
```

状态与开关：

```swift
@State private var paletteVisible = false

private func closePalette() {
    withAnimation(.easeOut(duration: 0.12)) { paletteVisible = false }
    palette.reset()
}
```

通知接收（既有 onReceive 群里追加）：

```swift
.onReceive(NotificationCenter.default.publisher(for: .eurekaToggleCommandPalette)) { _ in
    if paletteVisible { closePalette() } else {
        withAnimation(.easeOut(duration: 0.12)) { paletteVisible = true }
    }
}
```

- [ ] **Step 4: AppDelegate 构造注入**

服务属性区加：

```swift
private lazy var palette = CommandPaletteService(
    sessionBrowser: sessionBrowser, skillMemory: skillMemory, plans: plans)
```

`PopoverRootView(...)` 唯一构造点（grep `PopoverRootView(`）追加 `palette: palette`。

- [ ] **Step 5: 构建 + 手动验证 + Commit**

Run: `make build && make test` → Expected: 全过。
Run: `swift run eureka` → 主窗口按 ⌘K：面板弹出、输入 ≥2 字符出分组结果、↑↓/回车/Esc 正常、五类目标各点一个确认直达（会话正文命中要落到具体消息）。切到 brutal 风格再开一次面板确认不违和。

```bash
git add Sources/EurekaApp
git commit -m 'feat(ui): add command-k global search palette'
```

---

### Task 12: 全量验证

- [ ] **Step 1: 全量回归**

Run: `make build && make test`
Expected: Build complete；测试全过（603 + 新增若干）。

- [ ] **Step 2: 视觉回归（classic 不受影响的证明）**

```bash
swift run eureka --render-shell /tmp/shell-after-palette
```

Expected: 渲染正常（palette 是浮层不入 shell 渲染；侧栏/审计页与主干一致，肉眼过一遍无异常）。

- [ ] **Step 3: 手动验证清单（`swift run eureka`）**

1. ⌘K：元数据命中（技能名）、正文命中（记忆内容里的词）、会话正文命中（落到消息）各验一条。
2. Skills 详情：最近调用会话列表出现、可跳、不在索引范围的会话置灰。
3. 会话详情：产出区（记忆 + 物化计划）出现并可跳。
4. 新建一条记忆（app 内「＋」）→ 立即 ⌘K 搜它的正文 → 能命中（事件驱动索引生效）。
5. 设置 → 高级 → 清空全文索引 → ⌘K 会话正文命中消失、元数据命中仍在（降级不挂）。

- [ ] **Step 4: 收尾提交**

若有零散修正，按涉及范围用 `fix(ui)/fix(store)` 提交。发版由用户另行决定（不在本计划内）。
