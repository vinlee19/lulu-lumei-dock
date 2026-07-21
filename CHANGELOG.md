# Changelog

All notable changes to lulu-lumei-dock are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/).

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

- Align Codex titles, plans, and memory semantics with the current CLI behavior.

## [0.1.5] - 2026-07-20

### Added

- Sparkle-based signed in-app updates: checks once per installed-app launch,
  explicit approval for download/install, automatic download stays off.

### Fixed

- Release CI: separate test build and execution, and limit SwiftPM parallelism on
  the release runner to avoid SIGKILL on 7 GB runners.

[0.1.7]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.7
[0.1.6]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.6
[0.1.5]: https://github.com/vinlee19/lulu-lumei-dock/releases/tag/v0.1.5
