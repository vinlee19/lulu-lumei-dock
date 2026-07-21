# Changelog

All notable changes to lulu-lumei-dock are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/).

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
