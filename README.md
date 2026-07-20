# lulu-lumei-dock ✦

**English** · [中文](README.zh-CN.md)

**A macOS menu-bar "Dynamic Island" for your local AI coding agents.**

Surfaces live task activity, a ccusage-accurate usage ledger, subscription rate‑limit
gauges, session/skill/agent/memory management, an audit trail and cloud backup — for
**Claude Code · Codex CLI · opencode · Grok · Antigravity · Kimi Code**, all in one overlay.

`Swift 5.10 + SwiftPM` · `Sparkle is the only third‑party dependency` · `all data stays local`
· builds with Command Line Tools (no full Xcode needed)

> **About the name** — the project (this repo) is **lulu-lumei-dock**. It is built on the internal
> **Eureka** codebase, so the Swift module names (`EurekaKit`, …), the bundle identifier
> (`com.vinlee.eureka`) and the on‑disk data directory (`~/Library/Application Support/Eureka/`) keep the
> `Eureka` name for compatibility. Renaming those would break the relay stable path and existing installs,
> so they are intentionally left as‑is.

|  |  |
|---|---|
| ![compact](docs/images/island-compact.png) | ![finished](docs/images/island-finished.png) |
| **Running** — source badge (✳ Claude / ⌨ Codex) + count + timer | **Finished** — duration / session / project / source |
| ![tasklist](docs/images/island-tasklist.png) | ![wellness](docs/images/island-wellness.png) |
| **Task list** — current tool / ctx% / idle sessions | **Wellness** — a gentle nudge after long vibe‑coding |

## Install

**Homebrew (recommended)**

```bash
brew tap vinlee19/tap
brew install --cask lulu-lumei-dock
```

**Manual** — download the latest `.zip` from [Releases](https://github.com/vinlee19/lulu-lumei-dock/releases), unzip `lulu-lumei-dock.app` into `/Applications`.

Starting with `v0.1.5`, installed apps can check for signed updates in **Settings → About**. `v0.1.4`
and earlier need one final manual/Homebrew upgrade before in-app updates become available.

**First launch:** the app is **ad‑hoc signed** (not Apple‑notarized), so Gatekeeper may block it. Either right‑click the app → **Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/lulu-lumei-dock.app
```

> The installed bundle is `lulu-lumei-dock.app` and data lives in `~/Library/Application Support/Eureka/` (the internal name stays `Eureka` for compatibility). Building from source? See [Development](#development).

## What is this?

`lulu-lumei-dock` is a native macOS menu‑bar app that watches the local logs of your AI coding
agents and turns them into a live **Dynamic Island** overlay near the notch, plus a full panel
with usage analytics, rate limits, and management for sessions, skills, agents and memory.

It works with six agents out of the box — **Claude Code, Codex CLI, opencode, Grok,
Antigravity, and Kimi Code** — and needs **no network** for its core features: everything is
derived by reading local transcript / rollout / session files. The updater checks this repository's GitHub
Releases feed by default (disable it in Settings → About); the Claude subscription rate-limit gauge is the
other network feature and remains opt-in/off by default.

It also works **without installing any hooks** — transcript/rollout watchers are the fallback, so
sessions opened before hooks were installed are still visible.

## Features

**Dynamic Island notifications**
- A compact capsule pins to the top while tasks run (fuses with the notch, or drag it anywhere and
  it snaps back to center).
- Finished / errored / interrupted cards auto‑dismiss (hover to pause); waiting‑for‑permission /
  input cards stay until you deal with them.
- Multi‑task merged counts, queued finished cards shown one by one, click the capsule to expand the
  task list (current tool, context usage `ctx%`, idle sessions).
- Toggle time display: elapsed duration ↔ the session's original start time (resolved across resume
  chains to the true creation moment).
- Unified per‑source brand marks across the whole island (Claude star, Codex pinwheel, Grok slash,
  opencode terminal, Antigravity chevrons).

**Menu bar** — e.g. `▶2 · 37%`: active task count + the max of your subscription limits (Codex 5h /
Grok weekly / Claude), colored 60% amber / 85% red, with a tooltip breakdown.

**Usage ledger** (0.00% diff vs. `ccusage`) — today / this week / this month / custom range, broken
down by source, model, project (grouped to repo root) and session; estimated cost (with separate
cache pricing); a day/hour trend chart; a weekday×hour activity heatmap; and a
**skills / plugins** tab counting `skill` / `mcp` / `agent` / `command` / `tool` invocations. Export
the last 30 days to CSV.

**Skills** — browse, create, edit, and enable/disable skills across all five tools (enable/disable is
non‑destructive: the skill folder is moved to a sibling `*.eureka-disabled` directory). Plus a
dedicated **usage‑analytics** view (list ↔ stats toggle):
- Three rankings: **recently used / most used / longest unused**, each with last‑active time and
  cumulative count.
- Every list row shows its **last‑active** time.
- A **detail page** per skill: description, a cross‑tool **configuration matrix** (which of
  Claude/Codex/Grok/Antigravity/opencode has it, and whether it is user‑authored or tool‑bundled,
  shown as brand logos), and invocation stats — **count, trigger‑time tokens, and a daily trend**.
- Note on data: per‑skill invocation data is only recoverable for **Claude** (its transcript records
  `Skill` calls with usage on the same record). Trigger‑time tokens ≈ the context size at the moment
  of invocation, not the skill's full execution cost — this is labeled in the UI.

**Memory** — browse and edit `CLAUDE.md` / `AGENTS.md` and per‑project / per‑user memory files across
tools, with in‑app markdown preview + edit (atomic save with timestamped backup).

**Agent** — manage agent / subagent definitions across tools, mirroring the skills workflow.

**Plans** — browse and manage agent plan documents.

**Limits** — subscription rate‑limit gauges:
- **Codex** and **Grok** read a local snapshot (Codex from the newest rollout's `rate_limits`; Grok
  from `~/.grok/logs/unified.jsonl` billing entries) — **zero network**, hidden when unavailable.
- **Claude** is opt‑in (off by default) and uses an unofficial endpoint; any failure hides the whole
  block. Enabling it prompts a one‑time Keychain authorization (choose "Always Allow").

**Audit** — an append‑only trail of agent tool calls (full commands / file paths, no output bodies),
with risk flagging.

**Backup** — optional cloud backup of your local data to an S3‑compatible bucket (SigV4 signed).

**Signed in-app updates** — checks once per installed-app launch by default, then lets you explicitly
approve download/install in Sparkle's standard UI. Automatic download and unattended installation stay off.

**Health & wellness** — a data‑health dashboard shows heartbeat / output / failure status of every
data source (a stalled poller turns red), plus gentle wellness cards after long continuous activity,
many concurrent sessions, or late‑night runs.

## Supported agents

| Agent | Live tasks | Usage/tokens | Rate limits | Sessions | Skills / Memory / Agents |
|---|---|---|---|---|---|
| **Claude Code** | ✅ | ✅ | ✅ (opt‑in) | ✅ | ✅ |
| **Codex CLI** | ✅ | ✅ | ✅ (local) | ✅ | ✅ |
| **opencode** | ✅ | ✅ | — | ✅ | ✅ |
| **Grok** | ✅ | activity only¹ | ✅ (local) | ✅ | ✅ |
| **Antigravity** | ✅ | activity only¹ | — | ✅ | ✅ |
| **Kimi Code** | ✅ | ✅ | — | ✅ | ✅ (skills) |

¹ Grok is subscription‑based and Antigravity stores conversations as protobuf, so neither exposes
per‑request token accounting locally — only activity (invocations / sessions) is available.
Kimi Code has no local rate‑limit snapshot and no global memory / on‑disk agent-definition
convention, so those columns are skipped for it.

## Quick start

```bash
make install                 # build release + install to /Applications/lulu-lumei-dock.app
open /Applications/lulu-lumei-dock.app
```

On first launch the Settings tab opens — click **一键安装/更新 (Install / Update)** to write Claude
hooks and Codex notify (a `*.bak.eureka.*` backup is made first; "Uninstall all" restores it any
time). After that, any `claude` / `codex` task shows up on the island. Consider enabling
"Launch at login".

## Interaction cheatsheet

| Action | Effect |
|---|---|
| Click the capsule | Expand the running‑task list (incl. idle sessions) |
| Click a card | Advance to the next notification / dismiss |
| Hover a card | Pause auto‑dismiss |
| Drag the island | Move anywhere (incl. external displays); drop near top‑center to snap back |
| ⏱ in the task list | Toggle elapsed ↔ start time |
| Menu‑bar ✦ left‑click | Open the panel (history / sessions / usage / limits / settings …) |
| Menu‑bar ✦ right‑click | Quit |

## Configuration & data

All data lives in `~/Library/Application Support/Eureka/`:

| Path | Purpose |
|---|---|
| `eureka.sqlite` | history / usage / sessions / audit (inspect directly with `sqlite3`) |
| `events/` | event spool (hooks → relay writes here atomically, app consumes) |
| `bin/eureka-relay` | the stable path referenced by hooks/notify (re‑synced by hash on launch) |
| `pricing.json` (optional) | override the built‑in price table (USD / million tokens, prefix match) |
| `context-windows.json` (optional) | override per‑model context window size, e.g. `{"claude-opus": 1000000}` |

**Privacy:** automatic update checks contact this repository's GitHub Releases feed and can be disabled.
The opt-in "Claude subscription limits" feature sends a Keychain OAuth token to Anthropic. Core activity,
session and usage data stays local unless you explicitly configure cloud backup.

## CLI

```bash
eureka --install-claude-hooks      # install/update Claude hooks (backs up first)
eureka --uninstall-claude-hooks
eureka --install-codex-notify      # install Codex notify
eureka --uninstall-codex-notify
eureka --hooks-status              # install state for both sides
eureka --usage-snapshot            # full scan → today's usage JSON (used by the ccusage diff)
eureka --limits-snapshot [--claude]# rate-limit snapshot (Codex + Grok local; --claude also hits the unofficial API)
eureka --audit-snapshot            # dump the agent tool-call audit trail (--risk-only / --limit N)
eureka --render-previews [dir]     # offscreen-render every island state to PNG
eureka-relay inject --event stop --session demo   # inject a test event into the spool
```

## Development

```bash
make build      # debug build (Command Line Tools is enough — no full Xcode)
make test       # runs the full hand-rolled test suite (300 tests; CLT has no XCTest)
make run        # run the GUI in dev mode
make demo       # inject fake events to show every island state
make app        # release build → dist/lulu-lumei-dock.app (ad-hoc signed)
make package-release # verified ZIP + appcast containing its EdDSA signature
make install    # app + install to /Applications/lulu-lumei-dock.app
make clean      # rm -rf .build dist
Scripts/check-usage-against-ccusage.sh   # diff usage totals vs. ccusage (expect 0.00%)
```

There is no test filter — the runner (`Tests/EurekaTestsRunner/main.swift`) calls each suite
sequentially. To run a subset, comment out suite calls in `main.swift`.

## Architecture

Data flows one direction: **external agents → relay → spool → app state machine → SQLite + UI
projections.**

```
Claude Code hooks ──┐                                   ┌─ Dynamic Island NSPanel (compact/expanded)
Codex notify ───────┤→ eureka-relay → events/ spool ────│
                    │   (atomic JSON write)    ↓         ├─ NSStatusItem + NSPopover
Codex rollout tail ─┘                    SpoolConsumer   │   (history / sessions / skills / usage / limits / …)
Claude transcript watch ──────────────→ TaskStore (state machine)
usage scanners (Claude/Codex/opencode/Grok) ──────────→ SQLite (history / usage / tool_calls / audit)
```

- **`eureka-relay`** is a tiny, fully independent binary: it always `exit 0`, keeps stdout silent,
  runs in <50ms, and writes to `tmp/` then atomically `rename`s into the spool. Hooks/notify configs
  only ever reference the stable path `~/Library/Application Support/Eureka/bin/eureka-relay`, which
  the app re‑syncs by hash on launch so upgrades never break the link.
- **Module dependency graph** (SwiftPM targets, strictly one‑directional):
  `app → {EurekaIngest, EurekaUsage, EurekaInstall, EurekaSync} → EurekaStore → EurekaKit`.
  `eureka-relay` is dependency‑free.
- **SQLite** uses the system `libsqlite3` so the DB stays `sqlite3`‑inspectable. Usage tables are
  *derived* (rebuilt from transcripts on a schema‑version bump); `task_history` / `audit_events` /
  sync tables are *facts* and are never dropped.

Full design doc: [docs/design.md](docs/design.md).

## Known limitations

- Codex's "waiting for approval" state isn't shown (rollouts don't persist approval events).
- Claude subscription limits rely on an unofficial endpoint and may break with official changes
  (it hides itself when it does).
- Per‑skill invocation data (count / tokens / trend) is **Claude‑only**; Codex/Grok/opencode/
  Antigravity don't tag skill invocations in their logs.
- `ctx%` for Claude is an estimate (window size from a per‑model table; overridable).
- Costs are local estimates against public price lists and may differ from your bill.

## Uninstall

Use Settings → "Uninstall all" to remove hooks/notify (restoring backups), then delete
`/Applications/lulu-lumei-dock.app` and `~/Library/Application Support/Eureka/`. Nothing is left behind.

## License

[MIT](LICENSE) © 2026 vinlee19
