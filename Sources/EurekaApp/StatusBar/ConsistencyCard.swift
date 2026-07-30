import EurekaIngest
import EurekaKit
import SwiftUI

/// 跨源配置一致性卡（审计页顶部）。
///
/// 这是「本地 agent CLI 管理助手」最该干、也最没人干的一件事：12 个 CLI 各有一套技能 / 指令 /
/// 记忆，横向对不上账的地方全靠人肉记。这里只报**三类能自动判定、且用户确实在意**的缺口：
///  1. 项目指令文件配了一半（本机实勘：一个仓库完全没配、两个各缺一种）
///  2. 某个源缺了已在其它源配置的技能 —— **按源聚合**，不按技能逐条列
///     （25 个同名技能全都是"5 源有、codex/grok 无"，逐条列会刷出 25 行说同一件事）
///  3. 记忆库索引漂移（未被 MEMORY.md 收录的死记忆）
///
/// 口径都是**自适应**的：拿用户自己已有的约定去对账，不照理想清单挑刺 ——
/// 否则就会报「你没配 Gemini 的指令文件」这类纯噪声。判据与阈值见 `ConsistencyChecker`（有单测）。
struct ConsistencyCard: View {
    @ObservedObject var service: SkillMemoryService

    @State private var expanded = false

    var body: some View {
        let report = service.consistencyReport
        // 还没扫完就不占版面（此时全是空的，报"一切正常"是假的）
        if service.lastScanAt != nil {
            VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
                header(report)
                if expanded, !report.isClean {
                    Divider().opacity(0.5)
                    details(report)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .strokeBorder(
                        report.isClean ? Theme.cardBorder : Theme.gold.opacity(0.35),
                        lineWidth: report.isClean ? 0.5 : 0.8))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1.5)
        }
    }

    private func header(_ report: ConsistencyReportAlias) -> some View {
        HStack(spacing: 8) {
            Image(systemName: report.isClean
                ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(report.isClean ? Theme.enabledGreen : Theme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("配置一致性").font(.system(size: 12.5, weight: .semibold))
                Text(summary(report))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !report.isClean {
                Button(expanded ? "收起" : "查看 \(report.issueCount) 项") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
    }

    private func summary(_ report: ConsistencyReportAlias) -> String {
        guard !report.isClean else { return "指令文件、技能分布与记忆库索引都对得上" }
        var parts: [String] = []
        if !report.instructionGaps.isEmpty {
            parts.append("\(report.instructionGaps.count) 个仓库的指令文件不完整")
        }
        if !report.skillGaps.isEmpty {
            parts.append(report.skillGaps
                .map { "\($0.source.displayName) 缺 \($0.missing.count) 个技能" }
                .joined(separator: "、"))
        }
        if !report.libraryDrifts.isEmpty {
            let total = report.libraryDrifts.reduce(0) { $0 + $1.unindexed }
            parts.append("\(total) 条记忆未被索引收录")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func details(_ report: ConsistencyReportAlias) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !report.instructionGaps.isEmpty {
                section("项目指令缺口", hint: "按你在其它仓库的习惯推断") {
                    ForEach(report.instructionGaps) { gap in
                        HStack(spacing: 8) {
                            Text(gap.project)
                                .font(Theme.font.monoSkillName(11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            ForEach(gap.missing, id: \.self) { TagChip("缺 \($0)", tint: Theme.gold) }
                            ForEach(gap.present, id: \.self) { TagChip($0, neutral: true) }
                        }
                    }
                }
            }
            if !report.skillGaps.isEmpty {
                section("技能跨源缺口", hint: "已在其它源配置、这个源没有") {
                    ForEach(report.skillGaps) { gap in
                        HStack(alignment: .top, spacing: 8) {
                            SourceLogoTile(source: gap.source, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(gap.source.displayName) 缺 \(gap.missing.count) 个")
                                    .font(.system(size: 11, weight: .medium))
                                Text(gap.missing.prefix(6).joined(separator: "、")
                                    + (gap.missing.count > 6 ? " 等" : ""))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            if !report.libraryDrifts.isEmpty {
                section("记忆库索引漂移", hint: "未收录的条目 agent 读不到") {
                    ForEach(report.libraryDrifts) { drift in
                        HStack(spacing: 8) {
                            Text(drift.projectName)
                                .font(Theme.font.monoSkillName(11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if drift.unindexed > 0 {
                                TagChip("\(drift.unindexed) 条未收录", tint: Theme.gold)
                            }
                            if drift.dangling > 0 {
                                TagChip("\(drift.dangling) 条空引用", tint: Theme.failureRed)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(hint).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            content()
        }
    }
}

/// `ConsistencyChecker.Report` 的短别名（嵌套类型名太长，视图里到处写不好读）
typealias ConsistencyReportAlias = ConsistencyChecker.Report
