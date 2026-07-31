# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Eureka is a macOS menu-bar app that surfaces local **Claude Code** and **Codex CLI**（以及 OpenCode/Grok/Antigravity/Kimi/Gemini/Qwen/Hermes/CodeBuddy/Qoder/Cursor）task activity as a "Dynamic Island" overlay, plus a ccusage-accurate usage ledger, subscription rate-limit gauges, and session browsing. Swift 5.10 + SwiftPM; Sparkle 2.9.2 is the only third-party runtime dependency. UI strings and code comments are in Chinese — match that convention.

## Commands

```bash
make build      # swift build (debug)
make test       # swift run eureka-tests  — runs all 600 tests
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
swift run eureka --render-shell [dir]      # offscreen-render the sidebar + audit page (light/dark)
swift run eureka --render-lineage [dir]    # offscreen-render the turn lineage graph (golden + live)
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

**Fourteen event sources** feed `TaskStore`, wired together in `Sources/EurekaIngest/EventPipeline.swift` and composed in `Sources/EurekaApp/AppDelegate.swift`: (1) spool consumer for relayed hook/notify events, (2) Codex rollout tailer, (3) Claude transcript watcher, then one tailer each for (4) opencode, (5) Grok, (6) Antigravity, (7) Kimi, (8) Gemini, (9) Qwen, (10) Hermes, (11) CodeBuddy, (12) Qoder, (13) Cursor's `state.vscdb` poller and (14) Cursor's `agent-transcripts` tailer. Cursor is the only source with **two** live channels: the DB is the sole source of history / tokens / ctx% / todos / subagents, while the transcript has the explicit `turn_ended` the DB lacks. Ownership of lifecycle events is pinned **at turn start** (`SessionState.ownedByTranscript`) — if a transcript exists then, it owns the whole turn and the DB yields; otherwise the DB owns start *and* finish. Never re-decide mid-turn: the DB would emit the start and then yield the finish to a tailer that baselines the already-closed file silently, leaving the card stuck forever. Usage is separate: **ten** scanners under `Sources/EurekaUsage/` write to the ledger, not to `TaskStore` (Qoder has none — its CN backend reports zero tokens). The app works **without hooks installed** — the transcript/rollout/DB watchers are the fallback so sessions opened before hooks were installed are still visible.

### Module dependency graph (SwiftPM targets, strictly one-directional)

`app → {EurekaIngest, EurekaUsage, EurekaInstall, EurekaSync} → EurekaStore → EurekaKit`. `eureka-relay` is fully independent (zero deps).

| Target | Role |
|---|---|
| `EurekaKit` | Pure domain layer: `TaskEvent`/`AgentTask` models, `TaskStore` state machine, `IslandState` projection, `IslandGeometry` / `TurnGraph{,Layout}` / `MemoryGraph{,Layout}` pure functions. **No IO, no AppKit.** |
| `EurekaStore` | SQLite (system `libsqlite3` + thin wrapper) with three repos: `task_history` / `usage_records` / `scan_state`. |
| `EurekaIngest` | Event ingestion: `SpoolConsumer`, `ClaudeHookDecoder`, `ClaudeTranscriptWatcher`, `ClaudeErrorSniffer`, dedup, plus one tailer + session indexer + `*Paths` trio per non-Claude agent (`CodexRolloutTailer`, `OpencodeSessionTailer`, …, `HermesStateTailer`, `CursorStateTailer`). Also the knowledge-surface scanners: `SkillMemoryIndexer` + `MemoryLibrary` (Claude/Qwen `projects/<encoded>/memory` 记忆库), `ConsistencyChecker`, `AgentDefinitionIndexer`, `PlanMaterializer`. |
| `EurekaUsage` | Ten incremental+dedup usage scanners — file-based ones tail transcripts/rollouts; `Opencode`/`Hermes`/`Cursor` read SQLite instead (Hermes diffs `session_model_usage` against a per-session snapshot; Cursor differences adjacent `tokenCount.inputTokens` because it re-sends the whole context each turn and reports no cache split; all `cursor/*` models are priced `unknown` → tokens counted, cost $0). Antigravity has no usage scanner (conversations are protobuf, no local token accounting). CodeBuddy's usage rides on its `function_call` transcript lines (`providerData.usage`); Qoder is excluded (CN backend reports zero tokens). Plus `PricingTable`, `RateLimitProvider` protocol + Codex/Claude/Grok impls. |
| `EurekaInstall` | `settings.json` deep-merge / `config.toml` line-edit / `config.yaml` list-edit (`HermesConfigEditor`) installers, backup, diff preview, install-status detection. Pure text in/out, **zero deps**, independently testable. |
| `eureka` (app) | AppKit shell: island `NSPanel`, `NSStatusItem`+popover, settings, `RelaySyncer`, CLI mode. |
| `eureka-relay` | `claude-hook` / `codex-notify` / `inject` subcommands; writes to the spool. |
| `eureka-tests` | Hand-rolled assertion harness. |

### Task state machine (`EurekaKit/TaskStore.swift`)

Key = `source:sessionId`. Phases: `running` / `waiting(permission|idle)` / `idle` / finished. `apply(event)` returns `[TaskStoreEffect]` (`taskFinished` / `taskWaiting` / `activeTasksChanged`); the app layer turns effects into island cards, history writes, and status-bar updates. Claude sessions stay alive across turns (turn end → `idle`, next prompt → `running`); Codex idle sessions are reaped by `reapStaleTasks`. Running tasks with no heartbeat for >4h are reaped as `interrupted` (guards against lost hooks). The store is pure logic — callers own thread confinement (the app runs it on `@MainActor`).

## Critical invariants — do not break these

- **`eureka-relay` hard constraints:** always `exit 0`, stdout absolutely silent (UserPromptSubmit stdout gets injected into the model's context, and **PreToolUse stdout is read as a permission decision** — any byte there could allow or block a tool call), <50ms, stdin capped at 1MB. It writes to `tmp/` then `rename`s atomically into the spool. The envelope carries a top-level `terminal` object (env + controlling tty) so the app knows which terminal a session runs in; collecting it must stay syscall-only — never start a subprocess.
- **Relay stable path:** hooks/notify configs only ever reference `~/Library/Application Support/Eureka/bin/eureka-relay`. The app re-syncs the bundled binary there on launch (by hash) so upgrades don't break the link — never hardcode the app-bundle path into installed configs.
- **Stale-event suppression:** events older than 5 minutes only enter history/usage; they must NOT trigger island animations (`AppDelegate.handle` drops stale heartbeat/waiting/session-start events entirely).
- **Usage dedup is mandatory and persistent:** Claude transcripts duplicate `(requestId, message.id)` rows heavily across files (resume/fork copies old rows into new files). Dedup must persist across files (via `scan_state`), or usage will be inflated.
- **Hook installers must never overwrite an event wholesale.** `~/.claude/settings.json` and `~/.codex/hooks.json` share the same shape (`hooks: {Event: [{hooks: [...]}]}`) and both are routinely shared with other apps. Only add/remove entries carrying the `eureka-relay` marker; an unrecognisable shape must abort the write rather than be treated as an empty array.
- **Codex hook stdout is as dangerous as Claude's.** `PermissionRequest` very likely reads stdout as an allow/deny decision, so the relay's silence rule covers `codex-hook` exactly as it covers `claude-hook`.
- **Claude OAuth usage (rate limits) is unofficial, opt-in, default-off.** Any failure returns `nil` → the entire UI block hides. Keychain is read via the `/usr/bin/security` subprocess (avoids ACL re-prompts after ad-hoc re-signing).
- **Cursor's `state.vscdb` must never be backed up or synced.** The same SQLite file that holds every Cursor session also holds `cursorAuth/accessToken` and `cursorAuth/refreshToken` in its `ItemTable`. `SyncSourceCatalog` only ever walks `~/.cursor/skills` for Cursor — never add the database or its parent directory.
- **External agent databases are opened read-only, never with `immutable=1`.** Cursor / opencode / Hermes hold their libraries open in WAL mode; `immutable=1` would silently skip everything not yet checkpointed, so live sessions would look frozen.
- **Never scan a Codex rollout to the end just to find a title.** `CodexSessionIndexer.headInfo` reads a bounded head (`headScanLimit`, 1 MB) because ~24% of rollouts have no `user_message` at all and files reach 70 MB — scanning to EOF cost 65s of a 72s discovery. It also **must take only the first `session_meta`**: resumed/forked rollouts contain a second one, and letting it win assigned another session's id to the file (121 files → 91 unique ids before the fix).
- **Session discovery is expensive and must be shared.** `AgentSessionDiscovery.forIndexing()` feeds both indexers from one call; `ProjectScopeDiscovery` caches `recentCwds` for 60s because four knowledge services ask for it during warm-up. Full-text and per-turn indexing run on a 5-minute cadence (`UsageService.indexInterval`), not the 60s usage tick — they aren't real-time and only re-pay the discovery cost.
- **`~/.codex/memories` is a git repo Codex maintains, and only its three top-level files are memories.** Never recurse it: `rollout_summaries/` are per-session summaries, `extensions/` is meta-instruction, and `skills/` holds a real skill. Codex has **no per-project memory** — attribution lives inside the content (`applies_to: cwd=…`). Memory vs instructions is a hard split app-wide: agent-written = Memory tab, user-written rules (`CLAUDE.md`/`AGENTS.md`/`GEMINI.md`/`QWEN.md`/`.cursor/rules`/Hermes `SOUL.md`) = 指令 tab, and the two never share a count.
- **`~/.claude/projects/<encoded>` directory names are lossy — never reverse them.** Claude replaces `/`, `.` **and** `_` with `-` (verified against all 11 local dirs), so splitting on `-` turns `aftership-semantic-layer` into `layer`. Resolve project names by encoding known repo roots *forward* and matching (`SkillMemoryIndexer.resolveProjectName`), falling back to a transcript-head `cwd`.
- **A memory's `metadata.originSessionId` often points at a session that no longer exists** (84 memories carry one locally, only 37 transcripts survive). `originSessionPath == nil` means "not navigable": grey it out instead of offering a jump into an empty session page.
- **Dependency scope stays narrow:** Sparkle 2.9.2 is exact-pinned and only linked by the app target. SQLite still uses system `libsqlite3`, so the DB stays `sqlite3`-inspectable.

## Data & config locations

Cursor is the one source whose data is not under a dotfile home: sessions/messages/tokens all live in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (with cwd resolved via `User/workspaceStorage/<id>/workspace.json`), while its skills live in `~/.cursor/skills`.

App data lives in `~/Library/Application Support/Eureka/`: `eureka.sqlite` (history/usage/sessions), `events/` (spool), `bin/eureka-relay` (stable path), optional `pricing.json` (override price table) and `context-windows.json` (override per-model context-window size, the denominator for ctx%). Config backups are written as `*.bak.eureka.*` before any hooks/notify edit.

## Further reading

`AGENTS.md` — commit message / PR title / release conventions (all English; read before committing or releasing). `docs/design.md` — full design doc (verified data-source formats for Claude transcript / Codex rollout / hooks, key decisions, milestones). `README.md` — feature tour, interaction cheatsheet, known boundaries.
