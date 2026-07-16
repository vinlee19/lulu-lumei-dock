import EurekaInstall
import EurekaKit
import EurekaStore
import SwiftUI

/// 「审计」页签：agent 操作安全审计流水。筛选（来源/类型/仅风险/关键词）+ 分页 + 展开全文 + 导出 CSV。
struct AuditView: View {
    @ObservedObject var service: AuditService
    @ObservedObject var installer: InstallerService

    @State private var sourceFilter: AgentSource?
    @State private var kindFilter: ToolKind?
    @State private var riskOnly = false
    @State private var keyword = ""
    @State private var page = 1
    @State private var expanded: Set<String> = []
    @State private var showExportConfirm = false
    @State private var showClearConfirm = false

    private let pageSize = 100

    /// 规则 id → 中文标题（徽标展示；只存了 id，标题从内置规则查）
    private static let ruleTitles: [String: String] = Dictionary(
        RiskRuleEngine.builtinRules.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })

    private var query: AuditRepo.Query {
        AuditRepo.Query(
            source: sourceFilter, kind: kindFilter, riskOnly: riskOnly,
            keyword: keyword.trimmingCharacters(in: .whitespaces).isEmpty ? nil : keyword)
    }

    private var totalPages: Int {
        max(1, (service.total + pageSize - 1) / pageSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if installer.claudeStatus != .installed {
                hooksHint
            }
            if service.events.isEmpty {
                emptyState
            } else {
                list
                Divider()
                footer
            }
        }
        .onAppear {
            installer.refresh()
            reload()
        }
        .onChange(of: sourceFilter) { _, _ in resetAndReload() }
        .onChange(of: kindFilter) { _, _ in resetAndReload() }
        .onChange(of: riskOnly) { _, _ in resetAndReload() }
        .onChange(of: keyword) { _, _ in resetAndReload() }
        .confirmationDialog(
            "导出的 CSV 含完整命令文本（可能包含敏感信息），确认导出到下载目录？",
            isPresented: $showExportConfirm, titleVisibility: .visible
        ) {
            Button("导出") { service.exportCSV(query: query) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "确认清空全部审计数据？此操作不可撤销。",
            isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { service.clearAll() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 筛选条

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $sourceFilter) {
                    Text("全部来源").tag(AgentSource?.none)
                    Text("Claude").tag(AgentSource?.some(.claude))
                    Text("Codex").tag(AgentSource?.some(.codex))
                }
                .labelsHidden()
                .frame(width: 110)

                Picker("", selection: $kindFilter) {
                    Text("全部类型").tag(ToolKind?.none)
                    ForEach(ToolKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(ToolKind?.some(kind))
                    }
                }
                .labelsHidden()
                .frame(width: 100)

                Toggle("仅风险", isOn: $riskOnly)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索命令 / 文件路径 / 工具名", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button {
                    showExportConfirm = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .controlSize(.small)
                .help("导出当前筛选结果为 CSV")
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("清空全部审计数据")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - hooks 未装提示

    private var hooksHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Claude hooks 未安装，Claude 的操作暂未被审计采集（Codex 不受影响）。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("安装") { installer.installAll() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(service.events, id: \.opId) { event in
                    row(event)
                    Divider().opacity(0.3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func row(_ event: AuditEvent) -> some View {
        let isExpanded = expanded.contains(event.opId)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(event.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                sourceBadge(event.source)
                Text(event.kind.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(event.tool)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                if let level = event.riskLevel {
                    riskBadge(level: level, rule: event.riskRule)
                }
                if event.isError {
                    Text("失败\(event.exitCode.map { "(\($0))" } ?? "")")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            if !event.detail.isEmpty {
                Text(isExpanded ? event.detail : firstLine(event.detail))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(event.opId) } else { expanded.insert(event.opId) }
        }
    }

    // MARK: - 分页脚

    private var footer: some View {
        HStack(spacing: 8) {
            Text("共 \(service.total) 条")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            if service.riskTotal > 0 {
                Text("· 风险 \(service.riskTotal)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.audit)
            }
            if let msg = service.exportMessage {
                Text(msg)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                page = max(1, page - 1)
                reload()
            } label: { Image(systemName: "chevron.left").font(.system(size: 9)) }
            .buttonStyle(.borderless)
            .disabled(page <= 1)
            Text("\(page) / \(totalPages)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                page = min(totalPages, page + 1)
                reload()
            } label: { Image(systemName: "chevron.right").font(.system(size: 9)) }
            .buttonStyle(.borderless)
            .disabled(page >= totalPages)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34))
                .foregroundStyle(Theme.audit.opacity(0.5))
            Text(riskOnly || !keyword.isEmpty || sourceFilter != nil || kindFilter != nil
                ? "当前筛选无匹配记录"
                : "暂无审计记录。agent 执行命令 / 读写文件后会出现在这里。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("记录命令全文与文件路径，不含任何执行输出内容")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - 助手

    private func reload() {
        service.load(query: query, page: page, pageSize: pageSize)
    }

    private func resetAndReload() {
        page = 1
        reload()
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    private func sourceBadge(_ source: AgentSource) -> some View {
        Text(source == .claude ? "Claude" : source.displayName)
            .font(.system(size: 8.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((source == .claude ? Color.orange : Color.cyan).opacity(0.15)))
            .foregroundStyle(source == .claude ? Color.orange : Color.cyan)
    }

    private func riskBadge(level: RiskLevel, rule: String?) -> some View {
        let color: Color = level == .high ? .red : .orange
        let title = rule.flatMap { Self.ruleTitles[$0] } ?? level.label
        return Text(title)
            .font(.system(size: 8.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}
