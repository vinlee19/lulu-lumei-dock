import EurekaIngest
import EurekaKit
import SwiftUI

/// Cross-source config consistency card (top of the audit page).
///
/// This is the thing a "local agent CLI management assistant" should do most and nobody does:
/// 12 CLIs each have their own skills / instructions /
/// memory, and where they don't line up across sources is tracked purely by memory. Only **three
/// kinds of gaps that can be judged automatically and that users really care about** are reported:
///  1. Project instruction files half configured (observed on this machine: one repo with none at
///     all, two each missing one kind)
///  2. A source is missing skills already configured in other sources: **aggregated per source**,
///     not listed per skill
///     (all 25 same-named skills were "present in 5 sources, missing in codex/grok"; listing them
///     one by one would spew 25 rows saying the same thing)
///  3. Memory library index drift (dead memories not listed in MEMORY.md)
///
/// The criteria are all **adaptive**: they reconcile against conventions the user already has,
/// rather than nitpicking against an ideal checklist;
/// otherwise it would report pure noise like "you haven't configured Gemini's instruction file".
/// Rules and thresholds are in `ConsistencyChecker` (unit tested).
struct ConsistencyCard: View {
    @ObservedObject var service: SkillMemoryService
    /// MCP same-name conflicts (one server name defined differently across sources; passed in by
    /// AuditView, empty by default)
    var mcpDrifts: [ConsistencyChecker.MCPDrift] = []

    @State private var expanded = false
    /// Pending "fill in" target (the fill-in button on a skill-gap row was tapped)
    @State private var fixGap: ConsistencyReportAlias.SkillSourceGap?
    /// Fill-in result feedback (shown briefly; the gap rows disappear on their own after the
    /// rescan)
    @State private var fixNote: String?

    var body: some View {
        let report = service.consistencyReport
        let clean = report.isClean && mcpDrifts.isEmpty
        let issueCount = report.issueCount + mcpDrifts.count
        // Take no space until the scan finishes (everything is empty then, so reporting "all good"
        // would be a lie)
        if service.lastScanAt != nil {
            VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
                header(report, clean: clean, issueCount: issueCount)
                if let note = fixNote {
                    Text(note)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, expanded ? 0 : 6)
                }
                if expanded, !clean {
                    Divider().opacity(0.5)
                    details(report)
                }
            }
            .themedConfirm(
                L10n.format(
                    "Install %@ skills onto %@?",
                    zhHans: "把 %@ 个技能安装到 %@？",
                    String(fixGap?.missing.count ?? 0), fixGap?.source.displayName ?? ""),
                isPresented: Binding(
                    get: { fixGap != nil },
                    set: { if !$0 { fixGap = nil } }),
                message: fixGap.map { $0.missing.joined(separator: L10n.text(", ", zhHans: "、")) },
                confirm: L10n.text("Copy these skills over", zhHans: "复制这些技能过去")
            ) { runFix() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .strokeBorder(
                        clean ? Theme.cardBorder : Theme.gold.opacity(0.35),
                        lineWidth: clean ? 0.5 : 0.8))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1.5)
        }
    }

    private func header(
        _ report: ConsistencyReportAlias, clean: Bool, issueCount: Int
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: clean
                ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(Theme.font.themed(13))
                .foregroundStyle(clean ? Theme.enabledGreen : Theme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Configuration consistency", zhHans: "配置一致性")).font(Theme.font.themed(12.5, .semibold))
                Text(summary(report, clean: clean))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !clean {
                Button(expanded ? L10n.text("Collapse", zhHans: "收起") : L10n.format("View %@ items", zhHans: "查看 %@ 项", String(issueCount))) {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(Theme.font.themed(11))
            }
        }
    }

    private func summary(_ report: ConsistencyReportAlias, clean: Bool) -> String {
        guard !clean else {
            return L10n.text(
                "Instruction files, skill coverage, memory-library indexes, and MCP definitions all match",
                zhHans: "指令文件、技能分布、记忆库索引与 MCP 定义都对得上")
        }
        var parts: [String] = []
        if !report.instructionGaps.isEmpty {
            parts.append(L10n.format(
                "%@ repositories have incomplete instruction files",
                zhHans: "%@ 个仓库的指令文件不完整",
                String(report.instructionGaps.count)))
        }
        if !report.skillGaps.isEmpty {
            parts.append(report.skillGaps
                .map {
                    L10n.format(
                        "%1$@ is missing %2$@ skills",
                        zhHans: "%1$@ 缺 %2$@ 个技能",
                        $0.source.displayName, String($0.missing.count))
                }
                .joined(separator: L10n.text(", ", zhHans: "、")))
        }
        if !report.libraryDrifts.isEmpty {
            let total = report.libraryDrifts.reduce(0) { $0 + $1.unindexed }
            parts.append(L10n.format(
                "%@ memories are not in the index",
                zhHans: "%@ 条记忆未被索引收录",
                String(total)))
        }
        if !mcpDrifts.isEmpty {
            parts.append(L10n.format(
                "%@ MCP servers share a name but differ",
                zhHans: "%@ 个 MCP server 同名异义",
                String(mcpDrifts.count)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func details(_ report: ConsistencyReportAlias) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !report.instructionGaps.isEmpty {
                section(L10n.text("Project instruction gaps", zhHans: "项目指令缺口"), hint: L10n.text("Inferred from how your other repositories are set up", zhHans: "按你在其它仓库的习惯推断")) {
                    ForEach(report.instructionGaps) { gap in
                        HStack(spacing: 8) {
                            Text(gap.project)
                                .font(Theme.font.themed(11, .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            ForEach(gap.missing, id: \.self) { TagChip(L10n.format("Missing %@", zhHans: "缺 %@", $0), tint: Theme.gold) }
                            ForEach(gap.present, id: \.self) { TagChip($0, neutral: true) }
                        }
                    }
                }
            }
            if !report.skillGaps.isEmpty {
                section(L10n.text("Cross-source skill gaps", zhHans: "技能跨源缺口"), hint: L10n.text("Configured on other sources, missing on this one", zhHans: "已在其它源配置、这个源没有")) {
                    ForEach(report.skillGaps) { gap in
                        HStack(alignment: .top, spacing: 8) {
                            SourceLogoTile(source: gap.source, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format("%1$@ is missing %2$@", zhHans: "%1$@ 缺 %2$@ 个", gap.source.displayName, String(gap.missing.count)))
                                    .font(Theme.font.themed(11, .medium))
                                Text(gap.missing.prefix(6).joined(separator: L10n.text(", ", zhHans: "、"))
                                    + (gap.missing.count > 6 ? L10n.text(" etc.", zhHans: " 等") : ""))
                                    .font(Theme.font.themed(10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button(L10n.format("Fill in %@", zhHans: "补齐 %@ 个", String(gap.missing.count))) { fixGap = gap }
                                .buttonStyle(.borderless)
                                .font(Theme.font.themed(10.5))
                                .help(L10n.format("Copy these skills from a configured source to %@", zhHans: "把这些技能从已配置的源复制到 %@", gap.source.displayName))
                        }
                    }
                }
            }
            if !mcpDrifts.isEmpty {
                section(L10n.text("MCP names that disagree", zhHans: "MCP 同名异义"), hint: L10n.text("The same server name is defined differently across sources (see the MCP page)", zhHans: "同一 server 名在多源定义冲突（详情见 MCP 页）")) {
                    ForEach(mcpDrifts) { drift in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drift.name)
                                .font(Theme.font.themed(11, .medium))
                            ForEach(drift.variants, id: \.self) { variant in
                                Text(variant)
                                    .font(Theme.font.themed(9.5, .regular))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            if !report.libraryDrifts.isEmpty {
                section(L10n.text("Memory-library index drift", zhHans: "记忆库索引漂移"), hint: L10n.text("Entries left out of the index are invisible to the agent", zhHans: "未收录的条目 agent 读不到")) {
                    ForEach(report.libraryDrifts) { drift in
                        HStack(spacing: 8) {
                            Text(drift.projectName)
                                .font(Theme.font.themed(11, .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if drift.unindexed > 0 {
                                TagChip(L10n.format("%@ not indexed", zhHans: "%@ 条未收录", String(drift.unindexed)), tint: Theme.gold)
                            }
                            if drift.dangling > 0 {
                                TagChip(L10n.format("%@ dangling references", zhHans: "%@ 条空引用", String(drift.dangling)), tint: Theme.failureRed)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Runs "fill in" (after confirmationDialog confirms): batch copy + a single rescan; the result
    /// is shown briefly inside the card
    private func runFix() {
        guard let gap = fixGap else { return }
        fixGap = nil
        let targetName = gap.source.displayName
        fixNote = L10n.format(
            "Installing %@ skills onto %@…",
            zhHans: "正在把 %@ 个技能安装到 %@…",
            String(gap.missing.count), targetName)
        service.propagateAll(names: gap.missing, to: gap.source) { succeeded, failures in
            if failures.isEmpty {
                fixNote = L10n.format(
                    "Installed %@ skills onto %@",
                    zhHans: "已把 %@ 个技能安装到 %@",
                    String(succeeded), targetName)
            } else {
                fixNote = L10n.format(
                    "Install onto %1$@: %2$@ succeeded, %3$@ failed",
                    zhHans: "安装到 %1$@：成功 %2$@ 个、失败 %3$@ 个",
                    targetName, String(succeeded), String(failures.count))
                    + (failures.first.map { L10n.format(" (%@)", zhHans: "（%@）", $0) } ?? "")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { fixNote = nil }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(Theme.font.themed(11, .semibold)).foregroundStyle(.secondary)
                Text(hint).font(Theme.font.themed(9.5)).foregroundStyle(.tertiary)
            }
            content()
        }
    }
}

/// Short alias for `ConsistencyChecker.Report` (the nested type name is too long to read well
/// when written all over the view)
typealias ConsistencyReportAlias = ConsistencyChecker.Report
