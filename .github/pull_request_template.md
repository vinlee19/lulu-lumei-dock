<!--
Title: <type>(<scope>): <imperative summary>  — English, lowercase, no period, ≤ 72 chars.
The title becomes the squash commit on main. Use GitHub's draft state instead of "WIP".
Keep every section below; write N/A instead of deleting one. See CONTRIBUTING.md.
-->

## Summary

<!-- Draft PRs: start with "Status: …" — what works, what is missing, what feedback you want. -->
<!-- What changed, in 1–3 sentences. User-visible effect first. -->

## Motivation

<!-- Why this change? Link the issue or proposal: Closes #, Fixes #, Implements #, Depends on # -->

## Changes

<!-- Bullets grouped by module, e.g. EurekaIngest / EurekaUsage / EurekaApp / eureka-relay / docs -->
-

## Verification

<!-- Paste the exact commands and their result. Add area checks that apply:
     usage → Scripts/check-usage-against-ccusage.sh   island → make demo / --render-previews
     UI → --render-pages / --render-shell screenshots (light + dark)   hooks → --hooks-status -->
- [ ] `make build`
- [ ] `make test` — `N passed, 0 failed`
- [ ] `make lint-comments`
- Manual checks:

## Screenshots

<!-- Required for UI changes: before / after, light and dark. Redact personal data. Otherwise N/A. -->

## Risk & rollback

<!-- Critical invariants touched (CLAUDE.md), persisted data / schema / spool impact,
     config files written, migration, and how to revert. "Low — docs only" is fine. -->

## Checklist

- [ ] One logical change; no unrelated refactors mixed in
- [ ] Title follows Conventional Commits and works as the squash commit message
- [ ] Tests added or updated for every behaviour change
- [ ] Code comments are English; new UI strings go through `L10n` with a `zhHans` translation
- [ ] No new dependency, or an accepted proposal is linked
- [ ] No secrets, tokens, or personal data in code, logs, fixtures, or screenshots
- [ ] Docs updated (`README*`, `CLAUDE.md`, `docs/`) where behaviour or commands changed
- [ ] `CHANGELOG.md` `[Unreleased]` entry added for user-visible changes (or N/A)
