# Contributing to lulu-lumei-dock

English · [简体中文](CONTRIBUTING.zh-CN.md)

Thanks for helping out. This guide covers **how to ask for things** (issues and
proposals) and **how to hand in changes** (draft and ready pull requests). The
day-to-day engineering loop — branching, testing, verification gates, release —
lives in [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md).

AI coding agents follow exactly the same rules. `AGENTS.md` and `CLAUDE.md`
add agent-facing detail (commit conventions, architecture, critical invariants);
nothing in them relaxes this guide.

## Contents

- [Ground rules](#ground-rules)
- [Pick the right channel](#pick-the-right-channel)
- [Issues](#issues)
- [Proposals](#proposals)
- [Pull requests](#pull-requests)
- [Draft pull requests](#draft-pull-requests)
- [Code review](#code-review)
- [Coding standards at a glance](#coding-standards-at-a-glance)
- [Security](#security)

## Ground rules

- Be respectful and assume good faith. Critique code, not people.
- One logical change per pull request. Refactors and behaviour changes never
  share a PR.
- Search existing issues and PRs before opening a new one.
- Anything non-trivial starts as an issue, so the direction is agreed before
  code is written. Typo and small doc fixes can go straight to a PR.
- Never paste secrets, tokens, API keys, or personal data (emails, real session
  content, `eureka.sqlite` dumps) into issues, PRs, logs, or screenshots.

## Pick the right channel

| You want to… | Use |
|---|---|
| Report something broken | **Bug report** issue |
| Ask for a small, self-contained improvement | **Feature request** issue |
| Change architecture, data flow, a critical invariant, or add an agent / dependency | **Proposal** issue + design doc (see [Proposals](#proposals)) |
| Share early code to get feedback on direction | **Draft** pull request |
| Submit finished, verified work | **Ready-for-review** pull request |
| Report a security vulnerability | Private security advisory — **never** a public issue |

## Issues

Issue forms live in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/).
Issues may be written in English or Chinese; titles should be short and specific.

### Bug reports

A good bug report lets someone else reproduce the problem without asking
follow-up questions. Include:

- **Version** — app version from *Settings → About* (or `VERSION` for source
  builds) and macOS version.
- **Agent(s) involved** — Claude Code, Codex, Cursor, … and their versions.
- **Hook / notify state** — output of `swift run eureka --hooks-status`, or say
  "hooks not installed".
- **Steps to reproduce**, **expected** and **actual** behaviour.
- **Evidence** — screenshots or logs **with personal data redacted**.

Usage-total bugs: attach the output of `Scripts/check-usage-against-ccusage.sh`
if you can — the target is a `0.00%` diff.

### Feature requests

Describe the **problem first**, then the proposed solution and the alternatives
you considered. "As a user of X, I can't Y because Z" beats "please add a
button". If the request touches anything listed under [Proposals](#proposals),
a maintainer will ask for one.

### Triage and labels

Maintainers apply the labels: `bug`, `enhancement`, `documentation`,
`question`, `good first issue`, `help wanted`, `duplicate`, `invalid`,
`wontfix`. Proposals carry `enhancement` and a `[Proposal]` title prefix.
Comment "I'd like to take this" before starting so work isn't duplicated; an
assignee with no activity for 14 days may be unassigned.

## Proposals

A proposal is a lightweight design review done **before** implementation.

### When a proposal is required

- Adding a new agent source (tailer, scanner, indexer, or hook installer).
- Changing the event pipeline, the `TaskStore` state machine, or the relay
  envelope / CLI contract.
- Changing an SQLite schema, the spool format, or anything persisted on disk.
- Touching any item in *Critical invariants* in `CLAUDE.md`.
- Adding a third-party dependency (the runtime currently depends on Sparkle
  only — a new one needs strong justification).
- A new top-level UI surface (sidebar page, island state, settings tab) or a new
  theme style.
- Anything that reads credentials, Keychain items, or a new external database.

Bug fixes, small UI polish, tests, and docs do **not** need a proposal.

### Lifecycle

```
Draft ──► Discussion ──► Accepted ──► Implemented
                    └──► Declined / Withdrawn
```

1. **Open a Proposal issue** with the template. Fill in motivation, design
   sketch, affected modules and invariants, alternatives, and a rollout /
   rollback plan.
2. **Write the design doc** when the change is larger than the issue can hold:
   `docs/specs/YYYY-MM-DD-<slug>-design.md` (existing examples live there).
   Submit it as its own `docs(specs): …` PR, or attach it to the issue.
3. **Discussion** — at least one maintainer review. Unresolved questions are
   listed in the doc, not left in comment threads.
4. **Decision** — a maintainer marks the issue *Accepted* or *Declined* with a
   one-paragraph rationale. Accepted proposals may get an implementation plan
   under `docs/superpowers/plans/`.
5. **Implementation** — PRs reference the proposal (`Implements #123`). If the
   design must change materially during implementation, update the doc first.

## Pull requests

### Before you open one

- [ ] There is an issue (or proposal) for anything non-trivial, and the PR links it.
- [ ] The branch is up to date with `main` (rebase; don't merge `main` in).
- [ ] The local verification gates in
      [DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md#local-verification-gates)
      pass.

### Branch names

`<type>/<short-kebab-summary>`, using the commit types below — e.g.
`fix/codex-rollout-title`, `feat/trae-live-cards`, `docs/contributing-guide`.

### Title

PRs are **squash-merged**, so the title becomes the commit message on `main`.
It must follow [Conventional Commits](https://www.conventionalcommits.com/) and
stand on its own:

```
<type>(<scope>): <imperative summary>
```

- **Types**: `feat` `fix` `docs` `refactor` `perf` `test` `chore` `ci`
- **Scopes**: `ui` `island` `claude` `codex` `opencode` `grok` `kimi`
  `antigravity` `hermes` `codebuddy` `qoder` `cursor` `trae` `ingest` `usage`
  `store` `sync` `install` `updates` `packaging` `ci` `changelog`
- English, imperative mood, lowercase, no trailing period, ≤ 72 characters.
- No `WIP` / `Draft` / `[skip ci]` in the title — use GitHub's draft state.

Good: `fix(codex): read only the first session_meta in a rollout`
Bad: `Fixed bugs`, `WIP: codex stuff`, `feat: Update Island.`

### Description

The [pull request template](.github/pull_request_template.md) is pre-filled
when you open a PR. Keep every section; write `N/A` rather than deleting one.
PR titles and bodies are **English only**. The template asks for:

| Section | What goes in it |
|---|---|
| **Summary** | What changed, in 1–3 sentences, user-visible effect first. |
| **Motivation** | Why — link the issue / proposal (`Closes #12`, `Implements #34`). |
| **Changes** | Bullet list grouped by module (`EurekaIngest`, `EurekaApp`, …). |
| **Verification** | Exact commands run and their result, manual checks, screenshots for UI. |
| **Risk & rollback** | Invariants touched, migration / data impact, how to revert. |
| **Checklist** | The definition-of-done boxes. |

### Size

Aim for < 400 changed lines excluding generated files, fixtures, and pure
translations. Larger work is split into **stacked PRs**: each targets the
previous branch, states `Depends on #N` in its description, and is merged in
order (retarget to `main` after the parent merges).

### Merging

- Squash-merge only. The squash message is the PR title plus a trimmed body.
- Requirements: at least one approving review, all conversations resolved, the
  checklist complete, and the branch rebased on current `main`.
- The author merges after approval unless they ask a maintainer to.
- User-visible changes add an entry under `## [Unreleased]` in `CHANGELOG.md`
  (or the release PR collects them — say which in the description).

## Draft pull requests

Open a **draft** when you want feedback before the work is done: validating an
approach, sharing a spike, or parking a stacked PR whose parent is not merged.

Rules:

1. Create it as a draft (`gh pr create --draft`, or *Create draft pull
   request*) — never mark intent with `WIP:` in the title.
2. The title already follows the Conventional Commits format; the description
   uses the same template, with a **Status** line at the top of *Summary*:
   what works, what is missing, and the specific feedback you want.
3. Draft PRs may have failing checks and missing tests. Reviewers give
   direction-level feedback only; no line-by-line review, no approvals.
4. Before **Ready for review**: every checklist item ticked, the Status line
   removed, history tidied (fixups squashed), and the verification section
   filled with real output.
5. A draft with no activity for 30 days may be closed; reopen it when you
   resume.

## Code review

**Authors**

- Review your own diff first. Leave comments on anything surprising.
- Answer every comment: either push a change or explain why not. The reviewer
  resolves the thread.
- Push follow-up commits during review (don't force-push mid-review unless you
  are rebasing on `main`); they disappear in the squash anyway.

**Reviewers**

- Aim for a first response within 2 working days.
- Check, in order: correctness and invariants (`CLAUDE.md`), data safety
  (no writes to external agents' files, no secrets), tests, readability, style.
- Prefix non-blocking remarks with `nit:`. Use *Request changes* only for
  blocking issues and say what would unblock.

## Coding standards at a glance

Full detail: `CLAUDE.md` (architecture and invariants) and `AGENTS.md`
(commits and releases).

| Topic | Rule |
|---|---|
| Code comments | **English only** — doc comments, inline comments, `MARK`s, test comments, script comments. Enforced by `make lint-comments`. |
| UI strings | English source through `L10n.text(_:zhHans:)` / `L10n.format`; Simplified Chinese goes in the `zhHans` argument. Don't cache `L10n.text` in a `static let`. |
| Test titles | May stay Chinese (they are string literals, not comments). |
| Commits, PRs, releases, `CHANGELOG.md` | English only. |
| Module boundaries | `app → {EurekaIngest, EurekaUsage, EurekaSync} → EurekaStore → EurekaKit`; `EurekaKit` has no IO or AppKit; `eureka-relay` has zero dependencies. |
| Dependencies | Sparkle only, exact-pinned, app target only. New ones need an accepted proposal. |
| Relay | Always `exit 0`, stdout silent, < 50 ms, no subprocesses (except the documented notify chain). |
| Tests | Every behaviour change ships with tests in the hand-rolled harness (`Tests/EurekaTestsRunner`). |

## Security

- **Do not** open a public issue for a vulnerability. Use GitHub's
  [private vulnerability reporting](https://github.com/vinlee19/lulu-lumei-dock/security/advisories/new).
- Never commit `.env*` files, keys, certificates, tokens, or Keychain dumps.
- Code that reads credentials must go through environment variables or the
  Keychain, never through hardcoded values, and must not log them.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
