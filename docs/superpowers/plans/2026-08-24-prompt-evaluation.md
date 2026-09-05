# Prompt 评价体系 Implementation Plan

> 2026-08-24 在 Claude Code 计划模式里写成、已按此实施；原件在仓库外（`~/.claude/plans/`），
> 2026-09-05 收进仓库以修复代码注释里"见计划"的断链。**Spec 前置：**`docs/specs/2026-08-23-prompt-library-design.md`（其「修订记录」记录了与本计划相关的差异）。

## Context（为什么做）

复用化改造已落地，用户指出评价好坏才是重点。方法论调研（[docs/research/2026-08-24-prompt-evaluation-methods.md](docs/research/2026-08-24-prompt-evaluation-methods.md)，35 条一手来源）确认零 LLM 约束下可用三支柱：行为/隐式信号（主场）、静态结构、程序化轨迹断言。Eureka 独占优势：本地拥有每条 prompt 的完整执行后果。呈现遵守三原则——不打神秘综合分（三档+证据+建议）、评价长在复用决策点、聚合层面才下结论；四条纪律——多信号聚合、重述先消歧（挣扎 vs 探索）、不以自报感知为金标准、按用户基线归一（v1 单用户简化）。

## 已实勘的关键事实

- 轮内诊断引擎现成：`TurnDiagnostics.evaluate(TurnGraphBuilder.build(turn), promptChars:)`（EurekaKit，7 规则三档带建议）；对齐键 `TurnInput.promptMessageId == PromptEntry.messageIdx`，nil 轮丢弃。
- 逐源能力：**full** = claude/codex/qoder（turnTrail 完整）；**trajectory**（仅步数/时长/clarify）= opencode/zcode/kimi/qwen/hermes/cursor/codebuddy；**followupOnly**（仅纠偏层）= gemini/grok；**excluded** = antigravity/trae（固定说明行会切出假步轮，必须排除）。
- Schema v23→24：[Schema.swift](Sources/EurekaStore/Schema.swift) :34 改版本 + :4 注释 + :54 后 DROP + :285 后建表；`prompt_eval` 全列纯派生才能进 DROP 块（红线）；扩 PromptsRepo 不开新 repo。
- 管线：`PromptExtractor.extract(from:at:)` 自己 load —— 加 `extract(messages:session:at:)` 纯函数重载，refresh 里 `TranscriptReader.load` 一次共享给 extract + `TurnSlicer.slice`（load 双调会翻倍解析成本）。
- upsert 范式照抄 `PromptsRepo.upsertExtracted`（事务 + ON CONFLICT）；eval 行全列覆盖；不可评价的源**不写行**（区分"没算"与"clean"）。

## 实现步骤（一次实施，Step 1/2 可并行）

### Step 1 · 静态结构层（EurekaKit）
新建 `Sources/EurekaKit/PromptStructure.swift`：
- `struct Flags: OptionSet`（acceptance 验收标准 / filePath 点名路径 / deicticStart 指代开头 / sectioned 结构分节）+ `encoded`/`decode`（落库字符串）
- `static func detect(_ text: String) -> Flags`
弱先验：只进详情页提示，不进色点。测试：中英验收字样/路径正则/"这个|那个|it"开头/标题列表/空串。

### Step 2 · 轮后纠偏层（EurekaKit）
新建 `Sources/EurekaKit/PromptFollowupSignal.swift`：
- `enum Reformulation: Int { none=0, struggle=1, explore=2 }`
- `isCorrective(_ next: String) -> Bool`（词表："不对/不是这/重来/搞错/理解错/还是有问题/没生效/revert/undo/wrong…"）
- `reformulation(prev:next:) -> Reformulation`：token 化 = CJK 字符 bigram + 英文按词小写；Jaccard ≥ 0.4 才算重述；替换主导（removed ≥ added）= struggle，新增主导 = explore；<4 token 不判（超短句失真）。
测试：词表命中/非命中、中英混排 Jaccard、替换 vs 新增消歧、短句下限。

### Step 3 · 评价聚合 + 能力枚举（EurekaKit）
新建 `PromptEvalCapability.swift`（`level(for: AgentSource)` 四档，Kit 叶子层供 Ingest/App 两侧引用）、`Models/PromptEval.swift`（与建表列一一对应）、`PromptEvaluator.swift`：
- `evaluate(promptId:turn:diagnostics:nextPromptText:capability:) -> PromptEval?`（excluded 返 nil）
- **升级规则（定死）**：基线 = diagnostics.severity（无则 clean）；corrective 命中 → max(基线, notice)；struggle 重述 → max(基线, notice)；corrective+struggle 同现或 corrective+error 结局 → bad；explore 不升级；structure flags 不参与升级。rule_ids 追加 `corrective/reformulated/outcome-error`。
测试：各能力档字段裁剪、四条升级路径、excluded 返 nil。

### Step 4 · 存储层（EurekaStore，schema v24）
[Schema.swift](Sources/EurekaStore/Schema.swift) 四处改动（见上）；建表：
```sql
CREATE TABLE IF NOT EXISTS prompt_eval (
    prompt_id TEXT PRIMARY KEY,
    severity INTEGER NOT NULL DEFAULT 0,
    rule_ids TEXT NOT NULL DEFAULT '',
    step_count INTEGER NOT NULL DEFAULT 0,
    error_steps INTEGER NOT NULL DEFAULT 0,
    duration REAL,
    reformulated INTEGER NOT NULL DEFAULT 0,
    corrective INTEGER NOT NULL DEFAULT 0,
    outcome TEXT NOT NULL DEFAULT 'clean',
    structure_flags TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_prompt_eval_severity
    ON prompt_eval(severity) WHERE severity > 0;
```
[PromptsRepo.swift](Sources/EurekaStore/PromptsRepo.swift) 加 `upsertEval(_ rows:)`（ON CONFLICT 全列覆盖）+ `evalMap() -> [String: PromptEval]`。测试：tempStore 往返；迁移测试仿 AuditRepoTests:152-163（v23 升 24 后 prompt_eval 空、prompts 用户标注保留）。

### Step 5 · 提取管线接入（EurekaIngest + EurekaApp）
[PromptExtractor.swift](Sources/EurekaIngest/PromptExtractor.swift)：加 `extract(messages:session:at:)` 重载，原函数降为 load+转调（保住现有 4 个测试调用点）。[PromptsService.swift](Sources/EurekaApp/PromptsService.swift) refresh：capability≠excluded 时 load 一次 → extract + slice → 按 messageIdx 对齐 → **仅 full 档**构图跑 TurnDiagnostics（控增量成本）→ PromptEvaluator（nextPromptText 取下一轮 promptText）→ prompts+eval 合并一次事务写入；末尾 `evalMap()` 读回主线程发布 `evalById` + `func eval(of:)`。测试：重载对齐正确、eval 落库、指纹未变跳过。

### Step 6 · UI 呈现（[PromptsView.swift](Sources/EurekaApp/StatusBar/PromptsView.swift)）
- PromptRow：**仅 severity ≥ notice** 画色点 + 首要问题词（不给每条判分；缺行静默无点，不显示"clean"）。
- PromptDetailView：「实际效果」证据卡——步数/时长/错误步/诊断信号 advice 原文/是否引来纠偏/结局/结构提示，按能力档降级文案（followupOnly 标注"仅纠偏信号"）。
- 列表加「最费劲」排序开关（severity desc → step_count desc）。
- PromptGroupRow 聚合徽章："×5 · 3 次费劲"。

## 验证

1. `swift build` + `swift run eureka-tests` 全绿（新增 4 套测试）。
2. REPL 真实数据：跑 PromptEvaluator 全库，对照此前实测（968 轮 clean 866/notice 59/bad 43、纠偏 3.5%）——升级规则后 notice/bad 占比应升至 ~12-15%，不该爆炸。
3. `make run` 实机：删除 prompt_sessions 指纹触发重扫 → 列表出现少量色点；点开一条 bad 的详情看证据卡完整；「最费劲」排序把 seatunnel 长会话的高纠偏 prompt 排前；gemini 来源详情显示"仅纠偏信号"。
4. 迁移安全：旧库升 v24 后 prompts 的收藏/标签原样，prompt_eval 随重扫回填。

## 明确不做（P2）

Bradley-Terry 同簇排名（重述链构造偏好对）、静态结构分与行为结果的本地相关性自验证、跨用户基线归一化。
