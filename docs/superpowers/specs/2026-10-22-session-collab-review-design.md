# Session collaboration review — design

Date: 2026-10-22 · Branch: `feat/summary-collab-review` (on top of `fix/summary-executor-picker`)

## Intent

The AI Summary tab currently produces a handoff document about *the session*. The person who ran
the session wants something else: what **they** got out of working with the AI — what they
learned, which design calls they made and why, and how they chose when the AI offered options.
What each person wants to know differs, which is why the template must be selectable and
editable; untouched, a default template applies.

Reading the review is not the end: the things worth keeping should be confirmed one by one on the
spot and saved where they will be found again (and where the AI will see them next time).
Human-AI collaboration is the point: the AI proposes, the person decides.

## Goals

1. **Templates.** Built-in templates plus user templates, selectable per run, editable. The default
   is *My collaboration review*. The previous template stays as *Handoff*; a short *Brief* is added.
2. **A review page, not a log.** The result reads as a designed report: a TL;DR first, the
   person's choices as decision cards, learnings and design decisions as cards, how the approach
   evolved as a timeline, risks set apart, generation details pushed to a footer.
3. **Keep what matters, confirmed per item.** The review lists candidates (memories and rules for
   the AI); each can be edited, saved into the project's Claude memory library with a link back to
   the session, or dismissed. The state is remembered per run.
4. **Facts in the prompt.** The prompt header carries the session's objective numbers (prompts,
   tokens, cost, duration) so the model can ground statements about effort.
5. **Sessions open on the latest session.** Entering the Sessions tab selects the most recent user
   session; with no sessions at all, no detail pane is shown.
6. Executor rows show the version as small text, not as part of the name.

## Non-goals (this round)

- Grok as an executor (deferred: no ephemeral mode; isolation unverified).
- Skill repair loop (fix brief → new session → versioned skill) and dataset export / fine-tuning.
- An inbox that collects candidates across sessions (the person chose per-item confirmation).

## Anti-goals

- Inventing reasons: when the transcript does not say why a choice was made, the review says
  "reason not stated" instead of supplying a plausible one.
- Writing anything into memory without an explicit click.
- Decorating with colors and tags to look busy; hierarchy, spacing and a few purposeful
  components carry the design (lesson from the knowledge-page review).
- Letting templates weaken the safety rules (transcript is data, citations must exist, no
  invented files / commands / results).

## Decided

- **Template model.** A template is a name, a one-line description, an ordered list of sections
  (heading + what to write there) and free-text focus instructions. The safety rules and the
  part / merge pipeline are fixed and not editable. Built-ins can't be edited in place; "Edit"
  makes a copy. User templates live in `~/Library/Application Support/Eureka/summary-templates.json`;
  the selected template id is a preference.
- **Default template sections** (headings stay English so parsing is stable; the UI shows
  localized titles for built-in headings): `TL;DR`, `What I learned`, `My design decisions`,
  `My choices on AI proposals`, `How the approach evolved`, `Open questions and risks`,
  `Worth keeping`. Written in the first person from the user's point of view.
- **Parseable items.** Choices use
  `- **AI proposed:** … → **I chose:** … — **Why:** … [#n]`; candidates use
  `- **Memory** | title | content [#n]` or `- **Rule** | title | content [#n]`. The UI falls back
  to plain Markdown for anything that doesn't parse, so custom templates always render.
- **Runs record the template.** `summary_runs` gains `template_id`, `template_name` and
  `candidate_state` (JSON) via idempotent `ADD COLUMN`; it stays a fact table.
- **Saving a candidate** writes `<slug>.md` into `~/.claude/projects/<encoded cwd>/memory/` with
  Claude's frontmatter (`name`, `description`, `metadata.type` = `project` for Memory,
  `feedback` for Rule, `originSessionId`), and appends a pointer line to `MEMORY.md` (created when
  missing). Existing files are never overwritten (a numeric suffix is added). Sessions without a
  working directory can only copy.

## Builder's calls (made by me, open to change)

- Template switcher sits in the summary pane toolbar as a chip; the executor split button stays
  in the detail header.
- Template editor is a sheet with section rows (heading, guidance, move up/down, delete).
- Template version constant bumps to 2 (prompt shape changed).
- Most recent session = newest `lastActiveAt` among visible sessions, skipping folded harness
  utility prompts.
