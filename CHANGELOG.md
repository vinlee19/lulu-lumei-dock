# Changelog

All notable changes to lulu-lumei-dock are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/).

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
