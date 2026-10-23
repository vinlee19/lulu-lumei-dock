# Knowledge Hub + Skills Split View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the seven knowledge tabs into one sidebar entry with a type switcher on top, and move Skills onto the shared "list + detail" shell; the other six types keep their current pages inside the shell until phase 3.

**Architecture:** `KnowledgeHubView` owns the top bar (type segments with counts, search slot, trailing actions slot) and switches the content area by `navigation.tab`, so every existing deep link (`navigation.tab = .skills`, `focusPath`, ⌘K) keeps working unchanged. Skills renders `SkillsSplitView`: a pure grouping layer in `EurekaIngest` (`SkillGrouping`) feeds a list pane and a `SkillDetailPane`; below 760pt of content width the detail is pushed instead of shown beside the list.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), Swift Charts; hand-rolled test harness (`Tests/EurekaTestsRunner`).

**Spec:** design canvas https://claude.ai/artifact/LowQ8Uh1VrwPcSrbnr7fam (boards 2 "信息架构", 4 "图标与主题规则", 5 "方案 A 样例"); phase split agreed in chat on 2026-10-23.

## Global Constraints

- No new literal colors or fonts: every color is a `Theme.*` token, every font is `Theme.font.*` (phase 1 budget: brand = selection / primary action / progress; green = toggle only; gold = warnings only).
- All nine styles (classic, brutal, seven palettes) must render; brutal gets its structural tokens (`cardBorderWidth`, `cardShadow`, `controlOutline`) through the same calls the existing panes use.
- User-visible strings go through `L10n.text(_:zhHans:)`; English is the source, zhHans the translation. Code comments in English.
- Existing deep links must not change: `navigation.tab = .skills/.memory/...`, `skillMemoryService.focusPath`, `.eurekaRevealKnowledge`, ⌘K results.
- Window minimum stays 840×540 (content ≥ 675pt wide); the Skills page must be usable there.
- `SkillMemoryView(mode: .skills)`, `SkillDetailView`, `Theme.roleColor` stay in the tree (dead code is removed only with the user's say-so, in phase 3).

## Review Focus

- A skill whose copies are split between enabled and disabled (`enabledCount` 0 < n < copies): row shows "n/m", detail status says how many are off — test in Task 1.
- Two copies with the same normalized name but different project scopes (global + project): one row, `projectName == nil`, tag absent — test in Task 1.
- Usage recorded under the directory name rather than the frontmatter name (`plugin:foo` vs `foo`): group still gets the count — test in Task 1.
- `focusPath` pointing at a copy that is not the group's primary: selection lands on the group and the detail shows that copy's file — Task 3 step.
- Content width 675pt (minimum window): list fills the width, tapping a row pushes the detail with a back button — Task 5 render at 675.

---

### Task 1: `SkillGrouping` (pure) + tests

**Files:**
- Create: `Sources/EurekaIngest/SkillGrouping.swift`
- Create: `Tests/EurekaTestsRunner/SkillGroupingTests.swift`
- Modify: `Tests/EurekaTestsRunner/main.swift` (register `skillGroupingTests(t)` after `agentRoleTests(t)`)

**Interfaces (Produces):**
```swift
public struct SkillUsage: Equatable, Sendable { public var count: Int; public var lastTs: Date? }
public struct SkillGroup: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var key: String              // SkillMemoryIndexer.normalizeSkillName(primary.name)
    public var name: String
    public var copies: [SkillEntry]     // enabled first, system scope first, then source order, then path
    public var primary: SkillEntry
    public var sources: [AgentSource]   // distinct, copies order
    public var enabledCount: Int
    public var isAllEnabled: Bool; public var isAllDisabled: Bool
    public var projectName: String?     // non-nil only when every copy is project-scoped to the same project
    public var usageCount: Int; public var lastUsedAt: Date?
    public func contains(path: String) -> Bool
}
public enum SkillSectionKind: Equatable, Sendable { case frequent, enabled, disabled }
public struct SkillSection: Identifiable, Equatable, Sendable { public var id: SkillSectionKind { kind }; kind; groups }
public enum SkillGrouping {
    public static func usageKey(source: AgentSource, name: String) -> String   // "\(source.rawValue):\(normalized)"
    public static func groups(_ skills: [SkillEntry], usage: [String: SkillUsage]) -> [SkillGroup]
    public static func sections(_ groups: [SkillGroup], now: Date, recentWindow: TimeInterval = 30 * 86_400) -> [SkillSection]
}
```
Usage lookup per copy: `usage[usageKey(source, entry.name)] ?? usage[usageKey(source, lastPathComponent(entry.directory))]`; a group sums counts and takes the latest `lastTs`.
Sections: `frequent` = `usageCount > 0 && lastUsedAt >= now - recentWindow && !isAllDisabled`, sorted by count desc then name; `enabled` = the rest with `enabledCount > 0`, name asc; `disabled` = `isAllDisabled`, name asc. Empty sections are dropped.

- [ ] Write the tests (`t.suite("SkillGrouping")`): merge across sources; mixed enabled → `enabledCount` 1 of 2; project tag only when all copies agree; directory-name usage fallback; section order and sorting; empty sections dropped.
- [ ] Run `swift run eureka-tests` → the new suite fails to compile (types missing).
- [ ] Implement `SkillGrouping.swift`.
- [ ] Run `swift run eureka-tests` → all pass.
- [ ] Commit `feat(ingest): group skill copies by normalized name for the list`.

### Task 2: Hub shell + sidebar entry

**Files:**
- Create: `Sources/EurekaApp/StatusBar/KnowledgeHubView.swift`
- Modify: `Sources/EurekaApp/StatusBar/PopoverRootView.swift` (`Tab`: localized titles, `knowledgeTabs`, `isKnowledge`, `sidebarAnchor`; `PopoverNavigation.lastKnowledgeTab`; `sidebarGroups` knowledge group → `[.skills]`; content switch → hub for knowledge tabs)
- Modify: `Sources/EurekaApp/StatusBar/SidebarView.swift` (title/icon for the anchor come from `Tab.sidebarTitle` / `sidebarIcon`; selected when `selected.sidebarAnchor == tab`)

**Interfaces:**
```swift
extension PopoverRootView.Tab {
    static let knowledgeTabs: [Tab] = [.skills, .memory, .instructions, .plans, .agents, .mcp, .prompts]
    var isKnowledge: Bool
    var sidebarAnchor: Tab          // knowledge tabs → .skills, others → self
    var sidebarTitle: String        // .skills → L10n "Knowledge"/"知识库"; others → title
    var sidebarIcon: String         // .skills → "books.vertical.fill"; others → icon
}
struct KnowledgeHubView: View {
    @ObservedObject var navigation: PopoverNavigation
    // services: skillMemoryService, usageService, sessionBrowser, plansService, promptsService, agentConfigService, mcpService
}
```
Top bar: `KnowledgeTypeSegments` (icon 14pt + localized title + count in `themedMono`), selected = `navigation.tab`; for `.skills` the bar also shows `SearchField` bound to `skillMemoryService.searchText` (width 150–220) and `SkillsToolbarActions` (new-skill menu + rescan). Content: `.skills` → `SkillsSplitView` (Task 3); every other knowledge tab → the exact view PopoverRootView renders today.
Sidebar: clicking the anchor sets `navigation.tab = navigation.lastKnowledgeTab`; whenever `navigation.tab.isKnowledge`, `lastKnowledgeTab` is updated (`onChange` in PopoverRootView).

- [ ] Add the `Tab` helpers and `lastKnowledgeTab`; update `sidebarGroups`.
- [ ] Update `SidebarView` to use `sidebarTitle` / `sidebarIcon` / anchor selection.
- [ ] Write `KnowledgeHubView` with the segments and a placeholder content switch that renders today's views for all seven tabs.
- [ ] Wire `PopoverRootView.content`: `case t where t.isKnowledge: KnowledgeHubView(...)`.
- [ ] `swift build`; `swift run eureka --render-shell /tmp/x` → sidebar shows 7 entries with 知识库 selected when tab is a knowledge tab.
- [ ] Commit `feat(ui): fold the knowledge tabs into one hub with a type switcher`.

### Task 3: Skills split view (list pane)

**Files:**
- Create: `Sources/EurekaApp/StatusBar/SkillsSplitView.swift` (`SkillsSplitView`, `SkillGroupRow`, `SkillSourceFilter`, `SkillsToolbarActions`)
- Modify: `Sources/EurekaApp/StatusBar/KnowledgeHubView.swift` (render it for `.skills`)

**Interfaces:**
```swift
struct SkillsSplitView: View {
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    var sessionBrowser: SessionBrowserService? = nil
    var initialSelectionKey: String? = nil     // renderer only
    var initialPushDetail: Bool = false        // renderer only (narrow mode)
}
struct SkillsToolbarActions: View { @ObservedObject var service: SkillMemoryService }  // "+ New skill" menu with the create alert, "Rescan"
```
State: `selectedKey: String?`, `selectedSource: AgentSource?`, `detailPushed: Bool`, `deleting: SkillEntry?`. Derived: `groups = SkillGrouping.groups(service.skills filtered by selectedSource, usage: usageService.skillStats → [key: SkillUsage])`, `sections = SkillGrouping.sections(groups, now: Date())`.
Layout: `GeometryReader`; `wide = width >= 760`. Wide: `HStack(spacing: 12)` with list pane `width: 396` and detail pane `frame(maxWidth: .infinity)`, both `KnowledgePane` (surface + `Theme.cardBorder` / `cardBorderWidth` / `cardShadow`, radius `Theme.radius.card`). Narrow: list only; `detailPushed` shows the detail pane with a back button in its header.
List pane: header (count sentence "N skills · M enabled · K installed in several tools" / zhHans "N 个技能 · M 个已启用 · K 个装在多个工具里", then `SkillSourceFilter` = "All" chip + one chip per source with logo + count, sorted by count desc), rows in a `ScrollViewReader` (`scrollTo(selectedKey)` on change), section header per `SkillSection` ("Frequently used"/"常用", "Enabled"/"已启用", "Disabled"/"已停用" + count), footer (`ScanStatusLabel` + `RefreshButton`).
Row: `SourceLogoTile(primary.source, 28)` with a second `SourceBadge` (16pt, bottom-trailing) when `sources.count > 1`; name `Theme.font.themed(12.5, .medium)`; meta `Theme.font.themed(10.5)` in `Theme.textSecondary`: `"<Claude Code | N tools> · used N times · <relative last>"`; `TagChip(projectName, neutral: true)` when set; trailing: `MiniSwitch` when `copies.count == 1` else `Text("\(enabledCount)/\(copies.count)")` in `themedMono(11)` `textTertiary`. Selected row background `Theme.brandFill(0.14)` (brutal: `Theme.brand` fill + `controlOutline`), radius `Theme.radius.container`. Disabled group dims name/meta/tile to 0.55.
Selection: default = first group of the first section; `consumeFocus()` on `service.focusPath` / `lastScanAt`: find the group with `contains(path:)`, select it, remember `focusedCopyPath` so the detail opens that copy; in narrow mode also set `detailPushed = true`. Keyboard: `.focusable()` + `.onMoveCommand` ↑/↓ over the flattened group order.
- [ ] Build `SkillsToolbarActions` (move the 14-source create menu + alert here; label "New skill" with a plus icon, `.btn.pri` look = `Theme.brand` fill, `Theme.onBrand` text).
- [ ] Build the list pane with a placeholder detail ("Select a skill").
- [ ] `swift build`; render via Task 5's snapshot (or `--render-knowledge`) to check 780 / 1270.
- [ ] Commit `feat(ui): skills list pane with grouped copies and source filter`.

### Task 4: Skill detail pane

**Files:**
- Create: `Sources/EurekaApp/StatusBar/SkillDetailPane.swift`
- Modify: `Sources/EurekaApp/StatusBar/SkillsSplitView.swift` (replace the placeholder)

**Interfaces:**
```swift
struct SkillDetailPane: View {
    let group: SkillGroup
    var focusedCopyPath: String? = nil     // which copy's SKILL.md to show; default primary
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    var sessionBrowser: SessionBrowserService? = nil
    var onBack: (() -> Void)? = nil        // narrow mode only → shows "‹ Back"
    let onDelete: (SkillEntry) -> Void
}
```
Sections top to bottom (each `VStack` separated by `Divider().overlay(Theme.hairline)`):
1. Header: `SourceLogoTile(size: 40)`, name `themed(17, .semibold)`, scope line `textSecondary`: single copy → "Claude Code · global · available in every project" / project → "Claude Code · only in <project>"; multi → "Installed in N tools · <scope summary>".
2. Status: `StatusDot`-style 8pt dot (`enabledGreen` / `textTertiary`) + sentence: all on → "Enabled · <tool> uses it automatically when relevant"; all off → "Disabled · <tool> no longer reads it, the files stay"; mixed → "<n> of <m> copies enabled · each copy has its own switch below".
3. Actions (`HStack`, wrap with `FlowLayout`): **Open SKILL.md** (primary: `Theme.brand` fill / `onBrand`) → `service.openInEditor(path:)`; **Show in Finder** → `service.reveal`; **Install to other tools ▾** (`Menu` of sources not in `service.configurations(forName:)`, confirm dialog → `service.propagate(copy, to: [source])`); **Disable/Enable** (single copy) → `service.setSkillEnabled`; **Delete…** quiet → `onDelete(copy)`.
4. "What it does": full description, then hint "<tool> decides when to use it from this description." in `textTertiary`.
5. "Full text (SKILL.md)" with `"<lines> lines · <size>"` and **Edit here** button: collapsed `MarkdownRichText` clipped at 300pt with a bottom fade (`LinearGradient(Theme.surface.opacity(0)…Theme.surface)`; brutal: dashed `Theme.hairline` rule instead), **Show all** toggles; editing swaps in `TextEditor` (`Theme.font.code(12)`) + Save / Cancel via `service.save(path:content:)`.
6. "Usage": sentence from `usageService.skillStats` (count, last, weekly rank via `loadSkillWeeklyRank`), 30-day `Chart` (`BarMark`, `Theme.brand`, axis labels "30 days ago" / "today"), recent sessions rows (reuse the logic of `SkillDetailView.recentSessionRow`: tappable when `sessionBrowser.sessionsById` has it, posts `.eurekaRevealSession`).
7. "Installed in": one row per copy: `SourceBadge 16`, path in `Theme.font.code(11)` (middle truncation), scope text, `MiniSwitch`; then "Can also be installed to" + ghost `SourceLogoTile`s at 0.45 opacity for unconfigured sources + the same install menu.
8. "File": location / contains (SKILL.md + sibling count) / size / modified via `FileManager` on the focused copy.
Loads on appear / on `group.key` change (`.id(group.key)`): `loadSkillDailySeries`, `loadSkillWeeklyRank`, `loadSkillSessions`, `readContent`.
- [ ] Build the pane; wire into `SkillsSplitView`; delete confirmation stays in `SkillsSplitView` (moves file to Trash via `service.deleteSkill`).
- [ ] `swift build`; render.
- [ ] Commit `feat(ui): skill detail pane with usage, copies and inline editing`.

### Task 5: Renderer snapshots, narrow mode, archive

**Files:**
- Modify: `Sources/EurekaApp/PreviewRenderer.swift` (`renderKnowledge`: replace the four `knowledge-skills-*` snaps with `knowledge-skills` (780, narrow list), `knowledge-skills-detail` (780, pushed), `knowledge-skills-wide` (1270, split), `knowledge-skills-wide-dark`, `knowledge-skills-search`; add `knowledge-hub-shell` at 1270 showing sidebar + hub via `PopoverRootView`-free composition if cheap, else skip)
- Modify: `Sources/EurekaApp/StatusBar/SkillsSplitView.swift` (narrow push/back, keyboard)
- `design-shots/feat-knowledge-hub-skills/2026-10-23/` (classic / brutal / one palette, README, index)

- [ ] Add the snapshots; `swift run eureka --render-knowledge <dir>` for classic, brutal, nord.
- [ ] Walk the renders against board 5 of the canvas; fix spacing / truncation.
- [ ] `swift run eureka-tests` all green; `make app` → `dist/lulu-lumei-dock.app` for the user to try. **No push, no PR until the user approves.**
- [ ] Commit `chore(ui): snapshot the skills split view in --render-knowledge`.
