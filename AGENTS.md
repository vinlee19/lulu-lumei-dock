# AGENTS.md

Conventions for AI agents (and humans) contributing to this repository.
Read this before committing, opening a PR, or cutting a release.

## Language rules

| Artifact | Language |
|---|---|
| Commit messages, PR titles & bodies, release titles & notes, `CHANGELOG.md` | **English only** |
| UI strings, in-code comments | Chinese (existing convention — keep it) |

## Commit messages

[Conventional Commits](https://www.conventionalcommits.com/):

```
<type>(<scope>): <imperative summary>
```

- **Types**: `feat` `fix` `docs` `refactor` `perf` `test` `chore` `ci`
- **Scopes** (pick the area touched): `ui` `island` `claude` `codex` `opencode`
  `grok` `kimi` `antigravity` `ingest` `usage` `store` `sync` `install`
  `updates` `packaging` `ci` `changelog`
- Summary: imperative mood, lowercase, no trailing period, ≤ 72 chars.
- Body (optional): bullet points explaining **what** and **why**, wrapped at ~80 chars.
- One logical change per commit. Never mix refactors with behavior changes.

Examples from history:

```
feat(ui): unify panel theme around brand indigo with codex-style spacing
fix(codex): align titles, plans, and memory semantics
docs(changelog): add changelog and backfill 0.1.5-0.1.7 entries
fix(packaging): load app resources from signed bundle layout
```

## Pull request titles

- Same format as commit messages: `<type>(<scope>): <summary>`, English.
- PRs are squash-merged, so **the PR title becomes the commit message** — it must
  be valid on its own. One PR = one logical change.
- PR body: what changed, why, and how it was verified (build/tests/manual checks).

## Versioning

- Semantic versioning, digits only: `X.Y.Z`.
- The `VERSION` file is the single source of truth; the git tag must be `v` +
  the exact `VERSION` content (CI rejects mismatches).

## Release procedure

1. **Changelog first** — add an entry to `CHANGELOG.md` (Keep a Changelog format,
   English): `## [X.Y.Z] - YYYY-MM-DD` with `### Added` / `### Changed` /
   `### Fixed` sections, and append the version link at the bottom of the file.
2. Bump `VERSION` to `X.Y.Z`.
3. Verify: `make build && make test` (all tests must pass).
4. Commit (e.g. `docs(changelog): …` or as part of the feature commit), push `main`.
5. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
6. CI (`.github/workflows/release.yml`) then: validates tag ↔ `VERSION`, runs the
   full test suite, builds the release, EdDSA-signs the ZIP, generates
   `appcast.xml`, and creates the GitHub Release. Do not create the release
   manually before CI finishes.
7. **Polish the release page** after CI completes:
   - Title → `vX.Y.Z — Short summary`
   - Notes → handwritten English changelog copied from the `CHANGELOG.md` entry
     (replace the auto-generated compare link).

### Release title format

```
vX.Y.Z — Short summary
```

- Em dash `—` (U+2014) with spaces around it; first word of the summary
  capitalized; English; **no product-name prefix**.

Examples (all existing releases follow this):

```
v0.1.7 — Unified panel theme
v0.1.5 — Signed in-app updates
v0.1.2 — Kimi Code CLI support
```

### Release notes format

```markdown
## What's new in vX.Y.Z        (or "What's changed" / "What's fixed")

- **Headline feature** — one or two sentences, user-visible impact first.
- Smaller items as plain bullets.

## Upgrade                      (include when users must act)

Homebrew: `brew upgrade --cask lulu-lumei-dock`
Manual: download `lulu-lumei-dock-X.Y.Z.zip` below, unzip, replace the app in `/Applications`.
```

## After releasing locally

- `make install` rebuilds and replaces `/Applications/lulu-lumei-dock.app`
  (quit the running app first: `pkill -x eureka`).
- Installed builds ≥ 0.1.5 pick up the new version automatically via Sparkle.

## Style & architecture

See `CLAUDE.md` for build commands, module layout, and the critical invariants
(relay constraints, stale-event suppression, usage dedup, dependency scope).
