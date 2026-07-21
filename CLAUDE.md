# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Eureka is a macOS menu-bar app that surfaces local **Claude Code** and **Codex CLI**（以及 OpenCode/Grok/Antigravity/Kimi/Gemini）task activity as a "Dynamic Island" overlay, plus a ccusage-accurate usage ledger, subscription rate-limit gauges, and session browsing. Swift 5.10 + SwiftPM; Sparkle 2.9.2 is the only third-party runtime dependency. UI strings and code comments are in Chinese — match that convention.

## Commands

```bash
make build      # swift build (debug)
make test       # swift run eureka-tests  — runs all 300 tests
make run        # swift run eureka — runs the GUI app in dev mode
make demo       # Scripts/demo-island.sh — injects fake events to show every island state
make release    # swift build -c release
make app        # release + Scripts/build-app.sh → dist/lulu-lumei-dock.app (ad-hoc signed)
make install    # app + copy to /Applications/lulu-lumei-dock.app
make clean      # rm -rf .build dist
Scripts/check-usage-against-ccusage.sh   # diff usage totals against ccusage (expect 0.00%)
```

**Running a single test:** there is no test filter. The runner (`Tests/EurekaTestsRunner/main.swift`) calls each suite function sequentially (CLT has no XCTest, so this is a hand-rolled harness). To run a subset, comment out suite calls in `main.swift`. Assertions: `expect`, `expectEqual` (see `Harness.swift`); fixtures load from `Bundle.module` via `fixtureURL`/`fixtureData`.

**CLI / debugging the running app:**
```bash
swift run eureka --hooks-status            # Claude hooks + Codex notify install state
swift run eureka --usage-snapshot          # full scan → today's usage JSON (used by ccusage diff)
swift run eureka --limits-snapshot --claude # rate-limit snapshot (--claude also hits unofficial API)
swift run eureka --render-previews [dir]   # offscreen-render every island state to PNG
swift run eureka-relay inject --event stop --session demo  # inject a test event into the spool
```

## Architecture

Data flows one direction: external agents → relay → spool → app state machine → SQLite + UI projections.

```
Claude Code hooks ──┐                                   ┌─ Dynamic Island NSPanel (compact/expanded)
Codex notify ───────┤→ eureka-relay → events/ spool ────│
                    │   (atomic JSON write)    ↓         ├─ NSStatusItem + NSPopover
Codex rollout tail ─┘                    SpoolConsumer   │   (history / usage / limits / settings)
Claude transcript watch ──────────────→ TaskStore (state machine)
Codex rollout token_count ────────────→ UsageEngine / RateLimitProviders
                                              ↓
                                         SQLite (history / usage / scan state)
```

**Five data sources** feed `TaskStore`, wired together in `Sources/EurekaApp/AppDelegate.swift` (the central composition root): (1) spool consumer for relayed hook/notify events, (2) Codex rollout tailer, (3) Claude transcript watcher, (4) Claude usage scanner, (5) Codex usage scanner. The app works **without hooks installed** — the transcript/rollout watchers are the fallback so sessions opened before hooks were installed are still visible.

### Module dependency graph (SwiftPM targets, strictly one-directional)

`app → {EurekaIngest, EurekaUsage, EurekaInstall} → EurekaStore → EurekaKit`. `eureka-relay` is fully independent (zero deps).

| Target | Role |
|---|---|
| `EurekaKit` | Pure domain layer: `TaskEvent`/`AgentTask` models, `TaskStore` state machine, `IslandState` projection, `IslandGeometry` pure functions. **No IO, no AppKit.** |
| `EurekaStore` | SQLite (system `libsqlite3` + thin wrapper) with three repos: `task_history` / `usage_records` / `scan_state`. |
| `EurekaIngest` | Event ingestion: `SpoolConsumer`, `ClaudeHookDecoder`, `CodexRolloutTailer`, `ClaudeTranscriptWatcher`, `ClaudeErrorSniffer`, dedup. |
| `EurekaUsage` | Two incremental+dedup transcript scanners, `PricingTable`, `RateLimitProvider` protocol + Codex/Claude impls. |
| `EurekaInstall` | `settings.json` deep-merge / `config.toml` line-edit installers, backup, diff preview, install-status detection. Pure text in/out, independently testable. |
| `eureka` (app) | AppKit shell: island `NSPanel`, `NSStatusItem`+popover, settings, `RelaySyncer`, CLI mode. |
| `eureka-relay` | `claude-hook` / `codex-notify` / `inject` subcommands; writes to the spool. |
| `eureka-tests` | Hand-rolled assertion harness. |

### Task state machine (`EurekaKit/TaskStore.swift`)

Key = `source:sessionId`. Phases: `running` / `waiting(permission|idle)` / `idle` / finished. `apply(event)` returns `[TaskStoreEffect]` (`taskFinished` / `taskWaiting` / `activeTasksChanged`); the app layer turns effects into island cards, history writes, and status-bar updates. Claude sessions stay alive across turns (turn end → `idle`, next prompt → `running`); Codex idle sessions are reaped by `reapStaleTasks`. Running tasks with no heartbeat for >4h are reaped as `interrupted` (guards against lost hooks). The store is pure logic — callers own thread confinement (the app runs it on `@MainActor`).

## Critical invariants — do not break these

- **`eureka-relay` hard constraints:** always `exit 0`, stdout absolutely silent (UserPromptSubmit stdout gets injected into the model's context), <50ms, stdin capped at 1MB. It writes to `tmp/` then `rename`s atomically into the spool.
- **Relay stable path:** hooks/notify configs only ever reference `~/Library/Application Support/Eureka/bin/eureka-relay`. The app re-syncs the bundled binary there on launch (by hash) so upgrades don't break the link — never hardcode the app-bundle path into installed configs.
- **Stale-event suppression:** events older than 5 minutes only enter history/usage; they must NOT trigger island animations (`AppDelegate.handle` drops stale heartbeat/waiting/session-start events entirely).
- **Usage dedup is mandatory and persistent:** Claude transcripts duplicate `(requestId, message.id)` rows heavily across files (resume/fork copies old rows into new files). Dedup must persist across files (via `scan_state`), or usage will be inflated.
- **Claude OAuth usage (rate limits) is unofficial, opt-in, default-off.** Any failure returns `nil` → the entire UI block hides. Keychain is read via the `/usr/bin/security` subprocess (avoids ACL re-prompts after ad-hoc re-signing).
- **Dependency scope stays narrow:** Sparkle 2.9.2 is exact-pinned and only linked by the app target. SQLite still uses system `libsqlite3`, so the DB stays `sqlite3`-inspectable.

## Data & config locations

App data lives in `~/Library/Application Support/Eureka/`: `eureka.sqlite` (history/usage/sessions), `events/` (spool), `bin/eureka-relay` (stable path), optional `pricing.json` (override price table) and `context-windows.json` (override per-model context-window size, the denominator for ctx%). Config backups are written as `*.bak.eureka.*` before any hooks/notify edit.

## Further reading

`AGENTS.md` — commit message / PR title / release conventions (all English; read before committing or releasing). `docs/design.md` — full design doc (verified data-source formats for Claude transcript / Codex rollout / hooks, key decisions, milestones). `README.md` — feature tour, interaction cheatsheet, known boundaries.
