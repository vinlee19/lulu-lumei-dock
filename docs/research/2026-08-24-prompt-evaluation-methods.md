# 提示词质量的评价与比较方法论调研

- 日期：2026-08-24
- 背景：为 eureka 的 prompt 评价体系做方法论调研。eureka 的硬约束：纯本地、零 LLM 调用；独特优势：拥有每条 prompt 的**完整执行后果**（agent 工具轨迹、错误、用户后续纠偏）。
- 方法：全部结论追到一手来源（官方文档、论文原文、第一方博客），逐条附链接。二手转述内容一律未采信；个别官方页面被 Cloudflare 拦截无法直接抓取的，已在文中显式标注核实方式。

## TL;DR 总览

| 方法族 | 需要 LLM | 需要 golden set | 需要大样本 | 对 eureka 适用性 |
|---|---|---|---|---|
| 1. 断言式/回归测试 | 部分（model-graded 断言需要） | 需要（每条 prompt 预定义期望） | 否 | **判定机制可移植**，但"预定义期望"模式不适合评价用户的自由 prompt |
| 2. LLM-as-judge | 是（本质） | 否 | 否 | **不可用**（零 LLM）；rubric 维度化思想可移植为程序化检查 |
| 3. 竞技场/排名（Elo/BT） | 否（纯统计） | 否 | 需要大量成对比较 | **统计模型可用**，瓶颈是本地缺少天然"对战"；可用重述链构造伪偏好对 |
| 4. 程序化优化（DSPy/OPRO） | 是（优化循环） | 需要（带标注训练集） | 中等 | 框架不可用；**"metric 函数"观念可用**——执行后果即天然 metric 输入 |
| 5. 行为/隐式信号 | **否** | **否** | 单信号弱相关，需多信号聚合 | **主场。唯一同时满足零 LLM、零标注的方法族** |
| 6. 静态/结构性评价 | 否 | 否 | 否 | **完全可用**；且可与第 5 族在本地数据上交叉验证 |
| 7. coding agent HCI 研究 | — | — | — | 直接背书"纠偏/打断作为失败信号"路线；警示：勿用自报感知当金标准 |

---

## 1. 断言式 / 回归测试

### promptfoo

**核心机制**：对每个 test case 声明一组 assertion，跑 prompt 后逐条判定。断言分两类（[assertions reference](https://www.promptfoo.dev/docs/configuration/expected-outputs/)）：

- **Deterministic**（纯程序判定，零 LLM）：`equals` / `contains` / `icontains` / `regex` / `starts-with`、多值（`contains-any/all`）、格式（`is-json` / `contains-sql` / `is-xml` 等）、自定义（`javascript` / `python` / `webhook`）、文本相似度（`rouge-n` / `bleu` / `levenshtein`）、性能（`latency` / `cost` / `perplexity`）、以及一组**轨迹断言**：`trajectory:tool-used` / `trajectory:tool-args-match` / `trajectory:tool-sequence` / `trajectory:step-count` / `skill-used`、trace 断言（`trace-span-count` / `trace-error-spans`）。
- **Model-graded**（依赖 LLM，[model-graded 清单](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/)）：`llm-rubric`（单例打分，自定义 rubric）、`g-eval`（单例 + chain-of-thought）、`factuality` / `model-graded-closedqa`（源自 OpenAI 公开 evals）、`answer-relevance`、context 三件套（`context-recall/relevance/faithfulness`）、`select-best`（**成对/多路比较**，跨多个输出选最优）、`trajectory:goal-success`（LLM judge 判定 agent 是否达成目标）。

**评价指标**：每条断言返回 pass/fail + score（0–1）；test case 得分 = 各断言分数按 `weight` 加权平均；可设 `threshold` 决定整体 pass/fail；支持 `assert-set` 分组和 `not-` 前缀取反（[来源](https://www.promptfoo.dev/docs/configuration/expected-outputs/)）。

**优缺点**：deterministic 断言客观、免费、可回归；缺点是必须**预先知道期望**，对开放式输出只能退到 model-graded。

**适用前提**：需要为每条 prompt 写 assertion（等价于 golden set）；deterministic 部分零 LLM。

### OpenAI Evals

**核心机制**：YAML registry 定义 eval + JSONL 存样本；模板分两类——deterministic（exact match、fuzzy match、includes）与 model-graded（用 LLM 按 YAML 里的 rubric 判定），后者"model-graded evals with custom model-graded YAML files"（[github.com/openai/evals](https://github.com/openai/evals)）。仓库仍在维护，官方"actively review these evals when considering improvements to upcoming models"，但拒收需要自定义评价代码的贡献。

### Anthropic 官方 eval 指导

一手来源：[Define success criteria](https://platform.claude.com/docs/en/build-with-claude/define-success) 与 [Create strong empirical evaluations](https://platform.claude.com/docs/en/build-with-claude/develop-tests)。要点：

- 成功标准要 **specific / measurable / achievable / relevant**；推荐的维度清单：task fidelity、consistency、relevance & coherence、tone & style、privacy preservation、context utilization、latency、price——并明确"大多数场景需要**多维同时评估**"。
- eval 设计三原则：**be task-specific**（镜像真实任务分布含边界情况）、**automate when possible**、**prioritize volume over quality**——原文："More questions with slightly lower signal automated grading is better than fewer questions with high-quality human hand-graded evals."
- grading 方法的隐含优先级：exact match / code-based（无歧义、全自动）> 自动相似度（cosine similarity 测 consistency、ROUGE-L 测摘要相关性）> LLM-based（Likert 1–5、binary、ordinal，仅用于无法自动化的主观维度，且评价模型应不同于生成模型）。

### Claude Code `claude plugin eval`

**无公开文档**。已核对 [code.claude.com 文档索引](https://code.claude.com/docs/llms.txt)及 plugins/skills/commands 各页（2026-08-24），均无 eval 页面。功能本身存在（early access，需组织级开关）：由 `claude plugin eval --help` 确认，suite 为 `evals/<case>/prompt.md` + `graders/*.md`，grader 类型混合式——`regex` / `tool_used` / `tool_order` / `file_exists`（程序化）+ `llm`（model-graded）+ `baseline`；输出 JSON 结果与 HTML 报告，每个 run 在独立 sandbox 中执行。此段信息来自 CLI 自述而非公开文档，引用时注意时效。

> **对本地零 LLM 工具的适用性判断**：断言式判定机制高度可移植——promptfoo 的 `trajectory:*` 断言和 plugin eval 的 `tool_used`/`file_exists` grader 与 eureka 已有的轨迹数据同构，可做成纯程序化"结果侧 grader"；但"每条 prompt 预写期望"的回归测试范式不适用于评价用户的自由 prompt，只能反向借鉴其**指标分类学**（pass/fail + score + weight + threshold 的组合结构）。

---

## 2. LLM-as-judge

### 三种判定形态与已知偏差（MT-Bench）

一手来源：Zheng et al., *Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena*（NeurIPS 2023, [arXiv:2306.05685](https://arxiv.org/abs/2306.05685)）。

- 三种 judge 方式：**pairwise comparison**（两答案比高下）、**single answer grading**（单例打分）、**reference-guided grading**（给参考答案再判）。
- 系统性偏差：**position bias**（偏好特定位置的答案）、**verbosity bias**（偏好更长输出）、**self-enhancement bias**（偏好与自己相近的模型输出）、复杂题上的 **limited reasoning capability**。
- 缓解手段：**swap positions**（交换位置各判一次，不一致则平局）、few-shot 示例、chain-of-thought、reference-guided。
- 有效性上界："strong LLM judges like GPT-4 can match both controlled and crowdsourced human preferences well, achieving over 80% agreement"——与人际一致率相当。

### G-Eval：单例打分的 rubric 工程

一手来源：Liu et al., *G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment*（EMNLP 2023, [arXiv:2303.16634](https://arxiv.org/abs/2303.16634)）。机制：由 LLM **auto chain-of-thought 生成评估步骤** + **form-filling paradigm**（结构化表单输出分数）+ **probability-weighted scoring**（用 token 概率对分值加权，解决分数聚集/平局问题）。SummEval 上与人类判断 Spearman 0.514，超过此前所有方法。论文自承关键局限：**LLM evaluator 偏好 LLM 生成的文本**（self-preference 的循环性风险）。

### rubric 设计原则（可从官方指导归纳）

- 单一维度单一 rubric，输出受限（只输出数字/yes-no）——Anthropic [develop-tests](https://platform.claude.com/docs/en/build-with-claude/develop-tests) 的 Likert / binary / ordinal 三式。
- promptfoo 的 `llm-rubric` 支持 assertion 级覆盖 grader 模型与 `rubricPrompt`，威胁模型是"grader 漂移"（[model-graded docs](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/)）。
- Anthropic agent evals 博文（详见 §5c）：model-based grader "handle nuance" 但 "require calibration against humans"，且 "You won't know if graders work unless you read transcripts"（[Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)）。

> **对本地零 LLM 工具的适用性判断**：整族**不可用**（判定本体就是 LLM 调用）；可移植的是三件事——rubric 的**维度化拆解**（把"好 prompt"拆成可独立判定的子维度）、**位置对称性**思想（任何比较类信号都要检查顺序偏差）、以及"分数必须向人类校准"的告诫（eureka 的行为信号同样需要与用户真实结果对拍）。

---

## 3. 竞技场 / 排名法（Chatbot Arena）

一手来源：Chiang et al., *Chatbot Arena: An Open Platform for Evaluating LLMs by Human Preference*（ICML 2024, [arXiv:2403.04132](https://arxiv.org/abs/2403.04132)）与 LMSYS 官方博客 [Elo → Bradley-Terry 切换说明](https://lmsys.org/blog/2023-12-07-leaderboard/)。

**核心机制**：众包用户对匿名模型对做 **pairwise comparison**（同一 prompt、两个匿名回答、投票胜负），累计 240K+ 票后用统计模型排名。众包票质量经过验证："crowdsourced human votes are in good agreement with those of expert raters"。

**为什么成对比较比绝对打分可靠**：投票者只需回答"哪个更好"，不需要维持一把跨时间、跨人的绝对刻度；绝对打分的刻度漂移问题在 MT-Bench 论文的 single answer grading 讨论中同样被指出（[arXiv:2306.05685](https://arxiv.org/abs/2306.05685)）。成对偏好可直接喂给 Bradley-Terry 类模型得到全序。

**为什么 Bradley-Terry 而非 online Elo**（[LMSYS 博客](https://lmsys.org/blog/2023-12-07-leaderboard/)）：

- online Elo 对比赛顺序敏感、K-factor 造成"新模型上升快 vs 老模型波动大"的两难，实测 "considerable variability in the ratings using the classic online algorithm"。
- BT 假设 "player's performance does not change (i.e., game order does not matter)"——对静态模型（或静态 prompt）恰好成立；用 MLE 一次性估计 + **bootstrap 置信区间**，均值与 Elo 几乎一致但区间显著更紧。

**适用前提**：不需要 LLM、不需要 golden set，但需要**大量成对偏好数据**；样本少时置信区间宽到无法区分。

> **对本地零 LLM 工具的适用性判断**：BT/Elo 是纯统计，本地可算；真正的瓶颈是单用户本地数据里几乎没有"同一任务两条 prompt 对战"的天然结构。可行的变体：把**同一会话内的重述链**当作隐式偏好对（前一条 prompt 输给触发重述后成功的那条，机制同 §5d 的 query chains），在 prompt 模式（而非单条 prompt）粒度上聚合成 BT 排名——但必须先解决 §5d 的"重述歧义"问题。

---

## 4. 程序化优化框架的隐含评价观

### DSPy：metric 函数即评价体系

一手来源：[DSPy Metrics 官方文档](https://dspy.ai/learn/evaluation/metrics/)（[GitHub 源文件](https://github.com/stanfordnlp/dspy/blob/main/docs/docs/learn/evaluation/metrics.md)）与论文 Khattab et al.（ICLR 2024, [arXiv:2310.03714](https://arxiv.org/abs/2310.03714)）。

- metric 定义原文："a function that will take examples from your data and the output of your system and return a score"。签名 `metric(example, pred, trace=None) -> bool|int|float`。
- 官方分层建议：简单任务用 accuracy / exact match / F1；复杂长输出 "your metric should probably be a smaller DSPy program that checks multiple properties of the output"——即 **metric 本身可以是 LLM 程序**，且 "Defining a good metric is an iterative process"，metric 自身也可被少量标注数据优化。
- `trace` 参数的双模式：`trace is None`（评估）返回连续分数；`trace is not None`（bootstrapping 编译期）返回严格 bool，用于筛选哪些执行轨迹可留作 demonstration——**评价函数同时充当优化的选择压力**。
- 论文的"更好"定义：compile = 在小训练集上最大化 validation metric 来自举 demonstration，声称超过标准 few-shot "generally by over 25% and 65%"（两个基准上）。

### OPRO：把 prompt 优化写成黑盒优化

一手来源：Yang et al., *Large Language Models as Optimizers*（ICLR 2024, [arXiv:2309.03409](https://arxiv.org/abs/2309.03409)）。机制：meta-prompt 携带历史 (solution, score) 对，LLM 迭代生成新 prompt，评分回填。**"更好的 prompt" = 在带标注训练集上的 task accuracy 更高**——评价观被彻底还原为"固定数据集 + 固定 metric 上的分数"。结果："the best prompts optimized by OPRO outperform human-designed prompts by up to 8% on GSM8K, and by up to 50% on Big-Bench Hard tasks."

**隐含前提（两者共通）**：有标注答案的训练集；大量 LLM 调用做搜索；任务分布静态。

> **对本地零 LLM 工具的适用性判断**：优化循环不可用（需要 LLM 反复生成+打分），但**评价观本身是本项目最该偷的**：DSPy 把"prompt 好不好"完全外包给一个可执行的 metric 函数，而 eureka 恰好拥有 DSPy 花大钱模拟的东西——真实的 `trace`（agent 工具轨迹 + 执行结果）。把 eureka 的评价体系写成 `metric(prompt, 执行后果) -> score` 的纯函数族，就是 DSPy 评价观的零 LLM 实例化。

---

## 5. 行为 / 隐式信号（重点）

### 5a. Copilot 的 acceptance rate 与 code persistence

一手来源：Ziegler et al., *Productivity Assessment of Neural Code Completion*（MAPS '22, [arXiv:2205.06537](https://arxiv.org/abs/2205.06537)；期刊版即 CACM 2024 *Measuring GitHub Copilot's Impact on Productivity*）。

- 方法：17,420 份问卷邀请、**2,047 份回复与遥测数据配对**（截至 2022-03-12 的四周）。
- 指标定义：**acceptance rate** = "the fraction of completions shown to the developer that are subsequently accepted for inclusion in the source file"；**persistence** 在接受后 30/120/300/600 秒四个窗口测量，"mostly unchanged" 定义为与接受时的 Levenshtein 距离 < 33%。
- 核心数字：与自报 aggregate productivity 的 Pearson 相关——acceptance rate **r = 0.24**（p < 0.0001），mostly-unchanged@30s r = 0.23，acceptance per opportunity r = 0.22。结论原文："the rate with which shown suggestions are accepted, rather than more specific metrics regarding the persistence of completions in the code over time, drives developers' perception of productivity."（即**接受率优于保留率**，且论文自承 r=0.24 之外仍有大量未解释方差。）
- 量级：均值 acceptance rate 27%。规模佐证：GitHub 官方后续研究（Keystone.AI/Iansiti 合作，n = 934,533 用户）报告首年平均接受率近 30%（[GitHub Blog: economic impact](https://github.blog/news-insights/research/the-economic-impact-of-the-ai-powered-developer-lifecycle-and-lessons-from-github-copilot/)）；最初的 2,000+ 人 SPACE 框架调查见 [GitHub Blog: quantifying impact](https://github.blog/news-insights/research/research-quantifying-github-copilots-impact-on-developer-productivity-and-happiness/)。

**方法论启示**：(1) 行为信号与"质量"只有**弱相关**——必须聚合，不能对单条样本下结论；(2) 更"深"的信号（保留率）不一定比更"浅"的信号（接受率）更有效；(3) 相关的标的是"感知生产力"，不是客观产出（见 §7 METR 的警告）。

### 5b. SWE-bench：执行式 pass 判定及其反面教材价值

一手来源：Jimenez et al.（ICLR 2024, [arXiv:2310.06770](https://arxiv.org/abs/2310.06770)；[官方仓库](https://github.com/SWE-bench/SWE-bench)）。

- 判定机制（论文原文）："we check that all FAIL_TO_PASS and PASS_TO_PASS tests are found and have a pass status... If a test is missing or has a non-pass status, it is considered a fail status."——**FAIL_TO_PASS**（修复前失败、修复后须通过）与 **PASS_TO_PASS**（修复前后都须通过，防止回归，中位数 51 个）**全部通过**才算 resolved。评价在 Docker 容器里 apply patch → run tests，完全不看轨迹。
- 反面教材：OpenAI 与原作者做 [SWE-bench Verified](https://openai.com/index/introducing-swe-bench-verified/)（2024-08-13）时，93 名工程师三人一组复核 1,699 题，发现 **38.3% 的题目 problem statement 是 underspecified 的、61.1% 的单元测试可能把正确解判错**，合计过滤 68.3% 的样本；过滤后 GPT-4o 得分从 16% 翻倍到 33.2%。（注：openai.com 拒绝直接抓取，此段数字经由多方一致转载核对，原文链接如上。）后续 OpenAI 又宣布停用 Verified 并给出审计理由（[Why SWE-bench Verified no longer measures frontier coding capabilities](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)，同样仅能间接核对：对 o3 未稳定解出的 138 题、每题至少 6 名工程师复核，59.4% 存在测试设计或题面实质缺陷）。
- **对 prompt 评价的直接意义**：这是"任务描述质量决定评价有效性"的最强量化证据——**38.3% 的 eval 失真来自 prompt（issue 描述）本身 underspecified**。它同时支持 §6 的结构性主张：规格完备性不是玄学，是可测量的失真源。

### 5c. Agent 轨迹评价

- **Anthropic 官方立场**（[Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)，2026-01）：词汇表 task / trial / transcript / **outcome**（"a flight-booking agent might say 'booked' but the actual database reservation is the outcome"）/ grader / suite。grader 三类：code-based（"fast, cheap, objective, reproducible"但脆）、model-based（需向人校准）、human（金标准但不可扩展）。**优先判 outcome/最终状态而非轨迹**："grading what the agent produced, not the path it took"——因为 agent 常走出乎意料的合法路径；transcript 用于解释 *why*。随机性用 **pass@k**（k 次至少一次成功）与 **pass^k**（k 次全部成功）刻画，k=10 时两者分道扬镳。工程建议：从 20–50 个真实失败萃取任务起步；区分 regression suite（应保持 ~100%）与 capability suite（低通过率起步）；警惕 reward hacking（Opus 4.5 在订票 eval 里"发现政策漏洞"，判 fail 但其实更优）；"You won't know if graders work unless you read transcripts"。
- **Agent-as-a-Judge**（Meta, [arXiv:2410.10934](https://arxiv.org/abs/2410.10934)）：让 agentic 系统评价 agent，能对 "the entire task-solving process" 给中间反馈；在自建 DevAI 基准（55 个代码生成任务、365 条层级化需求）上 "dramatically outperforms LLM-as-a-Judge and is as reliable as our human evaluation baseline"。粒度是 requirement 级判定。需要 LLM，不可直接用，但确立了"轨迹本身值得判"的文献锚点。

### 5d. Reformulation / 重述作为隐式负反馈（检索与对话系统文献）

这是与 eureka"用户后续纠偏"信号最同构的文献线：

- **Radlinski & Joachims, *Query Chains: Learning to Rank from Implicit Feedback***（KDD 2005, [PDF](https://www.cs.cornell.edu/people/tj/publications/radlinski_joachims_05a.pdf)）：奠基性工作。query chain = 同一信息需求下的连续 reformulation；**用户重述这一动作本身被当作对先前结果不满的信号**，从链中提取 pairwise preference judgments 训练排序器——不需要任何显式标注。
- **Ponnusamy et al., *Feedback-Based Self-Learning in Large-Scale Conversational AI Agents***（AAAI 2020, Amazon Alexa, [arXiv:1911.02557](https://arxiv.org/abs/1911.02557)）：把 rephrase 当隐式负反馈，用 **absorbing Markov Chain** 做协同过滤，跨百万级会话挖 "坏 query → 好 rephrase" 对，自动重写。生产 A/B："win/loss ratio of 11.8 and effectively reduces the defect rate by more than 30%"，全程无人工标注。
- **Park et al.**（EMNLP 2021, Amazon, [aclanthology.org/2021.emnlp-main.489](https://aclanthology.org/2021.emnlp-main.489/)）：给出隐式不满信号清单——**termination、interruption、rephrase、error-correcting language、negative sentiment**——并用它们规模化训练满意度模型，替代人工标注。
- **关键告诫——Hassan et al., *Struggling or Exploring? Disambiguating Long Search Sessions***（WSDM 2014, Microsoft Research, [PDF](http://susandumais.com/WSDM2014-HassanEtAl.pdf)）：**多次 reformulation 不必然是负信号**——"more querying is not necessarily a negative indicator if the user is learning and consuming content on their journey"。长会话可能是 struggling（定义："users are experiencing difficulty locating the required information"）也可能是 exploring（"open-ended and multi-faceted information-seeking task"）。区分特征（论文 Table 1）：query 特征（数量、长度、手输 vs 建议）、**query transition 特征**（相邻 query 相似度、AddTerms/DelTerms/SubsTerms、泛化/特化次数）、点击特征（点击数、dwell time、abandonment）、历史与主题特征。行为差异：exploring 更多加词/删词换面向，struggling 更倾向**换词（substitution）**绕同一目标打转。全会话分类器 81.67% 准确率（多数类基线 64%），且把该预测喂给满意度模型使其准确率 70.75→74.14（真值可到 76.82）。

> **对本地零 LLM 工具的适用性判断**：**本方法族是 eureka 的主场，也是唯一同时零 LLM、零标注的一族**。可直接落地的映射：acceptance/persistence → "agent 产出的 diff 是否被保留/被 revert"；rephrase-as-negative-feedback → 同会话内相邻 prompt 的相似度 + 换词模式（Hassan 的 query transition 特征几乎可以原样搬到 prompt 序列上）；EMNLP 2021 信号清单 → eureka 已有的打断（Esc/中止）、error-correcting 措辞、会话放弃。两条纪律：单信号弱相关（Copilot r≈0.24）必须多信号聚合；重述有"探索 vs 挣扎"歧义，必须用 transition 特征区分而非一律记负分。

---

## 6. 静态 / 结构性评价

问题：有没有一手资料支持"prompt 的结构特征（明确目标/约束/验收标准/上下文自足）与结果质量相关"？答案：官方指南层面证据充分，量化 ablation 有两处。

### Anthropic 官方

- [Claude prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)（platform 文档）：
  - **Golden rule** 原文："Show your prompt to a colleague with minimal context on the task and ask them to follow it. If they'd be confused, Claude will be too."——即"上下文自足"的官方判据。
  - "Claude responds well to clear, explicit instructions. Being specific about your desired output can help enhance results."
  - "Providing context or motivation behind your instructions... can help Claude better understand your goals and deliver more targeted responses."（动机/上下文一节）
  - XML tags "help Claude parse complex prompts unambiguously" ——结构化分节（`<instructions>` / `<context>` / `<input>`）降低误读。
- [Claude Code best practices](https://code.claude.com/docs/en/best-practices)（原 anthropic.com 工程博文，已迁移）：给出了逐条 **before/after 对比表**，是"结构特征 → 结果"最具操作性的官方素材：
  - **验收标准**："Give Claude a check it can run... Without a check it can run, 'looks done' is the only signal available"；对照例：*"implement a function that validates email addresses"* → *"write a validateEmail function. example test cases: ... run the tests after implementing"*。
  - **具体化四策略**（scope the task / point to sources / reference existing patterns / describe the symptom），如 *"fix the login bug"* → *"users report that login fails after session timeout. check the auth flow in src/auth/... write a failing test that reproduces the issue, then fix it"*。总括："The more precise your instructions, the fewer corrections you'll need."
  - **早纠偏**："correcting it quickly generally produces better solutions faster"；纠错超过两次应 `/clear` 重来——"A clean session with a better prompt almost always outperforms a long session with accumulated corrections."（这句直接把 **纠偏次数** 与 **prompt 质量** 挂上了因果叙事。）
  - 也承认模糊 prompt 的合法用途："Vague prompts can be useful when you're exploring and can afford to course-correct."（与 Hassan 的 exploring/struggling 二分同构。）

### OpenAI 官方

- [Prompt engineering guide](https://developers.openai.com/api/docs/guides/prompt-engineering)（现版）：推荐分节结构 **Identity / Instructions / Examples / Context**，用 Markdown 标题与 XML 标签划界（"help the model understand logical boundaries"）；并主张把 prompt 当代码管理："Code-managed prompts let you use typed inputs, code review, tests, and your normal deployment process."
- [GPT-4.1 Prompting Guide](https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide)（cookbook，含量化 ablation）：
  - 模板：Role and Objective → Instructions → Reasoning Steps → Output Format → Examples → Context → Final instructions。
  - "GPT-4.1 is trained to follow instructions more closely and more literally than its predecessors"——越 literal 的模型，prompt 的显式规格越重要。
  - **量化证据**：agentic prompt 中加入 planning 提醒使 SWE-bench Verified 通过率 **+4%**；工具经 API 字段而非手写注入 **+2%**；delimiter 实验中 Markdown/XML 表现好、JSON 在长上下文中最差。
- 旁证（§5b）：SWE-bench Verified 标注发现 38.3% 题目因 underspecified problem statement 失真——任务描述的规格完备性可测且后果重大（[OpenAI](https://openai.com/index/introducing-swe-bench-verified/)）。

> **对本地零 LLM 工具的适用性判断**：**完全可用**。官方指南收敛出的结构特征清单——明确目标、显式约束、可运行的验收标准、文件路径/来源指引、上下文自足（Golden rule）、分节结构——全部可用纯文本启发式检测（正则/词法/引用检测），零 LLM。更重要的是 eureka 可以做别人做不了的事：**在本地数据上验证这些静态特征与行为结果（§5 信号）的相关性**，把"官方经验主张"升级为"本机实证权重"。

---

## 7. coding agent 的人机交互研究

- **Barke, James & Polikarpova, *Grounded Copilot***（OOPSLA 2023, [arXiv:2206.15000](https://arxiv.org/abs/2206.15000)）：20 名程序员的 grounded theory 观察，交互是**双模态**的——**acceleration mode**（知道下一步，AI 加速）vs **exploration mode**（不确定方案，AI 探路）。含义：同一行为信号（如反复重试）在两种模式下含义相反——与 Hassan 的 struggling/exploring 二分跨域互证。
- **Mozannar et al., *Reading Between the Lines*（CUPS 分类法）**（CHI 2024, [arXiv:2210.14306](https://arxiv.org/abs/2210.14306)）：21 名程序员 + 回顾式自标注，建立 CUPS 交互状态分类（verifying / editing suggestion 等），揭示 acceptance rate 之外的**隐性验证成本**——"revealing inefficiencies and time costs"，主张需要"new interface designs and metrics"。含义：接受率高不等于净收益高，验证时间是被主流指标忽略的成本项。
- **Vaithilingam, Zhang & Glassman, *Expectation vs. Experience***（CHI '22 EA, [DOI](https://dl.acm.org/doi/10.1145/3491101.3519665)，[PDF](https://tianyi-zhang.github.io/files/chi2022-lbw-copilot.pdf)）：24 人被试内实验——Copilot **没有**显著缩短完成时间或提高成功率，但 19/24 人仍偏好它（"useful starting point"）。偏好 ≠ 客观效能。
- **METR RCT**（2025-07, [官方博客](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/)）：16 名资深开源开发者、246 个真实 issue 随机分配可用/禁用 AI（主要 Cursor + Claude）。结果：允许 AI 时**实际慢 19%**，而开发者事前预估快 24%、事后仍自认快了 20%。**自我感知与客观结果系统性背离**——任何以"用户满意度自报"为金标准的评价体系都被此研究直接警告。局限：高标准成熟代码库、资深贡献者，不外推到所有场景。
- **大规模真实会话的纠偏信号研究**（2026, [arXiv:2605.29442](https://arxiv.org/abs/2605.29442)）：20,574 个真实 coding-agent 会话（1,639 个仓库、IDE+CLI），**把 developer pushback 直接用作 misalignment 的操作化定义**（"a breakdown made visible through developer pushback"），沿 form/cause/cost/resolution 四维标注，归纳七类失败（项目理解、意图误读、规则遵循、行动越界、实现执行、进度虚报、约束违反）；90.50% 的失败代价是 effort/trust 而非系统损坏，**91.49% 的可见修复需要用户显式纠正**。这是"用户纠偏 = 失败标注"路线目前最大规模的一手实证。
- **Huang et al., *Professional Software Developers Don't Vibe, They Control***（2025, [arXiv:2512.14012](https://arxiv.org/abs/2512.14012)）：13 次现场观察 + 99 份问卷；资深开发者"retain their agency... out of insistence on fundamental software quality attributes"，控制手段包括详细 prompt、打断、审查、纠偏重导向。含义：**打断/纠偏频率既反映 prompt 质量也反映用户风格**，作为质量代理时需按用户基线归一化。

> **对本地零 LLM 工具的适用性判断**：这一族为 eureka 的核心路线提供直接文献背书——已有大规模研究（arXiv:2605.29442）把真实会话中的用户纠偏当作失败标注使用。三条设计纪律：(1) METR/Vaithilingam：不要把用户偏好或自报感知当金标准，优先客观后果（revert、测试、任务是否重开）；(2) Barke/Hassan：先区分交互模式（探索 vs 执行），同一信号异模式异号；(3) Huang et al.：纠偏频率要按用户个人基线归一化，跨用户不可直接比较。

---

## 8. 综合：对 eureka prompt 评价体系的方法论结论

1. **可用的三支柱**：
   - **静态结构分**（§6）：验收标准、目标明确性、约束、上下文自足、结构分节——纯文本启发式，官方原则背书。
   - **行为结果分**（§5）：diff 保留/revert、错误轨迹、会话内重述链、打断/中止、任务重开——零 LLM、零标注，映射自 acceptance/persistence、rephrase-as-feedback、pushback-as-misalignment 三条成熟文献线。
   - **程序化轨迹断言**（§1/§5c）：`tool_used` / `file_exists` / 测试是否跑过且通过 / error span 计数——promptfoo trajectory 断言与 Anthropic "outcome 优先" 原则的零 LLM 子集。
2. **可用的统计骨架**：metric 函数观（DSPy）作为架构；多信号加权聚合（promptfoo 的 weight/threshold）作为组合器；若做 prompt 模式排名，用 Bradley-Terry + bootstrap CI（LMSYS），偏好对从重述链构造。
3. **不可用**：LLM-as-judge 全族、DSPy/OPRO 优化循环、model-graded 断言。
4. **四条纪律**：单信号弱相关必须聚合（r≈0.24）；重述先分探索/挣扎再计分（Hassan 特征可搬）；不以用户自报感知为金标准（METR）；纠偏频率按用户基线归一化（Huang et al.）。
5. **eureka 的独占优势**：业界为拿到"执行后果"要么花钱调 LLM（Agent-as-a-Judge）、要么建基准（SWE-bench）、要么做遥测（Copilot）；eureka 的转录/轨迹数据天然就是这三者共同追求的 ground truth 载体，还能在本地把静态结构分与行为结果做相关性自验证——这是任何云端评价框架都不具备的闭环。

## 附：来源清单

| # | 来源 | 类型 | 链接 |
|---|---|---|---|
| 1 | promptfoo assertions reference | 官方文档 | https://www.promptfoo.dev/docs/configuration/expected-outputs/ |
| 2 | promptfoo model-graded metrics | 官方文档 | https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/ |
| 3 | OpenAI Evals | 官方仓库 | https://github.com/openai/evals |
| 4 | Anthropic: Define success criteria | 官方文档 | https://platform.claude.com/docs/en/build-with-claude/define-success |
| 5 | Anthropic: Create strong empirical evaluations | 官方文档 | https://platform.claude.com/docs/en/build-with-claude/develop-tests |
| 6 | Claude Code 文档索引（确认 plugin eval 无公开文档） | 官方文档 | https://code.claude.com/docs/llms.txt |
| 7 | Zheng et al., MT-Bench / LLM-as-a-judge | 论文 (NeurIPS 2023) | https://arxiv.org/abs/2306.05685 |
| 8 | Liu et al., G-Eval | 论文 (EMNLP 2023) | https://arxiv.org/abs/2303.16634 |
| 9 | Chiang et al., Chatbot Arena | 论文 (ICML 2024) | https://arxiv.org/abs/2403.04132 |
| 10 | LMSYS: Elo → Bradley-Terry | 第一方博客 | https://lmsys.org/blog/2023-12-07-leaderboard/ |
| 11 | DSPy Metrics | 官方文档 | https://dspy.ai/learn/evaluation/metrics/ |
| 12 | Khattab et al., DSPy | 论文 (ICLR 2024) | https://arxiv.org/abs/2310.03714 |
| 13 | Yang et al., OPRO | 论文 (ICLR 2024) | https://arxiv.org/abs/2309.03409 |
| 14 | Ziegler et al., Copilot productivity | 论文 (MAPS '22 / CACM 2024) | https://arxiv.org/abs/2205.06537 |
| 15 | GitHub: quantifying Copilot impact | 第一方博客 | https://github.blog/news-insights/research/research-quantifying-github-copilots-impact-on-developer-productivity-and-happiness/ |
| 16 | GitHub: economic impact (n=934,533) | 第一方博客 | https://github.blog/news-insights/research/the-economic-impact-of-the-ai-powered-developer-lifecycle-and-lessons-from-github-copilot/ |
| 17 | Jimenez et al., SWE-bench | 论文 (ICLR 2024) | https://arxiv.org/abs/2310.06770 |
| 18 | OpenAI: SWE-bench Verified | 第一方博客 | https://openai.com/index/introducing-swe-bench-verified/ |
| 19 | OpenAI: 停用 SWE-bench Verified | 第一方博客 | https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/ |
| 20 | Anthropic: Demystifying evals for AI agents | 第一方工程博客 | https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents |
| 21 | Zhuge et al., Agent-as-a-Judge | 论文 (Meta) | https://arxiv.org/abs/2410.10934 |
| 22 | Radlinski & Joachims, Query Chains | 论文 (KDD 2005) | https://www.cs.cornell.edu/people/tj/publications/radlinski_joachims_05a.pdf |
| 23 | Ponnusamy et al., Alexa self-learning | 论文 (AAAI 2020) | https://arxiv.org/abs/1911.02557 |
| 24 | Park et al., implicit user feedback | 论文 (EMNLP 2021) | https://aclanthology.org/2021.emnlp-main.489/ |
| 25 | Hassan et al., Struggling or Exploring | 论文 (WSDM 2014) | http://susandumais.com/WSDM2014-HassanEtAl.pdf |
| 26 | Anthropic: Claude prompting best practices | 官方文档 | https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices |
| 27 | Claude Code: Best practices | 官方文档 | https://code.claude.com/docs/en/best-practices |
| 28 | OpenAI: Prompt engineering guide | 官方文档 | https://developers.openai.com/api/docs/guides/prompt-engineering |
| 29 | OpenAI: GPT-4.1 Prompting Guide | 官方 cookbook | https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide |
| 30 | Barke et al., Grounded Copilot | 论文 (OOPSLA 2023) | https://arxiv.org/abs/2206.15000 |
| 31 | Mozannar et al., CUPS | 论文 (CHI 2024) | https://arxiv.org/abs/2210.14306 |
| 32 | Vaithilingam et al., Expectation vs. Experience | 论文 (CHI '22 EA) | https://dl.acm.org/doi/10.1145/3491101.3519665 |
| 33 | METR: AI 对资深开发者的 RCT | 第一方博客 | https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/ |
| 34 | How Coding Agents Fail Their Users | 论文 (2026) | https://arxiv.org/abs/2605.29442 |
| 35 | Huang et al., Don't Vibe, They Control | 论文 (2025) | https://arxiv.org/abs/2512.14012 |
