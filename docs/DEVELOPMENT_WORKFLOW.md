# Development workflow

English · [简体中文](DEVELOPMENT_WORKFLOW.zh-CN.md)

The engineering loop every change goes through, from issue to release. It
complements [CONTRIBUTING.md](../CONTRIBUTING.md) (how to file issues, proposals,
and pull requests), [`AGENTS.md`](../AGENTS.md) (commit, PR, and release
conventions), and [`CLAUDE.md`](../CLAUDE.md) (architecture and critical
invariants). Build commands are listed in [BUILD.md](BUILD.md).

## Contents

1. [Lifecycle overview](#1-lifecycle-overview)
2. [Branches and worktrees](#2-branches-and-worktrees)
3. [Implementing a change](#3-implementing-a-change)
4. [Testing](#4-testing)
5. [Local verification gates](#5-local-verification-gates)
6. [Working with real data safely](#6-working-with-real-data-safely)
7. [Committing](#7-committing)
8. [Pull request and review](#8-pull-request-and-review)
9. [Merging and releasing](#9-merging-and-releasing)
10. [Definition of done](#10-definition-of-done)
11. [AI coding agents](#11-ai-coding-agents)

## 1. Lifecycle overview

```
 Issue ──► (Proposal + design doc, if required) ──► Branch / worktree
                                                         │
             ┌───────────────────────────────────────────┘
             ▼
   Implement + tests ──► Local verification gates ──► Draft PR (optional)
                                                         │
                                                         ▼
   Release ◄── Squash merge to main ◄── Review ◄── Ready for review
```

| Stage | Exit criterion |
|---|---|
| Issue | Problem agreed; owner assigned. |
| Proposal | Marked *Accepted* by a maintainer (only when [required](../CONTRIBUTING.md#when-a-proposal-is-required)). |
| Implement | Code and tests written on a dedicated branch. |
| Verify | All [gates](#5-local-verification-gates) pass locally. |
| Review | ≥ 1 approval, all threads resolved. |
| Merge | Squash-merged; `main` builds and tests green. |
| Release | Tag `vX.Y.Z` pushed per `AGENTS.md`; CI publishes. |

## 2. Branches and worktrees

- `main` is always releasable. Nobody pushes to it directly; everything lands
  through a squash-merged PR.
- Work on short-lived branches named `<type>/<short-kebab-summary>`
  (`fix/opencode-watermark`, `docs/contributing-guide`). Delete them after merge.
- Keep the branch rebased on `main` (`git fetch && git rebase origin/main`).
  Don't merge `main` into a feature branch.
- **Prefer a git worktree per task** so parallel work (including AI agent
  sessions) never shares a working directory:

  ```bash
  git worktree add .worktrees/<branch> -b <branch> origin/main
  cd .worktrees/<branch>
  ```

  `.worktrees/` and `.claude/worktrees/` are git-ignored. Remove a worktree
  when you're done: `git worktree remove .worktrees/<branch>`.
- **Stacked work**: when B depends on unmerged A, branch B from A, open B's PR
  against A with `Depends on #A`, and retarget B to `main` after A merges.
- In a shared checkout, stage only your own hunks (`git add -p`) — never
  `git add -A` / `git add .`.

## 3. Implementing a change

Before writing code, re-read the parts of `CLAUDE.md` that cover the modules you
are touching. In particular:

- **Respect module direction**: `app → {EurekaIngest, EurekaUsage, EurekaSync}
  → EurekaStore → EurekaKit`. `EurekaKit` stays pure (no IO, no AppKit).
  `EurekaInstall` depends only on `EurekaKit`. `eureka-relay` has zero deps.
- **Respect the critical invariants**. If your change touches one, it needs a
  proposal and the PR must say how the invariant still holds.
- **External agents' data is read-only.** Open their databases read-only and
  never with `immutable=1`; never write to their transcripts or config except
  through the hook installers, which only add/remove entries carrying the relay
  name and back up first.
- **No secrets in code or logs.** Credentials come from the environment or the
  Keychain and are never printed.
- **Strings and comments**:
  - User-visible strings: `L10n.text("English", zhHans: "中文")` /
    `L10n.format`. English is the source and the default.
  - Code comments: **English only**, explaining *why* rather than *what*.
    `make lint-comments` fails on CJK text in comments; string literals are
    exempt.
- **Small, reversible steps.** Prefer default-off flags for experimental
  features (see `AntigravityExperiment`).
- **No new dependencies** without an accepted proposal.

## 4. Testing

The project uses a hand-rolled harness (Command Line Tools ships no XCTest):

- Suites live in `Tests/EurekaTestsRunner/*Tests.swift`; each is a function that
  calls `expect` / `expectEqual` (see `Harness.swift`).
- **Register new suites** in `Tests/EurekaTestsRunner/main.swift`, or they never
  run.
- Fixtures go in `Tests/EurekaTestsRunner/Fixtures/` and load via
  `fixtureURL` / `fixtureData`. Fixtures must be synthetic or fully redacted —
  never copy real transcripts, emails, or tokens.
- There is no test filter. To iterate on one suite, temporarily comment out the
  others in `main.swift` — and restore them before committing.
- Bug fixes start with a failing test that reproduces the bug (red → green).
- Pure logic (`EurekaKit`, decoders, scanners, installers) is tested directly;
  UI is verified with the offscreen renderers (next section).

## 5. Local verification gates

Run these before marking a PR **Ready for review**, and paste the results into
the PR's *Verification* section.

**Always required**

| Gate | Command | Pass condition |
|---|---|---|
| Build | `make build` | No errors; no new warnings in files you touched. |
| Tests | `make test` | `N passed, 0 failed`. |
| Comment language | `make lint-comments` | Exit 0. |
| Diff hygiene | `git diff origin/main --stat` | Only files related to this change. |

**Required when the change touches the area**

| Area | Command | Pass condition |
|---|---|---|
| Usage scanners / pricing | `Scripts/check-usage-against-ccusage.sh` | `0.00%` diff against ccusage. |
| Island states | `make demo` or `swift run eureka --render-previews <dir>` | Every state renders; screenshots in the PR. |
| Sidebar / pages / settings | `swift run eureka --render-pages <dir>` and `--render-shell <dir>` (add `--style brutal`) | Light + dark screenshots, both styles, attached. |
| Turn lineage graph | `swift run eureka --render-lineage <dir>` | Golden and live graphs render. |
| Hooks / installers | `swift run eureka --hooks-status` | Expected state; no foreign entries changed. |
| Relay | `swift run eureka-relay inject --event stop --session demo` | Exit 0, stdout empty, event appears. |
| Rate limits | `swift run eureka --limits-snapshot` | Snapshot decodes; failures yield `nil`, not a crash. |
| MCP | `swift run eureka --mcp-inspect <name>` | Probe succeeds against a test server. |
| Packaging / release | `make app` | App assembles and launches. |

## 6. Working with real data safely

The app's database and the agents' files on your machine are real, irreplaceable
history.

- Never point experiments, scripts, or subagents at the live
  `~/Library/Application Support/Eureka/eureka.sqlite`. Make a copy and use it:

  ```bash
  sqlite3 ~/Library/Application\ Support/Eureka/eureka.sqlite \
    ".backup '/tmp/eureka-copy.sqlite'"
  EUREKA_DB_PATH=/tmp/eureka-copy.sqlite swift run eureka --usage-snapshot
  ```

- Never run `DROP`, `TRUNCATE`, or unscoped `DELETE` against any database by
  hand. Schema changes go through code, with a migration and a test.
- Hook installers write `*.bak.eureka.*` backups before editing config; keep
  that behaviour for any new installer.
- Redact screenshots and logs before attaching them to a PR or issue.

## 7. Committing

Full rules in [`AGENTS.md`](../AGENTS.md#commit-messages). In short:

- `<type>(<scope>): <imperative summary>`, English, lowercase, no period,
  ≤ 72 chars; optional body explaining *what* and *why*.
- One logical change per commit; never mix refactors with behaviour changes.
- Keep mechanical changes (formatting, renames, translations) in their own
  commits so reviewers can skip them.
- Don't commit build output (`.build/`, `dist/`), local worktrees, or personal
  config.

## 8. Pull request and review

1. Push the branch and open a PR with the template — as a **draft** if you want
   early feedback ([rules](../CONTRIBUTING.md#draft-pull-requests)).
2. Fill in every section; *Verification* contains real command output.
3. Request review. Respond to every comment; reviewers resolve threads.
4. Mark **Ready for review** only when the [definition of done](#10-definition-of-done)
   is met.

## 9. Merging and releasing

- Squash-merge once approved and rebased; the PR title becomes the commit on
  `main`.
- User-visible changes get a `CHANGELOG.md` entry under `[Unreleased]`.
- Releases follow [`AGENTS.md` → Release procedure](../AGENTS.md#release-procedure):
  changelog → bump `VERSION` → `make pricing-catalog` → `make build && make test`
  → push `main` → tag `vX.Y.Z` → CI builds, signs and publishes → polish the
  release page.
- Hotfixes follow the same path with a `fix(...)` PR and a patch version.

## 10. Definition of done

A change is done when **all** of these hold:

- [ ] The issue / proposal is linked and its acceptance criteria are met.
- [ ] Code respects module direction and every critical invariant in `CLAUDE.md`.
- [ ] Tests cover the new behaviour; `make test` reports 0 failures.
- [ ] `make build` and `make lint-comments` pass.
- [ ] Area-specific gates from §5 pass, with evidence in the PR.
- [ ] User-visible strings are localized through `L10n`; comments are English.
- [ ] Docs updated (`README.md`, `README.zh-CN.md`, `CLAUDE.md`, `docs/`) where
      behaviour, commands, or invariants changed.
- [ ] `CHANGELOG.md` updated for user-visible changes.
- [ ] No secrets, personal data, or real transcripts anywhere in the diff.

## 11. AI coding agents

Agents (Claude Code, Codex, …) are held to the same workflow:

- Work in a dedicated worktree and branch; never on `main` directly.
- Read `AGENTS.md` and `CLAUDE.md` first; they are the source of truth for
  conventions and invariants.
- Run the verification gates and report their real output — never claim a gate
  passed without running it.
- Subagents that inspect data use a database copy via `EUREKA_DB_PATH`, never
  the live file.
- Commit only when asked, staging only the files the task touched.
