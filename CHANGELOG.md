# Changelog

All notable changes to lulu-lumei-dock are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/).

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

[0.1.8]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.8
[0.1.7]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.7
[0.1.6]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.6
[0.1.5]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.5
[0.1.4]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.4
[0.1.3]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.3
[0.1.2]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.2
[0.1.1]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.1
[0.1.0]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.0
