# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Eureka is a macOS menu-bar app that surfaces local **Claude Code** and **Codex CLI**（以及 OpenCode/Grok/Antigravity/Kimi/Gemini/Qwen/Hermes/CodeBuddy/Qoder/Cursor/Trae）task activity as a "Dynamic Island" overlay, plus a ccusage-accurate usage ledger, subscription rate-limit gauges, and session browsing. Swift 5.10 + SwiftPM; Sparkle 2.9.2 is the only third-party runtime dependency. UI strings and code comments are in Chinese — match that convention.

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
swift run eureka --mcp-inspect <name>      # probe one MCP server (remote handshake / stdio deep-inspect), writes the real tool cache
swift run eureka --render-previews [dir]   # offscreen-render every island state to PNG
swift run eureka --render-shell [dir] [--style brutal]  # offscreen-render the sidebar + audit page (light/dark, both styles)
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

**Fifteen event sources** feed `TaskStore`, wired together in `Sources/EurekaIngest/EventPipeline.swift` and composed in `Sources/EurekaApp/AppDelegate.swift`: (1) spool consumer for relayed hook/notify events (four channels: `claude-hook` / `codex-hook` / `codex-notify` / `trae-hook`), (2) Codex rollout tailer, (3) Claude transcript watcher, then one tailer each for (4) opencode, (5) Grok, (6) Antigravity, (7) Kimi, (8) Gemini, (9) Qwen, (10) Hermes, (11) CodeBuddy, (12) Qoder, (13) Cursor's `state.vscdb` poller, (14) Cursor's `agent-transcripts` tailer and (15) ZCode's `cli/rollout` model-IO tailer. Cursor is the only source with **two** live channels: the DB is the sole source of history / tokens / ctx% / todos / subagents, while the transcript has the explicit `turn_ended` the DB lacks. Ownership of lifecycle events is pinned **at turn start** (`SessionState.ownedByTranscript`) — if a transcript exists then, it owns the whole turn and the DB yields; otherwise the DB owns start *and* finish. Never re-decide mid-turn: the DB would emit the start and then yield the finish to a tailer that baselines the already-closed file silently, leaving the card stuck forever. Usage is separate: **eleven** scanners under `Sources/EurekaUsage/` write to the ledger, not to `TaskStore` (Qoder has none — its CN backend reports zero tokens; Trae has none either — see below). The app works **without hooks installed** — the transcript/rollout/DB watchers are the fallback so sessions opened before hooks were installed are still visible. **Trae is the one exception**: its session DB is encrypted and there is no plaintext transcript anywhere, so hooks are its *only* live channel — without them Trae appears in the knowledge surfaces and the session browser but never on the island. Trae adds no tailer: its hooks are Claude-compatible, so it rides the spool consumer and `ClaudeHookDecoder` with `source: .trae`.

### Module dependency graph (SwiftPM targets, strictly one-directional)

`app → {EurekaIngest, EurekaUsage, EurekaInstall, EurekaSync} → EurekaStore → EurekaKit`. `eureka-relay` is fully independent (zero deps).

| Target | Role |
|---|---|
| `EurekaKit` | Pure domain layer: `TaskEvent`/`AgentTask` models, `TaskStore` state machine, `IslandState` projection, `IslandGeometry` / `TurnGraph{,Layout}` / `MemoryGraph{,Layout}` pure functions. **No IO, no AppKit.** |
| `EurekaStore` | SQLite (system `libsqlite3` + thin wrapper) with three repos: `task_history` / `usage_records` / `scan_state`. |
| `EurekaIngest` | Event ingestion: `SpoolConsumer`, `ClaudeHookDecoder`, `ClaudeTranscriptWatcher`, `ClaudeErrorSniffer`, dedup, plus one tailer + session indexer + `*Paths` trio per non-Claude agent (`CodexRolloutTailer`, `OpencodeSessionTailer`, …, `HermesStateTailer`, `CursorStateTailer`). Also the knowledge-surface scanners: `SkillMemoryIndexer` + `MemoryLibrary` (Claude/Qwen `projects/<encoded>/memory` 记忆库), `ConsistencyChecker`, `AgentDefinitionIndexer`, `PlanMaterializer`. Trae is the odd one out: **no tailer** (its hooks reuse `ClaudeHookDecoder`) and its `TraeSessionIndexer` reads the plaintext memory library instead of a transcript. |
| `EurekaUsage` | Ten incremental+dedup usage scanners — file-based ones tail transcripts/rollouts; `Opencode`/`Hermes`/`Cursor` read SQLite instead (Hermes diffs `session_model_usage` against a per-session snapshot; Cursor differences adjacent `tokenCount.inputTokens` because it re-sends the whole context each turn and reports no cache split; all `cursor/*` models are priced `unknown` → tokens counted, cost $0). Antigravity has no usage scanner (conversations are protobuf, no local token accounting). CodeBuddy's usage rides on its `function_call` transcript lines (`providerData.usage`); Qoder is excluded (CN backend reports zero tokens), and so is Trae (session DB is SQLCipher-encrypted → no local token accounting at all). Plus `PricingTable`, `RateLimitProvider` protocol + Codex/Claude/Grok impls. |
| `EurekaInstall` | `settings.json` deep-merge / standalone `hooks.json` merge (`CodexHooksInstaller`, `TraeHooksInstaller`) / `config.toml` line-edit / `config.yaml` list-edit (`HermesConfigEditor`) installers, backup, diff preview, install-status detection. Pure text in/out, **zero deps**, independently testable. |
| `eureka` (app) | AppKit shell: island `NSPanel`, `NSStatusItem`+popover, settings, `RelaySyncer`, CLI mode. |
| `eureka-relay` | `claude-hook` / `codex-hook` / `trae-hook` / `codex-notify` / `inject` subcommands; writes to the spool. |
| `eureka-tests` | Hand-rolled assertion harness. |

### UI theming (selectable styles)

The main-window UI has selectable styles, switched in 设置 → 通用 → 界面风格 (persisted as `AppSettings.themeStyle`, decoded via `ThemeStyle.resolve` — the 0.20.x releases persisted the id `"raft"`, which resolve still maps to `brutal`). Two kinds:

- **`classic`** (default, indigo+gold) and **`brutal`** (shown as **Neo-Brutalism**; cream `#FFFAEF` / ink `#141111` 2px borders / zero-blur offset shadows / flat colors / Space Grotesk + Space Mono bundled under `Resources/Fonts/`, OFL — the visual language of raft.build). Brutal is the only *structural* style (`isHardEdged`): it changes radii, borders, shadows, and fonts.
- **Palette themes** — Catppuccin, Gruvbox, Nord, Solarized, Rosé Pine, One Dark, Kanagawa (official palettes, MIT/Apache). These keep the classic structure and only swap colors: each is one entry in the `palettes` table in `Theme.swift` (`ThemePalette`), so adding/removing one touches only the enum, `resolve`, the table, and the Settings picker.

Mechanism: every `Theme.*` token is a `static var` dispatching on `ThemeStyle.current`; call sites never branch. Switching re-renders via `.id(settings.themeStyle)` on `PopoverRootView`'s root — child views must not cache theme values. **Invariant: the `classic` branch of every token must keep its pre-theming value exactly** (default style stays pixel-identical). Zero-blur shadows are painted on pure shape layers only — never on views containing text (glyph ghosting, fixed in 0.20.1). Island/Mascot are intentionally outside `Theme` and unaffected; per-vendor agent brand colors are not theme tokens. Visual walkthrough: `--render-shell <dir> [--style <id>]`.

### Task state machine (`EurekaKit/TaskStore.swift`)

Key = `source:sessionId`. Phases: `running` / `waiting(permission|idle)` / `idle` / finished. `apply(event)` returns `[TaskStoreEffect]` (`taskFinished` / `taskWaiting` / `activeTasksChanged`); the app layer turns effects into island cards, history writes, and status-bar updates. Claude sessions stay alive across turns (turn end → `idle`, next prompt → `running`); Codex idle sessions are reaped by `reapStaleTasks`. Running tasks with no heartbeat for >4h are reaped as `interrupted` (guards against lost hooks). The store is pure logic — callers own thread confinement (the app runs it on `@MainActor`).

## Critical invariants — do not break these

- **`eureka-relay` hard constraints:** always `exit 0`, stdout absolutely silent (UserPromptSubmit stdout gets injected into the model's context, and **PreToolUse stdout is read as a permission decision** — any byte there could allow or block a tool call), <50ms, stdin capped at 1MB. It writes to `tmp/` then `rename`s atomically into the spool. The envelope carries a top-level `terminal` object (env + controlling tty) so the app knows which terminal a session runs in; collecting it must stay syscall-only — never start a subprocess.
- **Relay stable path:** hooks/notify configs only ever reference `~/Library/Application Support/Eureka/bin/eureka-relay`. The app re-syncs the bundled binary there on launch (by hash) so upgrades don't break the link — never hardcode the app-bundle path into installed configs.
- **Stale-event suppression:** events older than 5 minutes only enter history/usage; they must NOT trigger island animations (`AppDelegate.handle` drops stale heartbeat/waiting/session-start events entirely).
- **Usage dedup is mandatory and persistent:** Claude transcripts duplicate `(requestId, message.id)` rows heavily across files (resume/fork copies old rows into new files). Dedup must persist across files (via `scan_state`), or usage will be inflated.
- **Hook installers must never overwrite an event wholesale.** `~/.claude/settings.json` and `~/.codex/hooks.json` share the same shape (`hooks: {Event: [{hooks: [...]}]}`) and both are routinely shared with other apps (`~/.codex/hooks.json` is occupied by Otty locally). `~/.trae-cn/hooks.json` is written in that same shape but **that shape is a reasoned guess, not verified** — see the gating invariant below. Only add/remove entries carrying the `eureka-relay` marker; an unrecognisable shape must abort the write rather than be treated as an empty array.
- **Codex and Trae hook stdout are as dangerous as Claude's.** Codex's `PermissionRequest` very likely reads stdout as an allow/deny decision; Trae's hook runtime explicitly honours `hookSpecificOutput` / `permissionDecision` / `additionalContext` / `stopReason` (verified in `libai_agent.dylib`). The relay's silence rule covers `codex-hook` and `trae-hook` exactly as it covers `claude-hook`.
- **Claude OAuth usage (rate limits) is unofficial, opt-in, default-off.** Any failure returns `nil` → the entire UI block hides. Keychain is read via the `/usr/bin/security` subprocess (avoids ACL re-prompts after ad-hoc re-signing).
- **Trae's session database is SQLCipher-encrypted and must never be treated as readable or backupable.** `~/Library/Application Support/Trae CN/ModularData/ai-agent/database.db` starts with a 16-byte random salt (`sqlite3` reports "file is not a database"), and there is no plaintext transcript anywhere — so **no message bodies, no titles, no tokens, no rate limits** for Trae, ever. Session titles/timestamps come from the plaintext memory library (`TraeSessionIndexer` parses `memory/projects/<encoded>/<YYYYMMDD>/topics.md`), which is **asynchronous and may be empty** if the user turned Trae's memory off. Backup is a strict whitelist (`SyncRoots.traeRoots`): skills / user_rules / memory only. Never walk `~/.trae-cn` itself (`trae-jwt-token` is a JWT, `mcp.json` may hold API keys) nor the Application Support dir (Cookies + that database).
- **Trae's hooks are a per-account server-gated feature, and the local account may not have them.** The Hooks settings tab's visibility is `dynamicConfig.iCubeApp.hooks.enable === true || account.scope === BYTEDANCE` (`workbench.desktop.main.js`). When it's off the Rust resolver logs `resolve_hooks_config is_ok=true` and goes straight to `UserPromptSubmit hook completed` **without ever reading `~/.trae-cn/hooks.json`** — no `Triggering hook: id=`, no `[parse_hooks_config] skipping config file`, not even our path in the log. Verified on this machine (scope `marscode`, no `hooks` key in the fetched config): the integration is inert. Consequence: the two config **paths** are verified from Trae's own code, but the **file schema inside them is not** — the binary also carries `id` / `if_expr` / `exec_env` / `version` / `matcher` field names, so the real shape may be a flat array of hook objects rather than Claude's event map. `TraeHooksInstaller` writes the Claude shape on purpose (Trae's payload and output contract are Claude's, and it can `import_claude_folders`) and is safe if wrong — worst case Trae ignores the file. **Re-verify before claiming Trae live cards work**; the recipe is in that file's header comment.
- **Trae comes in two independent installs and they are one `AgentSource`.** CN is `~/.trae-cn` + `Application Support/Trae CN`; international is `~/.trae` + `.../Trae` (names come from each `product.json`'s `dataFolderName` / `nameShort`). They are **not symmetric**: only CN has hooks and a memory library (the international `libai_agent.dylib` has no `src/domain/hooks/…` at all). `TraePaths.installedChannels()` returns CN first; anything hooks- or memory-related is CN-only by construction.
- **Cursor's `state.vscdb` must never be backed up or synced.** The same SQLite file that holds every Cursor session also holds `cursorAuth/accessToken` and `cursorAuth/refreshToken` in its `ItemTable`. `SyncSourceCatalog` only ever walks `~/.cursor/skills` for Cursor — never add the database or its parent directory.
- **External agent databases are opened read-only, never with `immutable=1`.** Cursor / opencode / Hermes hold their libraries open in WAL mode; `immutable=1` would silently skip everything not yet checkpointed, so live sessions would look frozen.
- **Never scan a Codex rollout to the end just to find a title.** `CodexSessionIndexer.headInfo` reads a bounded head (`headScanLimit`, 1 MB) because ~24% of rollouts have no `user_message` at all and files reach 70 MB — scanning to EOF cost 65s of a 72s discovery. It also **must take only the first `session_meta`**: resumed/forked rollouts contain a second one, and letting it win assigned another session's id to the file (121 files → 91 unique ids before the fix).
- **Session discovery is expensive and must be shared.** `AgentSessionDiscovery.forIndexing()` feeds both indexers from one call; `ProjectScopeDiscovery` caches `recentCwds` for 60s because four knowledge services ask for it during warm-up. Full-text and per-turn indexing run on a 5-minute cadence (`UsageService.indexInterval`), not the 60s usage tick — they aren't real-time and only re-pay the discovery cost.
- **`~/.codex/memories` is a git repo Codex maintains, and only its three top-level files are memories.** Never recurse it: `rollout_summaries/` are per-session summaries, `extensions/` is meta-instruction, and `skills/` holds a real skill. Codex has **no per-project memory** — attribution lives inside the content (`applies_to: cwd=…`). Memory vs instructions is a hard split app-wide: agent-written = Memory tab, user-written rules (`CLAUDE.md`/`AGENTS.md`/`GEMINI.md`/`QWEN.md`/`.cursor/rules`/Hermes `SOUL.md`/Trae `user_rules.md` + `.trae/rules/*.md`) = 指令 tab, and the two never share a count.
- **`~/.claude/projects/<encoded>` directory names are lossy — never reverse them.** Claude replaces `/`, `.` **and** `_` with `-` (verified against all 11 local dirs), so splitting on `-` turns `aftership-semantic-layer` into `layer`. Resolve project names by encoding known repo roots *forward* and matching (`SkillMemoryIndexer.resolveProjectName`), falling back to a transcript-head `cwd`. Trae's `~/.trae-cn/memory/projects/<encoded>--p<N>-<hash>` uses the same encoding plus a suffix — strip the suffix (`TraeSessionIndexer.stripProjectSuffix`), then match forward the same way; never split on `-`.
- **A memory's `metadata.originSessionId` often points at a session that no longer exists** (84 memories carry one locally, only 37 transcripts survive). `originSessionPath == nil` means "not navigable": grey it out instead of offering a jump into an empty session page.
- **Dependency scope stays narrow:** Sparkle 2.9.2 is exact-pinned and only linked by the app target. SQLite still uses system `libsqlite3`, so the DB stays `sqlite3`-inspectable.

## Data & config locations

Cursor is the one source whose data is not under a dotfile home: sessions/messages/tokens all live in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (with cwd resolved via `User/workspaceStorage/<id>/workspace.json`), while its skills live in `~/.cursor/skills`.

Trae splits the same way but across **two installs** (see the invariants above). Per install: hooks `<dataFolder>/hooks.json` (CN only) and `<repo>/.trae/hooks.json`; skills `<dataFolder>/{skills,builtin_skills,builtin/global/skills}` and `<repo>/.trae/skills`; user rules `<dataFolder>/user_rules.md` + `<dataFolder>/user_rules/*.md` and `<repo>/.trae/rules/*.md`; plans `<repo>/.trae/documents/plan_*.md` (real `.md`, indexed in place like Hermes — not materialized); memory `~/.trae-cn/memory/{user_profile.md,projects/<encoded>/{project_memory.md,<YYYYMMDD>/topics.md}}` (CN only). cwd is resolved via `<appSupport>/User/workspaceStorage/<id>/workspace.json`, same trick as Cursor. Slash commands (`<dataFolder>/commands`) are deliberately **not** indexed — no source's commands are.

App data lives in `~/Library/Application Support/Eureka/`: `eureka.sqlite` (history/usage/sessions), `events/` (spool), `bin/eureka-relay` (stable path), optional `pricing.json` (override price table) and `context-windows.json` (override per-model context-window size, the denominator for ctx%). Config backups are written as `*.bak.eureka.*` before any hooks/notify edit.

## Further reading

`AGENTS.md` — commit message / PR title / release conventions (all English; read before committing or releasing). `docs/design.md` — full design doc (verified data-source formats for Claude transcript / Codex rollout / hooks, key decisions, milestones). `README.md` — feature tour, interaction cheatsheet, known boundaries.
