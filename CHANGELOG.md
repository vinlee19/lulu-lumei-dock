# Changelog

All notable changes to lulu-lumei-dock are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/).

## [0.17.0] - 2026-07-30

### Added

- **Memory libraries** — each project's `memory/` directory folds into one row (entry count, size,
  latest change, how many origin sessions are still openable) and opens into its own page with a
  type-distribution card and type filters. Searching expands libraries so a query still reaches
  individual entries. Qwen's identically-shaped `projects/<encoded>/memory/` is covered too, and a
  library holding only an index is labeled as such instead of showing "0".
- **Memory graph** — a third layout beside list/icons, and a one-hop version on memory detail pages.
  Nodes are the index, type swimlanes, entries, and **the session each memory was written in**;
  edges are index→category, `[[wiki link]]` references (mutual ones merged into one bidirectional
  edge), and memory→session. Clicking a session node jumps to the session page over the same
  `eurekaRevealSession` channel the usage page uses; sessions whose transcript is gone
  are drawn dashed-grey and are deliberately not clickable. Links that resolve to nothing and deleted
  origin sessions are reported in the legend rather than silently omitted.
- Graph construction and layout live in `EurekaKit` as pure functions (following `TurnGraph`), so both
  are unit-testable and offscreen-renderable. The layout is a uniform grid — columns are type
  swimlanes plus a session lane, rows are index/headers/entries — and **no edge segment ever crosses a
  node** by construction: horizontal runs only travel row gutters, vertical runs only column gutters.
  When lanes don't fit the viewport the canvas grows and scrolls horizontally; only a node count over
  the limit degrades to "not drawn".
- **An "指令" tab**, split out of Memory. Persistent instructions (`CLAUDE.md`, `AGENTS.md` with
  `AGENTS.override.md` precedence, `GEMINI.md`, `QWEN.md`, `.cursor/rules/*.mdc`, Hermes `SOUL.md`) get
  their own page, count, and global-vs-project breakdown; Memory now counts only what agents wrote
  themselves. Locally that's 105 memories vs 19 instruction files — one number for both was
  meaningless. Creation entries follow their page: Codex/Kimi/Gemini's fixed-name instruction files
  moved to the new tab, per-CLI memory creation stayed on Memory.
- **Memory library index drift.** `MEMORY.md` is what an agent reads to decide what to load, so a
  memory file the index doesn't list is effectively dead — locally 2 of 72 in one library. Libraries now
  report both directions (unlisted files, and index entries pointing at nothing) on the library row, in
  a banner with a "show only unlisted" filter, and as dashed nodes in the graph.
- **Codex memories now link to their sessions too.** Codex has no frontmatter; its `MEMORY.md` records
  provenance in a `### rollout_summary_files` section, one `thread_id=` per line (15 locally, **15/15
  still resolvable** — compare Claude's 37/84). Memory entries carry a list of session refs now, so the
  row action and detail toolbar offer a single jump or a dropdown. `cwd=` is deliberately *not* used for
  project attribution: one entry points at a sandbox working directory, not a repo root.
- **A cross-source consistency card** on the audit page — the thing a "local agent CLI manager" should
  do and nothing else does: reconcile 12 CLIs' instruction files, skill distribution, and memory index
  health. Every threshold is *adaptive* (it checks conventions you already use, rather than an ideal
  checklist) because the real risk here is noise, not wrong math: instruction gaps only count files you
  use in ≥2 repos, and only for repos that actually have a memory library (`ProjectResolver` reports
  sandbox working directories as repo roots — 5 of 17 locally); skill gaps are aggregated per source and
  only reported when a skill is missing from exactly one comparable source. Locally that's 5 findings
  instead of 18. `ConsistencyChecker` lives in `EurekaIngest` as a pure function so those thresholds are
  pinned by tests.
- `--render-knowledge` now also renders the library page, the graph (light + dark), a memory detail
  page with its relation graph, and the instructions page; `--render-shell` renders the consistency card.

### Removed

- **The 诊断 (diagnostics) tab and its persistence layer.** Its value depended on someone reading the
  cross-session aggregates and changing their prompting habits; it wasn't earning the cost. Gone:
  `PromptDiagnosticsView` / `PromptDiagnosticsService`, `TurnMetricsIndexer`, `TurnMetricsRepo`, the
  `turn_metrics` / `turn_files` tables (dropped by schema v19), and `--diagnostics-snapshot` — about
  830 lines plus tests. The sidebar is back to 11 items.
- **The turn lineage graph stays**, reachable from the session page header. It computes on demand from
  `TurnSlicer.slice(transcript)` and never touched `turn_metrics`, so dropping the tables costs it
  nothing; `TurnDiagnostics` is kept because the graph's header strip shows its re-read / retry /
  rework counts. What's gone is only the cross-session aggregation and its persistent index —
  which is also what made this the cheaper half to remove.

### Fixed

- **A 72-second scan ran every 60 seconds.** `AgentSessionDiscovery.forIndexing()` measured **72.8s**
  and the usage timer called it on every tick, so the background queue was never idle — the app
  averaged **29.5% CPU** over an 11-hour run. Of those 72 seconds, **Codex alone accounted for 65**
  (121 sessions); Claude's 94 sessions took 0.41s. Three fixes, verified end to end:
  `AgentSessionDiscovery.forIndexing()` **72.8s → 1.9s**, `ProjectRoots.recentCwds()` **58.3s → 3.5s**.
  - **`CodexSessionIndexer.headInfo` read entire files.** Its stop condition required *both* an id and
    a name, but the name comes from the first `event_msg/user_message` — and sessions without any user
    message (subagent / automated / post-compact runs: **29 of 121** locally) never satisfied it, so it
    JSON-parsed every line of files up to **70 MB**. Now it reads a bounded head (64 KB probe, 1 MB
    cap), byte-scans for the two markers before paying for `JSONSerialization`, and walks lines with a
    cursor instead of `split`. Session names are byte-identical before and after.
  - **The same discovery ran four times during launch warm-up** (`SkillMemoryService` alone called it
    twice). `ProjectScopeDiscovery` now shares one result behind a 60s TTL, invalidated on manual refresh.
  - **Full-text indexing no longer shares the usage tick.** Search isn't real-time data and only pays
    the discovery cost again; it runs every 5 minutes while usage, limits, and history stay at 60s.
    (Per-turn indexing used to ride here too — it's gone entirely, see Removed.)
- **Codex session ids were silently wrong for 30 sessions.** Because `headInfo` scanned to end of file,
  a second `session_meta` — written when a rollout is resumed or forked, present in every file over
  5 MB locally — **overwrote the id with another session's**. 121 rollout files yielded only 91 unique
  ids, so those sessions collided in the session list and in `fts_docs`. Only the first `session_meta`
  counts now, and schema v18 forces a re-index (fingerprints alone wouldn't).
- Two per-frame hot paths: `sourcesByCount` called a full-table filter inside its sort comparator
  (~10k array walks per frame), and the memory graph re-ran layout for 126 nodes inside `GeometryReader`.
  Both are precomputed/cached now.

- **Codex "memory" counted 20 files where only 3 are memories.** `~/.codex/memories` is a git repo
  Codex maintains itself, and it mixes four unrelated things; the scan recursed through all of it. Only
  the three top-level files are memories (`raw_memories.md` → `MEMORY.md` → `memory_summary.md`, a
  pipeline). The rest were miscounted: 14 `rollout_summaries/*.md` are per-session summaries cited by
  `MEMORY.md`, `extensions/ad_hoc/instructions.md` is meta-instruction telling Codex how to maintain
  its own memory, and `skills/publish-draft-pr/SKILL.md` **is a skill** — it now shows up under Skills,
  where it belongs. Codex has **no per-project memory** at all: project attribution lives inside the
  content (`applies_to: cwd=…`), not in directories.
- **Hermes' three files were all filed as instructions.** `memories/MEMORY.md` and `memories/USER.md`
  are written *by the agent* (memories); only `SOUL.md` — its persona — is an instruction.
- **Sidebar dropped the "系统 / 设置" group at minimum window height** once a 12th tab existed. Row and
  group-label spacing each lost 1pt so everything fits the ~512pt content area again (the outer
  `ScrollView` was already a backstop, but the settings entry should not require scrolling to find).
  Removing the diagnostics tab later brought the count back to 11, leaving headroom.

- **Memory page counted the wrong thing.** Claude's real memories —
  `~/.claude/projects/<encoded>/memory/*.md`, agent-written, one `MEMORY.md` index plus one file per
  fact — were indexed and then dropped by a filter in `SkillMemoryService.rebuild()`, so the page
  total, source chips, scope breakdown, and size all excluded them (97 of 141 files on the author's
  machine). Nothing is discarded now: standalone files stay in the list, library entries fold into one
  row per library, and every statistic reads one shared set.
- **Project names were being reverse-engineered out of a lossy encoding.** Claude turns `/`, `.` *and*
  `_` into `-` when naming a project directory, so splitting on `-` gave `layer` for
  `aftership-semantic-layer`. Names now come from encoding each known repo root *forward* and matching,
  with a transcript-head `cwd` lookup as fallback.
- **Memory rows showed the project name as their title**, which made every entry in a library
  identically named. Titles come from frontmatter `name` (or the filename) now, with the project as a
  chip; the row's second line prefers `description` over the path.

## [0.16.0] - 2026-07-28

### Added

- **Turn lineage graph** — a real DAG of what an agent did in one turn: the
  prompt, its thinking, every tool call, spawned subagents, and the answer, with
  edges for causality *and* for the loops that matter. Nodes are deduplicated by
  operation identity (kind + tool + canonical target), so reading the same file
  eight times is one node badged `×8` rather than eight nodes — and the loops
  fall out of that for free: `Edit → build fails → Edit` becomes a genuine cycle
  instead of a synthesized edge. Back edges get their own lanes, data re-reads on
  the left and retries/rework on the right, so "context wasn't given up front"
  and "the change broke something" are distinguishable at a glance. Reachable
  from the session page header ("轮次血缘"), which also lists every turn with its
  step/re-read/retry counts. The layout engine lives in `EurekaKit` as pure
  functions (following `IslandGeometry`) and is covered by invariants —
  most valuably that **no edge segment ever crosses a node**, which holds by
  construction: horizontal runs only ever travel the mid-line of an inter-layer
  gutter, and edges spanning more than one layer reserve a column via dummies.
- **Prompt diagnostics tab** — cross-session answer to "which habits cost me the
  most, and am I improving". Ranks the rules actually hit (same rule table the
  per-turn view uses), each with the concrete prompt change it implies, plus a
  daily trend and a list of the worst turns that link straight to their graph.
  On the author's machine: 1979 turns across six CLIs, most common being
  "edited the same file repeatedly" (163 turns) and "asked you to clarify" (147).
- **Plaintext thinking for Codex, Kimi and Qwen** — the code previously asserted
  thinking was never available locally. That is true only for Claude, which
  strips the body and keeps an encrypted signature. Codex's plaintext lives on
  `event_msg/agent_reasoning` (the encrypted one is `response_item/reasoning`),
  Kimi's on `part.type == "think"`, Qwen's on `{text, thought: true}`. All three
  now render as collapsible thinking blocks in the session view and as thinking
  nodes in the graph; Claude's graph shows a dashed fork node instead and says
  why, rather than implying the model didn't think.
- **CLI**: `--render-lineage` (golden + live lineage renders) and
  `--diagnostics-snapshot` (scan and dump per-turn prompt-quality metrics).

### Fixed

- **Codex's main command channel was never parsed.** `custom_tool_call` carries
  `exec` and `apply_patch` today (1334 + 97 occurrences across the twelve largest
  local rollouts) and had no branch in either the transcript reader or the audit
  scanner — meaning session trails were incomplete *and the security audit was
  under-reporting Codex commands*. Its `input` is not JSON but JavaScript source
  (`await tools.exec_command({cmd: "…"})`) or raw patch text, in seven observed
  shapes; all now resolve, with a 3.8% fallthrough that is genuinely not a tool
  invocation. Note that historical rows are **not** backfilled: the watermark has
  already advanced past those files, so only new lines are captured.
- **Tool outcome detection for Codex.** `function_call_output.metadata.exit_code`
  no longer exists in current versions (0 of 2624 occurrences), so failures went
  unrecorded. Both formats are now recognised — old rollouts still on disk keep
  working — and an indeterminate result stays indeterminate instead of being
  reported as success.
- **An empty discovery result no longer wipes the index.** `prune(keeping:)` was
  called unconditionally, so a single empty session-discovery pass (transient IO
  error, unreadable root) deleted every row and forced a full re-scan. Observed
  destroying 1979 rows of turn metrics; the same flaw affected the full-text
  search index.
- **Session discovery ran twice per scan tick.** Discovery is the dominant cost
  (~60s for 267 sessions, since each file head is parsed), and the full-text and
  turn-metric indexers each ran their own pass. They now share one result.
- Slash-command echoes (`<command-name>`, `<local-command-stdout>`) and
  background task notifications are no longer counted as user prompts — half of
  the string-content user messages on the author's machine (240 of 483) are
  injected, which previously produced a turn list full of empty zero-step turns.
  Injected blocks are stripped rather than dropping the whole message, because a
  real prompt often follows them.

### Changed

- Schema v17 adds `turn_metrics` + `turn_files` (derived tables, rebuilt on
  upgrade). Only metrics are persisted — the graph itself is computed on open in
  under a millisecond, while cross-session aggregation would otherwise re-read
  ~2 GB on every page visit. First full index takes ~130s; afterwards a
  size+mtime fingerprint skips 263 of 267 files.
- The sidebar's navigation list scrolls. `hosting.sizingOptions = []` clips
  rather than grows the window, and `window.minSize` 540 is frame height (~512 of
  content), which left barely a dozen points of slack before the brand footer
  would have been cut off.

## [0.15.0] - 2026-07-27

### Added

- **Codex hooks integration** — `~/.codex/hooks.json` exposes four events
  (`UserPromptSubmit` / `Stop` / `SessionStart` / `PermissionRequest`), and the
  file has the same shape as Claude's `settings.json`, so the existing
  deep-merge installer applies. `PermissionRequest` is the point of it: Codex
  rollouts never recorded approval events, so "waiting for approval" was
  invisible for Codex until now. Installing also gives Codex *exact* terminal
  attribution, since relay envelopes carry the terminal. The merge only ever
  adds or removes entries carrying our own marker — verified against a real
  `hooks.json` already occupied by another app, including that uninstall
  restores the file byte-for-byte.
- **Tool-call audit for Grok and Qwen** — Grok's arguments live on
  `chat_history.jsonl`'s `assistant.tool_calls` (its `events.jsonl`
  `tool_started` lines carry only a tool name, which would produce audit rows
  with no detail and no risk-rule coverage). Qwen's are structured
  `functionCall.args`. Both vocabularies overlap Cursor's snake_case set, so
  the extractor is shared. Verified on real data: 1244 Grok rows and 28 Qwen
  rows, of which only 9 lack a detail string.
- **CodeBuddy and Qoder skills are indexed** — `~/.codebuddy/skills` holds 23
  real skills on the author's machine; the code previously asserted these two
  CLIs had no user-level skills directory and skipped them entirely. Project
  scoped roots (`<repo>/.codebuddy/skills`, `<repo>/.qoder/skills`) and the
  create-skill menu entries come with it. Qoder is unverified locally (not
  installed) and is noted as such in code.
- **Prompt counts for opencode, Hermes and Cursor** — the session list showed
  no conversation count for the three shared-database sources. Counted from
  `message.role`, `messages.role` and bubble type respectively, as absolute
  values so they cannot drift with the usage watermark.
- **Backup coverage for the last gaps** — `gemini/plans` and `qwen/plans` were
  being materialized and indexed but never backed up; Antigravity had no
  backup roots at all. Cursor's subagent definitions are included too.
- **Cursor subagent creation** — the indexer and list were wired in 0.14.0 but
  the create button was missing.
- **OpenCode memory creation** — the service already supported it and the
  index already read it; only the menu entry was absent.

### Changed

- **Backup page: composition is now two-level and no longer clipped** — it was
  a single-line horizontal scroller of twelve 9.5pt capsules, which overflows
  at the minimum window width with no visible indicator, and it only ever
  showed per-source totals, so it could not answer "which data does each CLI
  sync". `sync_state` gained a `category` column (idempotent migration), and
  legacy rows are decomposed from their remote key — safely, since a key with
  exactly four segments ends in a filename rather than a category. Real data
  now yields 27 buckets across 11 sources. The UI reuses the overview card and
  collapsible source headers the Skills/Memory/Plans/Agents pages already use.
- **Backup page: sync history is now a table** — added column headers and fixed
  column widths so fields line up across rows, a per-run source-composition
  bar so a run's contents are visible without expanding, grouping by the
  *full* category (`claude/skills`, not `claude`) with per-group collapse and a
  30-file cap instead of flattening up to 500, `LazyVStack`, a "N runs total"
  label, and theme tokens in place of raw greens and oranges.

### Fixed

- **Antigravity skills were written into Gemini's directory** —
  `AntigravityPaths.userSkillsRoot()` returned `~/.gemini/skills`, which is
  Gemini's. Antigravity's own root is `~/.gemini/antigravity/skills` (23 skills
  locally, a separate directory with separate inodes). Combined with the
  indexer being handed an empty root list, a skill created as "Antigravity"
  landed in Gemini's directory and then reappeared tagged gemini. The two are
  now fully disjoint (verified: zero path overlap).
- **Antigravity memory creation wrote into Gemini's directory too** — there is
  no Antigravity memory directory at all, so the entry point is gone rather
  than borrowing someone else's.
- **Backups over 1 GB displayed as megabytes** — the view used a formatter that
  stops at MB while the summary line used one with GB, so a 2.7 GB backup read
  as "2678.7 MB". Unified on the GB-aware formatter.
- **Sync history jumped back to page 1** after every cycle while the view still
  believed it was on the page the user had picked.
- Grok's MCP calls were classified as "other" instead of "mcp", and its
  `use_tool` bridge produced empty details because `tool_input` is an object
  rather than a string (all 40 rows). Empty-detail rows dropped from 47 to 9.

## [0.14.0] - 2026-07-27

### Added

- **Cursor is the twelfth supported agent** — live island cards, history,
  session browsing, ctx%, tool activity, subagents, tool-call audit,
  usage tokens, plans and `~/.cursor/skills` indexing. Cursor is an IDE with no
  hooks and no transcript files: everything lives in one SQLite database
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`),
  read read-only (WAL-aware, never `immutable=1`) and polled every 2s.
  Working directories resolve through `workspaceStorage/<id>/workspace.json`.
- **Cursor usage: tokens counted, cost always $0** — Cursor stores only
  `{inputTokens, outputTokens}` per turn with no cache split, and
  `inputTokens` is the entire re-sent context. The scanner attributes it
  by adjacent difference (same approach as the Codex scanner), so fresh
  input per session sums to the final context size rather than ~5x it
  (verified on this machine: 7.1M fresh + 26.3M cache = 33.4M raw). Every
  `cursor/*` model is marked `unknown` in the price table because Cursor
  bills per request on a subscription and reports `default` as the model
  for many turns.
- **Second live channel for Cursor: `agent-transcripts`** — Cursor 3.13.10
  also writes a Claude-style JSONL per turn under
  `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`, with an
  explicit `turn_ended` marker and Claude-vocabulary tool names (`Read` /
  `Glob` / `Grep` / `Shell`, not the DB's `read_file` / `glob_file_search`).
  It carries no tokens, ctx%, todos or subagents, so it supplements the
  database rather than replacing it — the transcript only covers turns after
  the feature shipped, with zero historical coverage.
  Lifecycle ownership is pinned **at turn start**: if a transcript exists
  then, it owns the whole turn (explicit `turn_ended`, no close debounce
  needed) and the DB poller yields; otherwise the DB owns start *and*
  finish. Re-deciding mid-turn would strand the card forever — the DB would
  emit the start, then yield the finish to a tailer whose first sight of the
  file is already-closed and therefore silent. Both branches are pinned by
  tests.
- **Cursor's context% is reported, not estimated** — unlike Claude, Cursor
  persists its own `contextUsagePercent`, which the island uses as-is.

### Fixed

- **Crash on launch when a Cursor conversation had no working directory** —
  the transcript tailer wrote `contexts[path]?.cwd = entry.cwd ?? contexts[path]?.cwd`,
  where the left side takes exclusive modify access to the dictionary while
  the right side reads the same key. Swift aborts on that overlapping access
  (`Fatal access conflict detected`). `??` short-circuits whenever the cwd is
  non-nil, so only `empty-window` conversations (Cursor with no folder open)
  reached it — which is exactly why the first round of tests missed it. Now
  read-modify-write, with a regression test that uses a cwd-less conversation.
- **CodeBuddy, Qoder and Cursor brand marks now render** — their SVGs
  declared `width="1em" height="1em"`, which `NSImage` cannot resolve, so
  all three drew as flat gradient squares. They now carry explicit 24×24
  dimensions. Qoder additionally gained a white variant: its mark is
  `currentColor` (i.e. black), which was invisible on the always-dark
  island.

### Notes

- **Cursor plans come from `todos`, not a directory** — Cursor has no
  `plans/` folder (`composer.planMigrationToHomeDirCompleted` is true but
  the target never exists). Its plan lives as the `todos` array inside each
  conversation, written by the `todo_write` tool; those are materialized
  into markdown checklists exactly like Codex's `update_plan` calls
  (verified: 22 of 154 local conversations produce a checklist).
  `cancelled` steps get their own `[-]` box so an abandoned step does not
  read as merely unfinished.
- **Cursor skills, rules and subagents** — user skills
  (`~/.cursor/skills`), Cursor's own bundled set (`~/.cursor/skills-cursor`,
  indexed read-only), project skills (`<repo>/.cursor/skills`), project
  rules (`<repo>/.cursor/rules/*.mdc`, indexed as project-scoped memory —
  Cursor has no global memory file, the server-side feature only leaves a
  toggle on disk) and subagent definitions (`~/.cursor/agents/*.md` and
  `<repo>/.cursor/agents/*.md`). Conventions taken from Cursor's own
  built-in `create-skill` / `create-rule` / `create-subagent` skills.
- Cursor has **no** local rate-limit snapshot (quota is website/IDE only);
  that surface is marked N/A rather than faked. Reading `cursorAuth/*` tokens to call
  the official quota API is deliberately not done.
- Cursor's database is **never** backed up or synced: the same file holds
  `cursorAuth/accessToken`. Only `~/.cursor/skills` is eligible.
- Full-text search and session deletion are skipped for Cursor for the
  same reason as opencode/Hermes — every session shares one database file.

## [0.13.0] - 2026-07-26

### Added

- **Audit trail covers CodeBuddy and Qoder** — incremental transcript
  scanners feed the same risk-flagged tool-call ledger as Claude/Codex,
  including subagent transcripts (attributed to the parent session).
  Audit now covers 4 of 11 agents.
- **Subagent progress on the island for Kimi, CodeBuddy and Qoder** —
  spawned agents (type, task description, running/completed/failed,
  current tool) now surface from all three, reusing the Claude subagent
  model. Qoder reuses the Claude layout scanner; CodeBuddy derives from
  spawn calls in the parent transcript; Kimi gets a cheap snapshot
  (subagent wires are still never tailed).
- **ctx% for Gemini, Qwen and CodeBuddy** — their transcripts already
  carry per-request input/cached tokens; the island now shows context
  usage for them. The built-in context-window table learns
  `gemini-2.5`/`gemini-3` (1M) so Gemini ctx% is no longer overstated
  ~5x against the 200k default.
- **Qwen tool activity on the island** — function-call parts map to
  current-tool events, which also keeps long tool runs alive instead of
  being reaped as interrupted after 4h. (Verified: Gemini's chat jsonl
  does not persist tool calls, so there is nothing to map there.)
- **Project-level discovery from all 11 agents** — project skills,
  memory, agent definitions and plan documents are now discovered for
  repos only ever used with Kimi/Gemini/Qwen/Grok/CodeBuddy/Qoder/
  Antigravity, not just Claude/Codex/opencode/Hermes checkouts.

## [0.12.0] - 2026-07-26

### Added

- **Session list: time-range picker replaces the hidden count cap** — the
  session browser no longer truncates to 10 entries. It shows every
  session in the selected range — 近 30 天 (default) or 全部时间 — via
  capsule tabs matching the sort control (choice persists). Previously
  the truncation lived behind an unlabeled icon, so less-recently-active
  agents' sessions looked like scanning bugs.

### Fixed

- **Codex resumed sessions were invisible.** Rollout files live in
  `YYYY/MM/DD` directories by creation date, and resuming an old session
  appends in place — so old-created/recently-active sessions were missed
  by live island monitoring, the session browser, the usage ledger, the
  audit trail and the rate-limit gauge alike. All five now enumerate
  every date directory and select by mtime.

## [0.11.0] - 2026-07-25

### Added

- **CodeBuddy and Qoder support** — the island, session browser,
  transcript viewer/search, plans, memory and cloud backup now cover
  Tencent CodeBuddy (`~/.codebuddy`) and Alibaba Qoder CN (`~/.qoder-cn`),
  bringing the app to eleven monitored agents. CodeBuddy sessions also
  feed the usage ledger (tokens ride on its transcript `function_call`
  lines); Qoder's CN backend reports zero tokens, so it is intentionally
  excluded from the usage dashboard. Resume jumps via
  `codebuddy --resume` / `qoderclicn --resume`.
- **Optional system notifications for key events** — a new
  关键事件发送系统通知 toggle (off by default) mirrors
  task-finished / waiting-for-input / task-error island cards to macOS
  notifications, so they are visible over fullscreen terminals and on
  other Spaces. Respects the existing per-type island toggles.

### Fixed

- Usage dashboard source-filter chips no longer get clipped at the
  minimum window width — they wrap to a second row.

### Performance

- Codex session index is only re-parsed when the file actually changes
  (was: fully re-read every second).
- All polling timers now declare a leeway so macOS can coalesce wakeups
  (battery); Gemini/Qwen/CodeBuddy/Qoder tailers no longer read whole
  transcripts on first sight — a 64KB head + 256KB tail window is enough
  to restore context and last state.
- Gemini session indexer applies its recency window before reading
  files instead of after.

## [0.10.0] - 2026-07-25

### Added

- **Sessions now remember which terminal they ran in.** The session list,
  history and the island task list show it, and each offers a one-click
  jump that brings that terminal application to the front. A session that
  moves — resumed in a different terminal — keeps both bindings, and its
  detail page lists every terminal it has run in.
- **Two ways of finding that out, so it works without hooks.** With an
  integration installed, the relay reads it out of the environment it
  inherits: a hook is a child of the CLI, which is a child of the
  terminal. Without one, the app matches a running agent process by
  working directory and follows the parent chain to the hosting
  application. The second path is approximate and drawn with a dashed
  border to say so; when two sessions of the same agent share a working
  directory it declines to guess.
- **Settings → 集成:** every integration now has its own switch instead of
  one install-everything button. Each states the file it will rewrite,
  that a timestamped backup comes first, and that only its own entries are
  ever touched. Configuration problems are reported instead of all looking
  like "not installed": a hook path that no longer points at the stable
  relay, a missing relay binary (which silently drops every event), a
  `notify` key already taken by another tool, and a config file that can't
  be parsed. The last three are refused rather than guessed at. Hooks
  belonging to other tools are detected and named, so it's clear they
  aren't being touched.
- **The permission card says what is being requested** — "Bash: rm -rf
  node_modules/" instead of just the session name — and the task list
  shows the object a tool is working on rather than only the tool name.
  Context compaction is now shown as well; it used to look like a stall.
  These come from two newly managed hooks, `PreToolUse` and `PreCompact`.
- **Optional: no completion card while you're looking at that terminal.**
  Off by default. Permission cards are never suppressed.

### Changed

- The install-everything block in Settings → 高级 is gone; hooks are now
  managed per integration on the new Integrations page, and the first-run
  instructions point there.
- Automatic hook updates only ever refresh integrations already installed,
  skip anything that can't be rewritten safely, and say why in Settings.
- Installing the Claude integration now also registers `PreToolUse`, which
  runs before every tool call. Claude waits for its hooks, so this adds a
  few milliseconds to each one.

### Fixed

- A nullable column in the new session-terminal key made every upsert miss
  — `NULL` is not equal to `NULL` in SQLite — so a session running inside
  an IDE, which has neither `TERM_PROGRAM` nor a controlling terminal,
  accumulated a duplicate row per event.
- Reading a session's terminal device no longer goes through
  `ttyname("/dev/tty")`, which only ever reports the generic `/dev/tty`
  and so couldn't tell one terminal from another.

## [0.9.0] - 2026-07-25

### Added

- **Hermes Agent is the ninth supported agent.** Live island cards, session
  browsing, the usage ledger and the knowledge base (skills / memory / plans)
  all cover Hermes, with its own brand mark, and it appears automatically in
  every source filter.
- **Live cards for Hermes without installing anything.** Hermes' shell hooks run
  synchronously on the agent's own loop and need interactive consent, so instead
  the app polls `~/.hermes/state.db` read-only every 5 seconds: top-level,
  non-archived sessions started within the last 24 hours. Start, heartbeat and
  finish cards are derived from the session counters, and `end_reason` is mapped
  to completed / errored / interrupted. A session that stops progressing for 5
  minutes is closed as idle, because Hermes only writes `ended_at` on a clean
  exit. The first scan of each database records a watermark only, so launching
  the app never replays history as a wall of cards — a session that was already
  running still surfaces on its next progress tick.
- **Hermes sessions in the session browser.** A 30-day window merged across the
  default home and every `~/.hermes/profiles/*` home. Transcripts render straight
  from the `messages` table, and each row offers a copyable resume command.
- **Hermes usage in the ledger.** Input / output / cache-read / cache-write
  tokens come from `session_model_usage`. Because Hermes accumulates those rows
  in place, a per-session snapshot is kept so re-scans only ever record the
  delta; `reasoning_tokens` is excluded as a subset of output. Auxiliary models
  get their own rows, and gateway sessions that update only the `sessions` row
  have their tokens back-filled as a residual instead of disappearing. A new
  "用量扫描 Hermes" entry appears on the data-health dashboard.
- **Hermes skills, memory and plans.** `~/.hermes/skills` is scanned recursively
  so category, sub-category and un-categorised skills are all found, while
  support directories (`references`, `templates`, …) and Python tooling
  directories are pruned. Memory is the three global files `memories/MEMORY.md`,
  `memories/USER.md` and `SOUL.md`. Plans are indexed directly from
  `<repo>/.hermes/plans` and `~/.hermes/plans` — they are already Markdown, so no
  materialization step is needed.
- **Enable/disable Hermes skills from the app.** Toggling a Hermes skill edits
  `skills.disabled` in `~/.hermes/config.yaml` rather than moving its folder,
  because moving it would break Hermes' bundled-skill checksum accounting. The
  editor works line by line: comments, key order and both inline and block list
  styles survive, it is idempotent, it leaves `platform_disabled` alone, and it
  writes a timestamped `*.bak.eureka.*` backup first. Anything it cannot rewrite
  safely is left untouched rather than guessed at.
- **Cloud backup covers Hermes**: the skills tree, `memories/*.md`, `SOUL.md` and
  `~/.hermes/plans/*.md`. `state.db`, `config.yaml`, `.env` and `auth.json` are
  deliberately excluded.
- **Hermes in Settings**: the CLI tools list detects `hermes` and offers
  `hermes update`, and Settings → Advanced lists the `~/.hermes` path.
- **Knowledge pages are pre-scanned at launch.** Skills/Memory, Agents and Plans
  are scanned in the background shortly after startup, staggered by measured
  cost, so the first visit shows data instead of a spinner. Skill and agent stat
  cards, including this week's hit ranking, are warmed at the same time.
- **A scan-status label** next to the refresh button on Skills, Memory, Agents
  and Plans shows the current phase while scanning and "上次扫描 …" when idle.

### Changed

- **Opening Skills / Memory / Agents / Plans no longer rescans.** Refresh now
  means "scan only if never scanned", and the refresh button is an explicit
  force-rescan. Plans' old 30-second throttle is gone. Because nothing watches
  the filesystem, items added outside the app appear after a manual refresh.
- `eureka --usage-snapshot` now really is a full scan — it was missing the
  Gemini, Qwen and Hermes scanners, so their rows only landed in the ledger if
  the GUI happened to scan them first.
- The Limits panel names Hermes among the agents with no local rate-limit data.
- Source logos can be bitmaps: Hermes ships a PNG, everything else stays SVG.

### Fixed

- Sessions that live in a shared database (opencode and now Hermes) no longer
  offer a delete control that silently deletes nothing — the checkbox and delete
  button are disabled with an explanatory tooltip, and the session detail pane
  stops showing the shared database file as if it were that session's transcript.

## [0.8.0] - 2026-07-25

### Added

- **Plans now show real progress.** Plan bodies are parsed for checklist
  markers, so every plan carries step counts, a completion percentage and a
  derived status (完成 / 进行中 / 草稿 / 文档). The Plans overview card breaks the
  whole library down by status, and list rows show a progress bar with 步数.
- **Agents gain roles, models and call counts.** Each subagent is classified
  into one of seven roles (通用 / 探索 / 实现 / 审查 / 规划 / 建模 / 文档) shown as a
  glyph tile plus tag, its model string is normalized to a display label
  (Opus / Sonnet / Haiku / GPT-5-Codex / 继承 …), and Claude/Kimi subagent
  invocation counts are surfaced from the existing `tool_calls` rows via a new
  read-only query.
- **Memory lists project instruction files.** Per-project `CLAUDE.md`,
  `AGENTS.md` and `GEMINI.md` now appear next to the global ones, tagged 全局 or
  项目 with the owning project.
- `eureka --render-knowledge [dir]` renders every knowledge page (list and
  icon, light and dark) offscreen for visual review.

### Changed

- **Plans / Skills / Memory / Agents rebuilt around one layout.** Each page is
  now an overview card with a big count and distribution, a row of source
  filter chips, and a flat 列表 / 图标 pair — replacing the old stat-tile row and
  per-source collapsible sections. Skills rows carry usage bars and 命中次数,
  Memory rows a 全局/项目 scope badge.
- **The search field is far less timid:** capsule shape, brand-gradient
  magnifier tile, tinted fill that deepens on hover, a purple-gold focus ring
  with a glow, an indigo caret, and a live hit-count pill with a round clear
  button while searching. It no longer stretches across the whole header.
- All four pages share one leading tile — same rounded square, brand tint and
  hairline border — so Plans' progress ring and Agents' role-coloured squares
  no longer read as separate design languages. Plan cards state what a plan is
  rather than how far along it is; completion stays in the list view.
- Sidebar knowledge icons are monochrome grey; the selected indigo capsule
  carries the emphasis.

### Fixed

- **Home is no longer indexed as a project.** `ProjectResolver` stops its
  upward `.git` search at the home directory but previously fell back to
  returning the cwd, so any session run in `~` turned home into a project root.
  That rescanned `~/.claude/skills`, `~/.codex/skills`, `~/.gemini/skills` and
  `~/.grok/skills` as "project level", double-counting every system skill (188
  listed instead of 107), tagging global skills with the home directory name,
  and — because entries are identified by path — leaving empty cells in the
  icon grid where duplicate ids collided. Skills, memory and agent indexing now
  also dedupe by path, so overlapping roots can never duplicate again.
- **Plans no longer fall back to a meaningless title.** Codex sessions with no
  thread name and no usable first user message were all listed as
  「Codex 计划」(45 of 110 locally) despite carrying descriptive first steps;
  those steps are now used as the title. Overly long titles are cut at the
  nearest sentence or clause boundary instead of hard-truncating mid-word.

## [0.7.0] - 2026-07-24

### Added

- **Richer Lulu and Lumei companion animations.** The built-in mascot now ships
  with a dual-character v2 atlas containing nine animation families and 16
  clockwise look directions. While idle, both characters naturally follow the
  pointer; returning movement wakes them, and clicks trigger playful reactions.
- Five additional transparent scene stickers cover running in, bouncing back,
  waking up, resting and sleeping.

### Changed

- **High-frequency mascot states now have 18 weighted variants:** six each for
  idle, working and waiting. Variants rotate at state-specific intervals, with
  per-variant captions and motion profiles, instead of repeating one fixed
  sticker indefinitely.
- Custom mascot manifests may define multiple `variants` per state with their
  own frames, FPS, caption, motion profile and selection weight. Existing
  single-animation manifests remain compatible.
- Sprite-atlas frames are cached after their first decode so continuous pointer
  tracking does not repeatedly load the full image from disk.

## [0.6.2] - 2026-07-23

### Added

- **Project-scoped skills are now backed up.** Cloud backup previously covered
  only global skills (`~/.claude/skills` etc.); it now also uploads per-project
  skills (`<repo>/.claude/skills`, `.codex/skills`, …) discovered from recent
  sessions, under keys `<host>/<source>/skills/project/<project>/…`. The Skills
  page and the backup engine share one project-discovery path.
- **One-click CLI update.** Each installed tool in Settings → About shows an
  「更新」button — only when a newer version is available — that runs the tool's
  own updater in a visible Terminal (`claude update`, `opencode upgrade`,
  `grok update`, `agy update`, or `npm i -g <pkg>@latest` for the rest). The
  「可更新 / 已就绪」badge now uses a semver comparison and the latest version is
  checked automatically when the page opens.

### Changed

- **Brand logo shown in more places.** A shared purple-gold「Lu」mark now sits in
  the sidebar bottom-left next to the version, and replaces the generic icon on
  the Settings → About app card (the sidebar header reuses it too).
- **Settings sub-tabs are icon-led.** 通用 / 备份 / 审计 / 高级 / 关于 each gain a
  leading icon, matching the rest of the app's navigation.

## [0.6.1] - 2026-07-23

### Added

- **Manual refresh on every management pane.** Skills, Memory, Plans, Agents
  and the Usage dashboard now share one refresh control — a purple icon on a
  light brand-tinted disc — in the toolbar. Skills, Memory and Agents gain a
  manual refresh for the first time (previously they only re-scanned when the
  pane was opened).

### Changed

- Plans' plain gray refresh icon and the Usage dashboard's text button are
  unified to the shared `RefreshButton` so the refresh affordance looks the
  same everywhere; it sits after the layout toggle and before the "新建"
  action as a secondary control.

## [0.6.0] - 2026-07-23

### Added

- **Card / list toggle on every knowledge pane.** Skills, Memory, Plans and
  Agents now switch between a card grid and a full-width list from one control
  in the pane toolbar. The list rows mirror the Sessions row — source logo,
  two-line title/description, a hover-revealed edit / reveal / delete cluster
  and a left accent bar on hover. Plans and Agents gain a list view for the
  first time.
- **Design-token layer** in `Theme`: semantic status colors (enabled /
  disabled / failure / auto-clean), a visible card border, purple-gold and
  chart gradients, a radius scale (card 12 / container 10 / tile 8) and a font
  scale — every pane now pulls the same values instead of hand-rolling them.
- Skill detail shows the current **weekly call rank**.

### Changed

- **Knowledge-pane cards redesigned.** The left purple-gold spine and the
  permanent action toolbar are gone; cards are fewer-per-row and larger (bigger
  source logo, prominent title, up to three description lines), with edit /
  reveal / delete revealed on hover. Group-header counts are a neutral pill,
  and the card/list switch moved out of every group header into the toolbar.
  Shared `KnowledgeCard` / `KnowledgeRow` / `LayoutToggle` / `TagChip` /
  `StatusDot` / `EmptyStateView` / `SearchField` / `SourceSectionHeader` /
  `MarkdownDocumentCard` back all four panes.
- **Sidebar** groups now carry labels (活动 / 知识库 / 用量) with monochrome
  icons, and Settings is pinned to the bottom.
- **History** is a day-grouped timeline (today / earlier) with a per-row source
  badge and colored status circles (green ✓ / red ✕ / gray —).
- Sessions detail uses natural asymmetric chat bubbles; the turn-trail fold
  pill is recolored gold to separate it from the purple accent.

## [0.5.2] - 2026-07-22

### Changed

- **Sessions toolbar redesign.** The search field and source filter fuse into
  one rounded panel with an always-on purple-gold gradient border (brighter
  when focused, with a clear-text button); the source picker is now a custom
  popover — real CLI logos inside and out, per-source session counts, a
  brand-tinted selected row, and it no longer spills past the pane divider
  the way the old system menu did.
- **Colored control icons** in the sidebar-tile style: the sort tabs (active /
  disk / duration / project, renamed from 最近活跃/大小/时长) each get a
  colored icon tile, and the multi-select and refresh buttons become colored
  tile buttons (multi-select lights up with a brand ring when armed).
- The display-limit dropdown and the whole toolbar adopt the same rounded
  capsule language as the rest of the app.

## [0.5.1] - 2026-07-22

### Fixed

- Selecting a CLI in the sessions source dropdown flooded the whole left
  pane with a giant source logo: macOS re-hosts `Menu` label content, and
  shape/resizable-image views escape their frame constraints there. The
  dropdown label now uses text only (brand-tinted when a filter is active).

## [0.5.0] - 2026-07-22

### Changed

- **Unified page design.** Skills, Memory and Agents now share the Plans-style
  interaction language: equal-width stat tiles on top (click a CLI tile to
  filter), card grids per source, and inline detail pages (back bar,
  preview/edit toggle, document-card markdown rendering) replacing every
  modal sheet — including the Codex profile form. Skill and agent cards carry
  a green/grey status square that toggles enablement in place.
- **Skills list and analytics merged into one page.** The list/stats
  segmented tabs are gone; a "Top skills" ranking card (rank, source badge,
  proportion bar, last-active time, call count) sits above the card grid,
  with today / this week / this month / all-time / custom date ranges, and
  clicking a ranking row opens the inline skill detail.
- **Sessions pane redesign.** The left list is flat by default, sorted by
  recent activity, size or duration; a fourth "project" segment restores
  project grouping (expanded by default). Source filtering moved from a
  hidden icon menu to a visible dropdown listing every CLI with its session
  count.
- The usage dashboard gained an **all-time** period alongside
  today / week / month / custom.
- The Memory tab now shows only global and user-created memories;
  project-scoped files (repo-root `CLAUDE.md` / `GEMINI.md` / `QWEN.md`,
  per-project memory dirs) are no longer listed there. Indexing is
  unchanged, so cloud backup still covers them.
- Settings dropped the "usage stats" sub-tab — the top-level Usage module
  already covers it.

### Fixed

- Large blank gaps between rows in the session list: structural
  expand/collapse animation inside the lazy list left ghost space, and
  duplicate session ids could render as empty rows. The flat list removes
  the structure, project grouping no longer animates, and indexing dedupes
  by session id.

## [0.4.0] - 2026-07-21

### Added

- **Qwen Code CLI support** — the eighth agent source, covered across every
  module: session browsing with transcript rendering (thinking parts hidden,
  tool calls shown as notes), a per-request token ledger from the CLI's
  telemetry events (deduped by response id; cached input split out), live
  island tasks, skills / global and per-project memory including repo-root
  `QWEN.md`, cloud backup (which deliberately excludes `settings.json` since
  it holds an API key), full-text search, resume/delete, Qwen model pricing
  and the official logo.
- **Plans for Gemini and Qwen.** Neither CLI persists plan artifacts, so the
  plans tab now heuristically materializes the last assistant message that
  contains three or more task-list items as a read-only working checklist.

### Fixed

- Sessions with blank titles no longer render as empty rows in the session
  list — they fall back to a short session-id label.

## [0.3.0] - 2026-07-21

### Added

- **Gemini CLI support** — the seventh agent source, covered across every
  module: session browsing with transcript rendering and full-text search
  (chat files under `~/.gemini/tmp`, project attribution via
  `projects.json`), a per-message token usage ledger (cached input split out,
  thinking tokens billed as output; duplicate streamed lines and
  resume-rewritten files are deduped), live island tasks via a chat-file
  tailer, skills (`~/.gemini/skills`, now attributed to Gemini rather than
  Antigravity, which shares the same home) and global/per-project `GEMINI.md`
  memory, cloud backup, CLI tool card, and the official Gemini spark logo.
  No local rate-limit or plan-artifact conventions exist, so those two
  modules are intentionally skipped.

## [0.2.3] - 2026-07-21

### Added

- **Plans tab overhaul.** The row list becomes a card grid grouped into peer
  sections — repo-local **project plan documents** (scanned from each
  project's `plans/` and `docs/**/plans/` directories) on top, then each tool
  source. Stat tiles at the top (total count + size, per-category counts)
  double as filters, and clicking a card opens an **inline detail page**
  (back bar, preview/edit for real files, document-card layout) instead of a
  modal sheet.
- **Richer markdown rendering** everywhere the app renders markdown
  (plans, sessions, memory, skills): GFM task lists render as tri-state
  checkboxes (`[ ]` / `[~]` / `[x]`), headings get a real hierarchy with
  hairline underlines, inline code becomes chips, links are tinted and
  underlined.
- **Official source logos.** Claude, Codex (ChatGPT mark), Grok, Kimi and
  Antigravity badges now use the official vector logos across the island and
  every panel, with a white Grok variant for dark contexts. opencode is now
  written **OpenCode** throughout the UI and uses its official mark.

### Changed

- **Plans scanning is now incremental.** Codex rollouts are fingerprinted, so
  a steady-state refresh drops from minutes of full parsing to well under a
  second; the first scan shows a be-patient hint and refreshes are throttled.

## [0.2.2] - 2026-07-21

### Added

- **Weekly vibe-coding report.** A new "weekly" sub-tab in the usage dashboard
  summarizes any week at a glance: active hours, total tokens and estimated
  cost, per-source / model / project rankings, the three priciest sessions,
  task success/error/interrupted counts, a skill leaderboard, and late-night
  coding days. Flip between weeks and export the report as Markdown.

## [0.2.1] - 2026-07-21

### Added

- **Rate-limit exhaustion forecast.** Every limits refresh now records a local
  usage-percent sample; a least-squares fit over the current window's tail
  projects when the window will hit 100%. When that moment is actionable
  (≥50% used, rising, less than 90 minutes away) the island shows a one-time
  warning card per source and window cycle, and the limits panel displays the
  projected fill time next to each gauge. Toggle in general settings
  (default on). Zero network — samples come from the existing local snapshots.

## [0.2.0] - 2026-07-21

### Added

- **Cross-session full-text search.** The sessions tab search box now also
  searches the *content* of every conversation (Claude / Codex / Grok / Kimi):
  message-level hits appear below the session list with snippets, and clicking
  one opens the session and scrolls straight to the message. The index is a
  local SQLite FTS5 trigram index — CJK and English substring queries both
  work — built incrementally alongside the usage scan (a few minutes once,
  then near-zero cost). Advanced settings gain a toggle (default on) and a
  "clear index" button. opencode (shared database) and Antigravity (protobuf)
  transcripts are not indexed.

## [0.1.9] - 2026-07-21

### Changed

- **Richer sidebar, System Settings style.** Every nav entry now has its own
  colored rounded icon tile with neutral labels; entries are grouped
  (activity / knowledge / usage / settings) with inset dividers, topped by a
  header with a mini purple-gold "Lu" logo tile. The limits entry shows a live
  max-usage percent badge colored by the 60/85 thresholds. Selection keeps the
  brand capsule.
- **Bigger default window.** The main window now opens at 75% of the screen's
  visible area (capped at 1440×900) instead of a fixed 900×620. The frame
  autosave key was renamed to discard sizes polluted by the pre-0.1.8 shrink
  bug, so existing installs also get the new roomy default once; manual
  resizes are remembered from then on.

## [0.1.8] - 2026-07-21

### Changed

- **Sidebar navigation.** The eleven top capsule tabs are replaced by a fixed
  left sidebar with nine entries (brand-tinted selection, version footer).
  Backup and audit are no longer top-level tabs: both now live as sections
  inside Settings, and the audit config card moved from General to sit above
  the audit event list.
- **Chat-style session transcript.** User prompts render as right-aligned,
  content-hugging brand-tinted bubbles; assistant replies as plain flowing
  markdown. The persistent role/timestamp row is gone — hovering a message
  reveals a floating chip with the timestamp and a copy button. Markdown body
  scaled up to 13 pt with wider spacing, transcript margins narrowed to sit
  closer to the flanking panes, search hits highlighted in gold, and tool-trail
  rows recolored to the brand accent.
- **Purple-gold app icon.** The app icon is repainted as an indigo gradient
  plate with a gold-gradient "Lu" mark, using the same color values as
  `Theme.brand` / `Theme.gold`, replacing the old teal palette that no longer
  matched the panel theme.

### Fixed

- **Main window no longer opens squeezed.** The SwiftUI hosting controller
  used to drive the freshly opened window down to its minimum size, causing
  overlapping text until the user resized it manually. The window now opens at
  its intended 900×620 (or the saved frame, clamped to the new 840×540 floor).
- Long markdown paragraphs could truncate to a single line with an ellipsis in
  tight layouts; transcript, list, and quote text now always wraps.

## [0.1.7] - 2026-07-21

### Changed

- **Panel theme unified around a single brand accent.** The eleven tabs no longer
  each own a rainbow color; the whole main window now uses one brand indigo
  (auto-brightened in dark mode) with gold as a secondary accent drawn from the
  app icon. Status colors (success/error/threshold), cost blue, and chart source
  colors are unchanged.
- **Neutral surfaces.** Cards and containers moved from 7% tinted fills to a
  neutral `controlBackgroundColor` surface with a 0.5 pt hairline border, so color
  now only appears on data, not on chrome.
- **Codex-inspired spacing and radius scale.** New design tokens in `Theme.swift`:
  module 22 / page 16 / card 16 / row 9 for spacing and 14 / 10 for corner radius,
  applied consistently across all tabs.
- **Shared components.** New `SectionCard`, `CapsuleTabButton` and
  `CapsuleTabTray` in `Styles.swift` replace the per-view card helpers and tab
  bars (settings sections, usage dashboard sub-tabs, main tab bar).
- **Session list selection** now shows a brand-tinted row fill with a 3 pt leading
  indicator bar, Activity Monitor style.

## [0.1.6] - 2026-07-20

### Fixed

- Codex session titles are now named from thread metadata instead of opaque
  ids, resolved across the rollout history.
- Codex plan materialization reworked: plans are extracted per thread with
  stable naming and correct project attribution.
- Codex memory indexing now matches the CLI's actual on-disk conventions
  (global `AGENTS.md` plus per-project files discovered from the project
  scope).
- Expanded test coverage for Codex ingest, plan materialization, and
  skill/memory indexing.

## [0.1.5] - 2026-07-20

### Added

- Sparkle-based signed in-app updates: checks once per installed-app launch,
  explicit approval for download/install, automatic download stays off.
  Disable in Settings → About.

### Fixed

- Release pipeline verifies the EdDSA-signed ZIP and appcast before
  publishing; CI test execution is split from the build, and SwiftPM
  parallelism is capped to fit the runner's memory.

## [0.1.4] - 2026-07-20

### Fixed

- Launch crash affecting Homebrew and manually installed v0.1.3 builds: SwiftPM
  resources are now loaded from the signed macOS `Contents/Resources` layout.
- Packaging: strict code-signing verification plus a packaged-resource runtime
  smoke test.

## [0.1.3] - 2026-07-17

### Added

- Deeper Kimi Code coverage: manage Kimi's global and per-project `AGENTS.md`
  from the Memory tab; the Agents tab lists Kimi's four built-in subagent
  profiles (read-only); the Limits panel explains why opencode / Antigravity /
  Kimi show no gauge.
- Claude plans are editable in-app (preview/edit with atomic save + backup) and
  deletable; other agents' plans are labeled read-only materialized copies.
- Backup: per-source upload breakdown in sync history and a stats composition
  row; configurable per-file retry with exponential backoff; custom sync
  folders uploaded under `<prefix>/<host>/custom/<name>/…`.
- Status-bar right-click shortcut to reset the island position.

### Fixed

- Island position self-heal: a stale custom position saved on a disconnected
  display no longer leaves the island off-screen.
- opencode dead path where `memories/` files could be created but never indexed.

## [0.1.2] - 2026-07-17

### Added

- Full Kimi Code CLI support (6th agent source): sessions browsing and
  transcripts, live island lifecycle from wire-log tailing, per-request token
  records in the usage ledger, skills management and invocation analytics,
  plans indexing, cloud backup inclusion, and `kimi` binary detection.
- New Kimi source badge in Moonshot azure (#1783FF).
- Honors the `KIMI_CODE_HOME` environment variable for relocated data
  directories.

## [0.1.1] - 2026-07-16

### Changed

- App bundle renamed `Eureka.app` → `lulu-lumei-dock.app` (bundle id and data
  directory unchanged; settings and data carry over).

## [0.1.0] - 2026-07-16

### Added

- Initial release: menu-bar Dynamic Island for local AI coding agents with
  live task activity, a ccusage-accurate usage ledger, subscription rate-limit
  gauges, and session / skill / memory / agent management for Claude Code,
  Codex CLI, opencode, Grok, and Antigravity.

[0.17.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.17.0
[0.16.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.16.0
[0.15.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.15.0
[0.14.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.14.0
[0.13.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.13.0
[0.12.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.12.0
[0.11.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.11.0
[0.10.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.10.0
[0.9.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.9.0
[0.8.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.8.0
[0.7.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.7.0
[0.6.2]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.6.2
[0.6.1]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.6.1
[0.6.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.6.0
[0.5.2]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.5.2
[0.5.1]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.5.1
[0.5.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.5.0
[0.4.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.4.0
[0.3.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.3.0
[0.2.3]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.2.3
[0.2.2]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.2.2
[0.2.1]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.2.1
[0.2.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.2.0
[0.1.9]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.9
[0.1.8]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.8
[0.1.7]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.7
[0.1.6]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.6
[0.1.5]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.5
[0.1.4]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.4
[0.1.3]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.3
[0.1.2]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.2
[0.1.1]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.1
[0.1.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.0
