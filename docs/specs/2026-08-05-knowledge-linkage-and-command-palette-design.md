# 知识面联动与 ⌘K 全局搜索 — 设计稿

- 日期：2026-08-05
- 状态：**已评审通过，暂缓实施**（等待用户明确启动指令）
- 来源：用户痛点收敛为「页面间割裂」与「找东西难」；实现路线选定 **方案 B（FTS 统一索引）**，索引时机改为事件驱动以消除滞后。

## 背景与痛点

知识面五页（Plans / Skills / Memory / 会话 / 指令）现状盘点结论：

- 每页一个搜索框互不相通；知识面搜索只搜元数据不搜正文（`SkillMemoryService.swift:160-175`）；计划搜索不搜正文（`PlansService.swift:86-93`）；历史页无搜索。
- 技能没有「哪些会话调用过它」的反查（记忆有 originSession 跳转，技能只有聚合次数）；`tool_calls` 表聚合键 `(day, source, kind, name)` 无会话维度（`Schema.swift:109`），但它是**派生表**，升级重建全量回填（v10/v12 先例，`Schema.swift:15-17`）。
- 计划与会话零关联：`PlanEntry` 无 sessionId 字段，物化正文里的「会话 <id>」是纯文本（`PlanMaterializer.swift:317-338`）。
- 跨页 reveal 机制已有：`.eurekaRevealSession` → `PopoverRootView.swift:94-100`。

## 范围（三件事，一次交付）

### F1 ⌘K 命令面板

- **唤起**：`MainMenu` 新增「查找 → 全局搜索…」（⌘K），主窗口前台时可用；面板为 `PopoverRootView` 顶层 ZStack 浮层 `CommandPaletteView`；Esc 关闭、↑↓ 移动、Enter 直达。
- **输入**：250ms 防抖、≥2 字符起搜（沿用现有 FTS 惯例）。
- **结果**：按类型分组（会话/技能/记忆/指令/计划），行 = 来源徽标 + 标题 + 命中摘要（正文命中带上下文 snippet），组内按 rank。
- **直达路由**：会话复用 `.eurekaRevealSession`（正文命中沿 revealMessage 链路定位到消息）；新增 `.eurekaRevealKnowledge`（三签 + 打开详情）与 `.eurekaRevealPlan`。
- **后端**：新 FTS5 表 `knowledge_search`（trigram，与会话全文同款），列 `(kind, key, title, project, source, body)`，kind ∈ skill/memory/instruction/plan，key = 文件路径（物化计划用物化路径，key 稳定）。
- **索引时机（关键决策）**：`KnowledgeSearchIndexer` 不挂 5 分钟定时器，改为在 `SkillMemoryService` / `PlansService` 每次扫描完成后增量刷新（(path, mtime, size) 指纹 diff，删除已消失行）。启动预热、手动刷新、应用内写操作都触发 → 搜索新鲜度 = 列表新鲜度。
- 面板查询 = 内存元数据匹配 + FTS 正文命中，合并去重（同一目标取高 rank）。会话侧（SearchRepo）零改动。

### F2 技能 → 调用会话

- Schema **v13**：`tool_calls` 主键加 `session_id TEXT NOT NULL DEFAULT ''`，沿用派生表「升级重建全量重扫」机制自动回填历史；usage 扫描器写入时带上会话 id（转录文件即会话）。
- Store 新查询 `recentSessions(kind:name:limit:)` → (sessionId, lastTs, count)，默认 limit 10。
- `SkillDetailView` 统计段下新增「最近调用会话」卡：会话名（解析不到置灰显示 id，沿用记忆悬空置灰惯例）+ 相对时间 + 次数，点击 reveal session。非 Claude 源保留现有「无逐技能数据」文案。

### F3 会话 → 产出物

- `PlanEntry` 加 `sessionId: String?`，物化器写入（数据本来在手）。`PlansService` 加 `plans(sessionId:)`。
- `SkillMemoryService` 加按 `originSessionId` 反查记忆（内存索引现成）。
- `SessionDetailView` 概览卡下新增「本会话产出」区（有产出才显示）：记忆行 → Memory 详情，计划行 → Plans 详情；行样式沿用「终端归属历史」。

## 边界处理

- FTS 写入失败：静默降级为元数据搜索，面板不挂，log 记录。
- 单文件正文索引截断 256KB。
- 跳转目标暂不可达时：静默保留 focusPath 等下轮扫描重试（onChange(lastScanAt) 兜底），用户手动切签即放弃——比 toast 提示更安静（实施时的既定偏差）。
- 不涉及 classic 主题 invariant；Island/Mascot 不碰。

## 测试

- Store：v13 迁移（旧库升级 → 派生表重建）、`recentSessions` 查询、`knowledge_search` 增删查 + trigram 中文命中。
- `PlanMaterializer`：sessionId 物化断言（扩展现有 fixtures）。
- `CommandPaletteService`：聚合去重排序纯函数测试。
- 全量 `make test` 回归。

## 明确不做（本期）

- 一致性卡可行动化（用户未选）
- 计划 → 会话的反向跳转入口（数据字段本期已备好，UI 二期顺手）
- 系统级全局热键（用户选定主窗口内 ⌘K）
- 知识面文件系统监听（FSEvents）——与本期正交，另行立项

## 实施后记（2026-08-06）

- 结果排序：知识面正文命中按 `mtime DESC`（非 rank——trigram FTS 的 rank 对短查询区分度有限）；面板行是**类型徽标 + 来源副标题**。
- 二期候选：gemini/kimi 物化计划的 sessions.json 边车（会话 id 在手但文件名映射需改造）；brutal 风格下面板的硬边视觉语言；SessionDetailView 的 kind 字面量并入 `CommandPalette.Kind` 常量。
