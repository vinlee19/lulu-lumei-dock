import EurekaInstall
import EurekaKit
import EurekaStore
import SwiftUI

/// 「审计」页签：agent 操作安全审计流水。筛选（来源/类型/仅风险/关键词）+ 分页 + 展开全文 + 导出 CSV。
///
/// 骨架与 Skills/Memory/Plans/Agents 四页刻意同构（`PlansView.content` 是样板）：
/// `header + Divider + ScrollView{ 总览卡 / 来源 chips / 类型 chips / 列表容器 }.background(surfaceSecondary)`。
/// 此前这一页 `Styles.swift` 的复用组件一个都没用：手抄了空态与搜索框，来源徽标是
/// `Color.orange`/`Color.cyan` 的纯文字胶囊而不是真的 `SourceBadge`，来源筛选还是硬编码
/// 的 `Picker` —— 12 个来源里只列了 7 个，那是功能缺失不只是观感问题。
///
/// ⚠️ 本页从「设置 → 审计」升为顶级页签，**不再继承**设置子树注入的
/// `.toggleStyle(.switch)` / `.controlSize(.small)` / `.font(11.5)`，
/// 所以设置浮层必须自己声明这三样，否则控件尺寸与字号会突变。
struct AuditView: View {
    @ObservedObject var service: AuditService
    @ObservedObject var installer: InstallerService
    /// 采集/告警/保留时长四个开关原在「设置 → 审计」的卡里，现收进页头齿轮浮层
    @ObservedObject var settings: AppSettings
    /// 只为「系统通知不可用」的降级提示（开发态 / 权限被拒）
    @ObservedObject var notificationService: NotificationService
    /// 跨源配置一致性卡的数据源（技能 / 指令 / 记忆库都在它手上）
    @ObservedObject var skillMemory: SkillMemoryService

    @State private var sourceFilter: AgentSource?
    @State private var kindFilter: ToolKind?
    @State private var riskOnly = false
    @State private var keyword = ""
    @State private var page = 1
    @State private var pageInput = ""
    @State private var expanded: Set<String> = []
    @State private var showSettings = false
    @State private var showExportConfirm = false
    @State private var showClearConfirm = false

    private let pageSize = 100

    /// 离屏渲染/预览专用：指定初始筛选（交互时由 chips / 搜索框改）。
    /// 照 `PlansView(initialLayout:)` 的做法 —— 空态与「仅风险」态否则没法自动出图核对。
    init(
        service: AuditService, installer: InstallerService, settings: AppSettings,
        notificationService: NotificationService, skillMemory: SkillMemoryService,
        initialRiskOnly: Bool = false, initialKeyword: String = ""
    ) {
        self._service = ObservedObject(wrappedValue: service)
        self._installer = ObservedObject(wrappedValue: installer)
        self._settings = ObservedObject(wrappedValue: settings)
        self._notificationService = ObservedObject(wrappedValue: notificationService)
        self._skillMemory = ObservedObject(wrappedValue: skillMemory)
        self._riskOnly = State(initialValue: initialRiskOnly)
        self._keyword = State(initialValue: initialKeyword)
    }

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

    private var filtering: Bool {
        sourceFilter != nil || kindFilter != nil || riskOnly
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            installer.refresh()
            notificationService.refresh()
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

    // MARK: - 页头（标题 15/bold + 搜索 + 齿轮 / 导出 / 清空 / 刷新）

    private var header: some View {
        HStack(spacing: 12) {
            Text("审计").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: "搜索命令 / 文件路径 / 工具名",
                text: $keyword, resultCount: service.total)
            Spacer(minLength: 12)
            if let message = service.exportMessage {
                Text(message)
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            CardActionButton(icon: "gearshape", help: "采集与保留策略") {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
            CardActionButton(icon: "square.and.arrow.up", help: "导出当前筛选结果为 CSV") {
                showExportConfirm = true
            }
            CardActionButton(icon: "trash", color: Theme.failureRed, help: "清空全部审计数据") {
                showClearConfirm = true
            }
            RefreshButton(help: "重新读取审计流水") { reload() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 采集开关与保留策略。用 popover 而不是 `Menu`：这里有三段必须保留的说明文字
    /// （隐私口径 / 启发式免责 / 通知降级），NSMenu 的条目会把长文本截断。
    ///
    /// 非 private 是为了给 `PreviewRenderer` 单独出图 —— popover 依赖真实窗口，
    /// 离屏渲染整页时它不会被光栅化，只能单独渲这个内容视图才能核对排版。
    var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("记录 agent 操作审计流水", isOn: $settings.auditEnabled)
            Text("记录 agent 执行的完整命令与读写的文件路径，用于事后回溯；"
                + "不记录任何执行输出内容。命令文本本就明文存于本地会话记录中。")
                .font(Theme.font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.auditEnabled {
                Divider()
                Toggle("高危操作岛内红卡告警", isOn: $settings.auditRiskAlertsEnabled)
                Toggle("高危操作系统通知（锁屏 / 其他桌面可见）", isOn: $settings.auditSystemNotifyEnabled)
                if let hint = notificationHint, settings.auditSystemNotifyEnabled {
                    Text(hint)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.goldFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("保留时长")
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.auditRetentionDays) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("180 天").tag(180)
                        Text("365 天").tag(365)
                        Text("永久").tag(0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                }
                Text("高危规则为启发式提示（sudo / rm -rf 绝对路径 / 管道执行下载脚本 / 读写密钥等），"
                    + "非沙箱拦截；命中会去重节流。")
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 顶级页签不继承设置子树的样式注入，这三行必须自己声明
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11.5))
        .padding(Theme.spacing.card)
        .frame(width: 320)
    }

    /// 系统通知降级提示：反映真实授权状态（开发态不可用 / 被拒 / 正常）
    private var notificationHint: String? {
        switch notificationService.availability {
        case .unavailableNotBundled:
            return "当前为开发模式（swift run）运行，系统通知不可用，仅岛内红卡告警；安装为 .app 后生效。"
        case .denied:
            return "系统通知权限已被拒绝，仅岛内红卡告警。可在 系统设置 > 通知 > lulu-lumei-dock 中开启。"
        case .authorized, .unknown:
            return nil
        }
    }

    // MARK: - 主体

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                // 配置一致性：与审计流水同页，因为两者回答的是同一类问题
                // 「我这一堆 CLI 的配置到底是什么状态」。它不需要审计开关，也不受筛选影响。
                ConsistencyCard(service: skillMemory)
                sourceBar
                kindBar
                if !settings.auditEnabled {
                    captureOffHint
                } else if installer.claudeStatus != .installed {
                    hooksHint
                }
                // 读库失败以前只发布不渲染 —— 出错时整页静默空白，无从判断
                if let error = service.lastError {
                    noticeCard(
                        icon: "exclamationmark.octagon.fill", tint: Theme.failureRed,
                        text: error)
                }
                if service.events.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: filtering ? "当前筛选无匹配记录" : "暂无审计记录",
                        hint: filtering
                            ? "换个来源 / 类型，或清空关键词"
                            : "agent 执行命令、读写文件后会出现在这里；只记录命令全文与文件路径，不含执行输出")
                        .padding(.top, 40)
                } else {
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(service.events.enumerated()), id: \.element.opId) {
                                index, event in
                                row(event)
                                if index < service.events.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 50)
                                }
                            }
                            Divider().opacity(0.4)
                            paginationBar
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    // MARK: - 总览卡

    private var statsCard: some View {
        StatOverviewCard(
            value: "\(service.total)",
            unit: "审计事件",
            subtitle: subtitle,
            distributionTitle: "类型分布",
            segments: kindSegments,
            trailingNote: filtering ? "已筛选" : nil)
    }

    private var subtitle: String {
        let retention = settings.auditRetentionDays == 0
            ? "永久保留" : "保留 \(settings.auditRetentionDays) 天"
        // `riskTotal` 是**全库**风险数（不跟筛选走），筛选态下与旁边的大数不同基准，
        // 摆在一起会读成「0 条里有 123 条风险」→ 筛选时只留保留策略，风险数交给「仅风险」chip。
        guard service.riskTotal > 0, !filtering else { return retention }
        return "风险 \(service.riskTotal) · \(retention)"
    }

    /// 类型分布：前 4 名 + 「其他」，同 `AgentsView.modelSegments` 的做法与配色阶梯。
    /// **必须收口**：`ToolKind` 有 9 个 case，9 条图例在 780pt 最小内容宽下会把
    /// 「命令」「16,911」都竖着折成一列字。全部 9 类的精确条数由下方类型 chips 承担。
    private var kindSegments: [StatOverviewCard.Segment] {
        let shades: [Double] = [1.0, 0.78, 0.6, 0.45]
        var segments: [StatOverviewCard.Segment] = []
        var other = 0
        for (index, entry) in sortedKinds.enumerated() {
            if index < shades.count {
                segments.append(.init(label: entry.key.label, count: entry.value,
                                      color: Theme.brand.opacity(shades[index])))
            } else {
                other += entry.value
            }
        }
        if other > 0 {
            segments.append(.init(label: "其他", count: other, color: Theme.brand.opacity(0.3)))
        }
        return segments
    }

    /// 有数据的类型，多者在前（chips 与分布共用同一排序）
    private var sortedKinds: [(key: ToolKind, value: Int)] {
        service.kindCounts.filter { $0.value > 0 }
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .map { (key: $0.key, value: $0.value) }
    }

    // MARK: - 筛选

    /// 来源筛选：换成 `SourceFilterBar`，自动覆盖**所有有数据的**来源
    /// （旧的硬编码 `Picker` 漏了 opencode/antigravity/kimi/gemini/hermes）
    private var sourceBar: some View {
        SourceFilterBar(
            selected: $sourceFilter,
            allLabel: "全部", allIcon: "checkmark.shield",
            totalCount: service.sourceCounts.values.reduce(0, +),
            sources: service.sourceCounts.filter { $0.value > 0 }
                .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
                .map(\.key),
            count: { service.sourceCounts[$0] ?? 0 })
    }

    /// 类型 chips + 仅风险（换行流式，同 `SourceFilterBar` 的视觉语言、小一号）
    private var kindBar: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            kindChip(nil, label: "全部类型", icon: "square.grid.2x2",
                     count: service.kindCounts.values.reduce(0, +))
            ForEach(sortedKinds, id: \.key) { entry in
                kindChip(entry.key, label: entry.key.label, icon: entry.key.icon,
                         count: entry.value)
            }
            riskChip
        }
    }

    private func kindChip(
        _ kind: ToolKind?, label: String, icon: String, count: Int
    ) -> some View {
        let isSelected = kindFilter == kind
        return Button {
            kindFilter = (kind != nil && kindFilter == kind) ? nil : kind
        } label: {
            chipLabel(
                icon: icon, label: label, count: count,
                isSelected: isSelected, tint: Theme.brand)
        }
        .buttonStyle(.plain)
    }

    private var riskChip: some View {
        Button { riskOnly.toggle() } label: {
            chipLabel(
                icon: "exclamationmark.shield.fill", label: "仅风险",
                count: service.riskTotal, isSelected: riskOnly, tint: Theme.failureRed)
        }
        .buttonStyle(.plain)
        .help("只看命中高危 / 提醒规则的操作")
    }

    private func chipLabel(
        icon: String, label: String, count: Int, isSelected: Bool, tint: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(label).font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85))
                                            : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.surface)))
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.clear : Theme.cardBorder, lineWidth: 0.8))
        .contentShape(Capsule())
    }

    // MARK: - 提示卡（采集关闭 / hooks 未装 / 读库失败共用一套圆角卡）

    private var captureOffHint: some View {
        noticeCard(
            icon: "pause.circle.fill", tint: Theme.gold,
            text: "审计采集已关闭，不会再记录新操作（下方仍是已入库的历史）。"
        ) {
            Button("开启") { settings.auditEnabled = true }
                .controlSize(.small)
        }
    }

    /// Claude hooks 未装提示。原先是一块全幅无圆角的 `Color.orange.opacity(0.08)` 矩形，
    /// 全 app 没有第二处这么做的。
    private var hooksHint: some View {
        noticeCard(
            icon: "exclamationmark.triangle.fill", tint: Theme.gold,
            text: "Claude hooks 未安装，Claude 的操作暂未被审计采集"
                + "（Codex / CodeBuddy / Qoder / Cursor / Grok / Qwen 不受影响）。",
            // 装卸结果必须回显：否则被拒（配置解析不了 / 路径被手改）时毫无反馈
            detail: installer.message
        ) {
            // 只装 Claude hooks。绝不能调 installAll() —— 那会连带写
            // ~/.codex/config.toml，给只用 Claude 的人凭空造出另一个 agent 的配置文件。
            Button("安装") { installer.install(.claudeHooks) }
                .controlSize(.small)
        }
    }

    private func noticeCard<Action: View>(
        icon: String, tint: Color, text: String, detail: String? = nil,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Theme.font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - 行（KnowledgeRow：悬停品牌底 + 3pt 左缘条 + 右键菜单，与四大知识页同构）

    @ViewBuilder
    private func row(_ event: AuditEvent) -> some View {
        let isExpanded = expanded.contains(event.opId)
        KnowledgeRow(onOpen: { toggle(event.opId) }) {
            HStack(alignment: .top, spacing: 10) {
                kindTile(event.kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.tool)
                            .font(Theme.font.monoSkillName(12, weight: .semibold))
                            .lineLimit(1)
                        SourceBadge(source: event.source, size: 12)
                        if let level = event.riskLevel {
                            TagChip(
                                event.riskRule.flatMap { Self.ruleTitles[$0] } ?? level.label,
                                tint: Theme.riskColor(level))
                        }
                        if event.isError {
                            TagChip(
                                event.exitCode.map { "退出码 \($0)" } ?? "失败",
                                tint: Theme.failureRed)
                        }
                        // cwd 一直存着却从不展示，白放着
                        if let project = projectName(event.cwd) {
                            TagChip(project, neutral: true)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(isExpanded ? event.detail : firstLine(event.detail))
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        // 展开态必须锁竖向固有高度，否则多行命令会被压回一行（旧版也有这行）
                        .fixedSize(horizontal: false, vertical: isExpanded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(event.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        } menu: {
            Button(isExpanded ? "收起" : "展开全文") { toggle(event.opId) }
            Button("复制参数全文") { copy(event.detail) }
            if let cwd = event.cwd, !cwd.isEmpty {
                Button("复制工作目录") { copy(cwd) }
            }
            Divider()
            Button("只看 \(event.source.displayName)") { sourceFilter = event.source }
            Button("只看「\(event.kind.label)」") { kindFilter = event.kind }
        }
    }

    /// 类型图标块：复用 `TileSpec` + `ToolKind.icon`，位置与四大知识页的 `SourceLogoTile` 对齐
    private func kindTile(_ kind: ToolKind) -> some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(28), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: 28, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(28), style: .continuous)
                    .strokeBorder(TileSpec.border(Theme.brand), lineWidth: 0.5))
            .overlay(
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.brandFg))
            .help(kind.label)
    }

    // MARK: - 分页（照 UsageDashboardView.paginationBar，含以前缺的「跳至」）

    private var paginationBar: some View {
        HStack(spacing: 8) {
            Text("共 \(service.total) 条")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            // 同 subtitle：全库风险数与筛选后的「共 N 条」不同基准，不并排显示
            if service.riskTotal > 0, !filtering {
                Text("· 风险 \(service.riskTotal)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.failureRed)
            }
            Spacer()
            Button { goTo(page - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page <= 1)
            Text("\(page) / \(totalPages)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { goTo(page + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page >= totalPages)
            Text("跳至").font(.system(size: 10)).foregroundStyle(.tertiary)
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let target = Int(pageInput.trimmingCharacters(in: .whitespaces)) {
                        goTo(target)
                    }
                    pageInput = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 助手

    private func toggle(_ opId: String) {
        if expanded.contains(opId) { expanded.remove(opId) } else { expanded.insert(opId) }
    }

    private func goTo(_ target: Int) {
        page = min(max(1, target), totalPages)
        reload()
    }

    private func reload() {
        service.load(query: query, page: page, pageSize: pageSize)
    }

    private func resetAndReload() {
        page = 1
        expanded.removeAll()
        reload()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func firstLine(_ text: String) -> String {
        guard !text.isEmpty else { return "—" }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    /// cwd → 项目名（取末段即可；不为一个展示串把 EurekaUsage 的 ProjectResolver 引进来）
    private func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
