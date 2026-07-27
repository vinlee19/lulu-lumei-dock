import AppKit
import EurekaKit
import EurekaStore
import EurekaSync
import SwiftUI

/// 「备份」页签：云端备份的状态/进度/统计/历史一站式面板；
/// 配置（服务商/连接/密钥/间隔）收在独立弹窗 ConfigSheet 里。
struct BackupView: View {
    @ObservedObject var service: SyncService
    @ObservedObject var settings: AppSettings

    @State private var showConfig = false
    @State private var historyPage = 1
    @State private var expandedRuns: Set<Int64> = []
    @State private var expandedSources: Set<String> = []
    /// 展开中的「轮次+类目」，键 `<runId>|<category>`
    @State private var expandedRunGroups: Set<String> = []

    private let historyPageSize = 20

    private var provider: StorageProvider {
        StorageProvider(rawValue: settings.storageProvider) ?? .tencentCOS
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.module) {
                statusCard
                if settings.cloudBackupEnabled {
                    if service.progress != nil || service.syncing {
                        progressCard
                    }
                    statsCard
                    compositionCard
                    if service.runsTotal > 0 {
                        historyCard
                    }
                } else {
                    emptyState
                }
            }
            .padding(Theme.spacing.page)
        }
        .onAppear {
            service.refreshCredentialStatus()
            service.refreshStats()
            service.visibleRunsPage = historyPage
            service.loadRuns(page: historyPage, pageSize: historyPageSize)
        }
        .sheet(isPresented: $showConfig) {
            BackupConfigSheet(service: service, settings: settings)
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        card("备份状态") {
            HStack {
                Toggle("自动备份（增量上传，无变化自动跳过）", isOn: $settings.cloudBackupEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button("配置…") { showConfig = true }
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                summaryBadge(provider.displayName)
                if !settings.cosBucket.isEmpty {
                    summaryBadge(settings.cosBucket)
                }
                if !settings.cosRegion.isEmpty {
                    summaryBadge(settings.cosRegion)
                }
                summaryBadge("每 \(Int(service.intervalMinutes)) 分钟")
                summaryBadge(
                    service.credentialsConfigured ? "密钥已配置" : "密钥未配置",
                    color: service.credentialsConfigured ? .green : .orange)
                Spacer(minLength: 0)
            }
            HStack {
                Button("立即同步") {
                    pushConfig()
                    service.syncNow()
                }
                .controlSize(.small)
                .disabled(!configReady || service.syncing)
                Button("测试连接") {
                    pushConfig()
                    service.testConnection()
                }
                .controlSize(.small)
                .disabled(!configReady)
                if service.syncing && service.progress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                if let test = service.testResult {
                    Text(test)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let error = service.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 进度卡

    private var progressCard: some View {
        card("同步进行中") {
            if let progress = service.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text("\(progress.completedFiles)/\(progress.totalFiles) 个文件")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    // 统一用带 GB 的格式化：大备份用 formatBytes 会显示成「1234.5 MB」
                    Text("\(formatSyncBytes(max(0, progress.transferredBytes))) / \(formatSyncBytes(max(0, progress.totalBytes)))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let current = progress.currentFile {
                    Text("正在上传：\(current)")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在扫描本地文件…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 统计卡

    private var statsCard: some View {
        card("备份统计") {
            HStack(spacing: 18) {
                stat("已备份文件", service.stats.map { "\($0.fileCount)" } ?? "—")
                stat("总大小", service.stats.map { formatSyncBytes(max(0, $0.totalBytes)) } ?? "—")
                stat("最近上传", service.stats?.lastUploadAt.map {
                    relativeFormatter.localizedString(for: $0, relativeTo: Date())
                } ?? "—")
            }
            if let result = service.lastResult {
                Text("上轮：\(result)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 备份构成（总览卡 + 每来源可折叠分组）

    /// 按来源聚合后的构成，字节降序
    private var compositionBySource:
        [(source: String, count: Int, bytes: Int64, kinds: [SyncStateRepo.CompositionBucket])] {
        var grouped: [String: [SyncStateRepo.CompositionBucket]] = [:]
        for bucket in service.composition {
            grouped[bucket.source, default: []].append(bucket)
        }
        return grouped
            .map { source, kinds in
                (source: source,
                 count: kinds.reduce(0) { $0 + $1.count },
                 bytes: kinds.reduce(0) { $0 + $1.bytes },
                 kinds: kinds.sorted { $0.bytes > $1.bytes })
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// 构成区。旧版是单行横向 ScrollView + 12 个 9.5pt 胶囊：最小窗口宽度（可用约 610pt）
    /// 下必然溢出，而 `showsIndicators: false` 让用户根本看不出还有内容被藏起来。
    /// 现在改成总览卡 + 每来源一行可折叠分组，展开看二级类目占比 —— 与 Skills/Memory/
    /// Plans/Agents 四页同一套语言（`StatOverviewCard` + `SourceSectionHeader`）。
    @ViewBuilder
    private var compositionCard: some View {
        let bySource = compositionBySource
        if !bySource.isEmpty {
            let totalFiles = bySource.reduce(0) { $0 + $1.count }
            let totalBytes = bySource.reduce(Int64(0)) { $0 + $1.bytes }
            card("备份构成") {
                StatOverviewCard(
                    value: "\(totalFiles)",
                    unit: "个文件",
                    subtitle: formatSyncBytes(totalBytes),
                    distributionTitle: "按来源",
                    segments: bySource.prefix(6).enumerated().map { index, item in
                        StatOverviewCard.Segment(
                            label: displayName(forSource: item.source),
                            count: item.count,
                            color: sourceColor(item.source, fallbackIndex: index))
                    },
                    trailingNote: bySource.count > 6 ? "另有 \(bySource.count - 6) 个来源" : nil)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(bySource, id: \.source) { item in
                        SourceSectionHeader(
                            source: AgentSource(rawValue: item.source),
                            icon: "folder.fill",
                            title: displayName(forSource: item.source),
                            count: item.count,
                            trailingNote: formatSyncBytes(item.bytes),
                            collapsed: !expandedSources.contains(item.source),
                            onToggle: { toggleSource(item.source) })
                        if expandedSources.contains(item.source) {
                            ForEach(item.kinds, id: \.kind) { bucket in
                                kindRow(bucket, sourceBytes: item.bytes)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 二级类目一行：名称 + 占该来源的比例条 + 文件数 + 字节
    private func kindRow(
        _ bucket: SyncStateRepo.CompositionBucket, sourceBytes: Int64
    ) -> some View {
        let ratio = sourceBytes > 0 ? Double(bucket.bytes) / Double(sourceBytes) : 0
        return HStack(spacing: 8) {
            Text(bucket.kind ?? "根文件")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.brand.opacity(0.55))
                        .frame(width: max(3, geo.size.width * ratio))
                }
            }
            .frame(height: 4)
            Text("\(bucket.count) 个")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(formatSyncBytes(bucket.bytes))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
    }

    private func toggleSource(_ source: String) {
        if expandedSources.contains(source) {
            expandedSources.remove(source)
        } else {
            expandedSources.insert(source)
        }
    }

    /// 来源段 → 展示名。`custom` 与未知段回退原文（以前页面上直接印裸 rawValue 如 `codebuddy`）
    private func displayName(forSource source: String) -> String {
        AgentSource(rawValue: source)?.displayName ?? source
    }

    /// 总览条的分段色：命中来源用品牌色，其余（custom）按序取品牌色不同透明度
    private func sourceColor(_ source: String, fallbackIndex: Int) -> Color {
        if let agent = AgentSource(rawValue: source) { return agent.brandColor }
        return Theme.brand.opacity(max(0.25, 0.8 - Double(fallbackIndex) * 0.12))
    }

    // MARK: - 历史卡（持久化 + 分页 + 可展开文件明细）

    private var totalHistoryPages: Int {
        max(1, (service.runsTotal + historyPageSize - 1) / historyPageSize)
    }

    /// 同步历史。旧版无列头无对齐（字段左挤、跨行对不齐）、20 行非 lazy、
    /// 展开后最多 500 个文件平铺、且只按来源一级分组（把 `RunFile.category` 的二级丢了）。
    /// 现在照仓库里最相近的两页（`AuditView` 的 LazyVStack + `UsageDashboardView` 的
    /// 固定列宽表格）重做，并给每行加一条来源占比微条 —— 不展开也能看出这轮传了谁的东西。
    private var historyCard: some View {
        card("同步历史") {
            historyHeader
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(service.runs) { run in
                    runRow(run)
                    Divider().opacity(0.35)
                }
            }
            historyPager
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 10)  // chevron 列
            Text("时间").frame(width: 84, alignment: .leading)
            Text("状态").frame(width: 46, alignment: .leading)
            Text("上传").frame(width: 58, alignment: .trailing)
            Text("大小").frame(width: 68, alignment: .trailing)
            Text("构成").frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 2)
    }

    private var historyPager: some View {
        HStack(spacing: 8) {
            Text("共 \(service.runsTotal) 轮")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                goToHistoryPage(historyPage - 1)
            } label: { Image(systemName: "chevron.left").font(.system(size: 9)) }
            .buttonStyle(.borderless)
            .disabled(historyPage <= 1)
            Text("\(historyPage) / \(totalHistoryPages)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                goToHistoryPage(historyPage + 1)
            } label: { Image(systemName: "chevron.right").font(.system(size: 9)) }
            .buttonStyle(.borderless)
            .disabled(historyPage >= totalHistoryPages)
        }
    }

    private func goToHistoryPage(_ page: Int) {
        historyPage = min(max(1, page), totalHistoryPages)
        // 服务侧每轮同步后按这个页码原地刷新，不再把用户顶回第 1 页
        service.visibleRunsPage = historyPage
        service.loadRuns(page: historyPage, pageSize: historyPageSize)
    }

    @ViewBuilder
    private func runRow(_ run: SyncRunsRepo.Run) -> some View {
        let expanded = expandedRuns.contains(run.id)
        let groups = groupedFiles(run.files)
        Button {
            if expanded { expandedRuns.remove(run.id) } else { expandedRuns.insert(run.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(run.files.isEmpty ? 0 : 1)
                    .frame(width: 10)
                Text(run.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                HStack(spacing: 4) {
                    Circle()
                        .fill(run.error == nil ? Theme.enabledGreen : Theme.failureRed)
                        .frame(width: 6, height: 6)
                    Text(run.error == nil ? "成功" : "失败")
                        .font(.system(size: 10.5))
                        .foregroundStyle(run.error == nil ? .secondary : Color(Theme.failureRed))
                }
                .frame(width: 46, alignment: .leading)
                Text("\(run.uploaded) 个")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
                Text(run.uploadedBytes > 0 ? formatSyncBytes(run.uploadedBytes) : "—")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
                compositionBar(groups)
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                if run.failed > 0 {
                    Text("失败 \(run.failed)")
                        .font(.system(size: 10)).foregroundStyle(Color(Theme.failureRed))
                }
                if run.deferred > 0 {
                    Text("待传 \(run.deferred)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let error = run.error {
            Text(error)
                .font(.system(size: 9.5))
                .foregroundStyle(Color(Theme.failureRed))
                .lineLimit(2)
                .padding(.leading, 18)
        }

        if expanded {
            VStack(alignment: .leading, spacing: 1) {
                // 按**完整 category** 分组（claude/skills 而不是 claude），每组可再折叠
                ForEach(groups, id: \.category) { group in
                    runGroupRow(run: run, group: group)
                }
                if run.uploaded > run.files.count {
                    Text("本轮共 \(run.uploaded) 个文件，只记录了前 \(run.files.count) 个明细")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 3)
        }
    }

    /// 每行一条来源占比微条（照 UsageDashboardView.toolRow 的做法）
    @ViewBuilder
    private func compositionBar(_ groups: [RunGroup]) -> some View {
        let total = max(Int64(1), groups.reduce(Int64(0)) { $0 + $1.bytes })
        if groups.isEmpty {
            Text("—").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        } else {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(groups.prefix(8).enumerated()), id: \.offset) { index, group in
                        Capsule()
                            .fill(sourceColor(group.source, fallbackIndex: index))
                            .frame(width: max(2, geo.size.width * Double(group.bytes) / Double(total)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 5)
        }
    }

    /// 展开区的一个类目组：默认收起，点开才列文件（最多 30 个，避免 500 个平铺）
    @ViewBuilder
    private func runGroupRow(run: SyncRunsRepo.Run, group: RunGroup) -> some View {
        let key = "\(run.id)|\(group.category)"
        let open = expandedRunGroups.contains(key)
        Button {
            if open { expandedRunGroups.remove(key) } else { expandedRunGroups.insert(key) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                if let source = AgentSource(rawValue: group.source) {
                    SourceBadge(source: source, size: 10)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.brand.opacity(0.7))
                }
                Text(group.category)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("\(group.files.count) 个")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(formatSyncBytes(group.bytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if open {
            let shown = group.files.prefix(30)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatSyncBytes(max(0, file.size)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 20)
            }
            if group.files.count > shown.count {
                Text("…剩 \(group.files.count - shown.count) 个")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
    }

    /// 一轮里的一个类目组
    struct RunGroup {
        var category: String
        var source: String
        var files: [SyncRunsRepo.RunFile]
        var bytes: Int64
    }

    /// 一轮的文件按**完整 category** 分组（`claude/skills` 而不是 `claude`），字节降序。
    /// 旧版只取首段，把二级信息丢了 —— 而 `RunFile.category` 本来就带着。
    private func groupedFiles(_ files: [SyncRunsRepo.RunFile]) -> [RunGroup] {
        var groups: [String: [SyncRunsRepo.RunFile]] = [:]
        for file in files {
            let category = (file.category?.isEmpty == false ? file.category! : "其他")
            groups[category, default: []].append(file)
        }
        return groups
            .map { category, files in
                RunGroup(
                    category: category,
                    source: category.split(separator: "/").first.map(String.init) ?? category,
                    files: files,
                    bytes: files.reduce(Int64(0)) { $0 + $1.size })
            }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 34))
                .foregroundStyle(Theme.brand.opacity(0.5))
            Text("开启自动备份后，技能、记忆、计划与全部会话记录会增量上传到你的云端存储")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("只上传不删除 · 密钥仅存于 macOS 钥匙串 · 支持腾讯云 COS 与自定义 S3 兼容存储")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button("配置…") { showConfig = true }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - 助手

    private var configReady: Bool {
        let endpointReady = provider != .custom
            || !settings.cosEndpointHost.trimmingCharacters(in: .whitespaces).isEmpty
        return !settings.cosRegion.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.cosBucket.trimmingCharacters(in: .whitespaces).isEmpty
            && endpointReady
            && service.credentialsConfigured
    }

    private func pushConfig() {
        service.updateConfig(
            provider: provider,
            region: settings.cosRegion.trimmingCharacters(in: .whitespaces),
            bucket: settings.cosBucket.trimmingCharacters(in: .whitespaces),
            endpointHost: settings.cosEndpointHost.trimmingCharacters(in: .whitespaces),
            keyPrefix: settings.cosKeyPrefix.trimmingCharacters(in: .whitespaces),
            retryAttempts: settings.cosRetryAttempts,
            retryBackoffSeconds: settings.cosRetryBackoffSeconds,
            customFolders: settings.customSyncFolders)
    }

    private func card(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        SectionCard(title, content: content)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func summaryBadge(_ text: String, color: Color = Theme.brand) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

// MARK: - 配置弹窗

/// 云端备份配置：服务商/连接参数/密钥/同步间隔 + 实时请求 URL 预览
private struct BackupConfigSheet: View {
    @ObservedObject var service: SyncService
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @State private var secretId = ""
    @State private var secretKey = ""
    @State private var credentialsSaved = false

    private var provider: StorageProvider {
        StorageProvider(rawValue: settings.storageProvider) ?? .tencentCOS
    }

    /// 实时拼出的请求 URL 预览（与实际上传请求一致的形态）
    private var urlPreview: String {
        let bucket = settings.cosBucket.trimmingCharacters(in: .whitespaces)
        let region = settings.cosRegion.trimmingCharacters(in: .whitespaces)
        let host = provider.endpointHost(region: region.isEmpty ? "<region>" : region)
            ?? (settings.cosEndpointHost.isEmpty ? "<endpoint>" : settings.cosEndpointHost)
        let prefix = settings.cosKeyPrefix.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ "))
        let device = SyncKeyMapper.deviceNamespace()
        var parts: [String] = []
        if !prefix.isEmpty { parts.append(prefix) }
        parts += [device, "claude", "…"]
        return "PUT https://\(bucket.isEmpty ? "<bucket>" : bucket).\(host)/"
            + parts.joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("云端备份配置")
                .font(.system(size: 13, weight: .semibold))
                .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row("服务商") {
                        Picker("", selection: $settings.storageProvider) {
                            ForEach(StorageProvider.selectable, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    row("地域") {
                        TextField(provider.regionHint, text: $settings.cosRegion)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("存储桶") {
                        TextField("如 backup-1250000000", text: $settings.cosBucket)
                            .textFieldStyle(.roundedBorder)
                    }
                    if provider == .custom {
                        row("Endpoint") {
                            TextField("如 s3.us-east-1.amazonaws.com",
                                      text: $settings.cosEndpointHost)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    row("键前缀") {
                        TextField("对象键前缀", text: $settings.cosKeyPrefix)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("同步间隔") {
                        TextField("30", value: $settings.cosSyncIntervalMinutes,
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { clampInterval() }
                        Text("分钟（最小 1）")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    row("失败重试") {
                        Stepper(value: $settings.cosRetryAttempts, in: 0...5) {
                            Text("\(settings.cosRetryAttempts) 次")
                                .font(.system(size: 11).monospacedDigit())
                        }
                        .controlSize(.small)
                        TextField("3", value: $settings.cosRetryBackoffSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("秒退避 ×2 递增（仅网络错误/5xx 重试）")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 2)

                    customFoldersSection

                    Divider().padding(.vertical, 2)

                    row("SecretId") {
                        SecureField("", text: $secretId)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("SecretKey") {
                        SecureField("", text: $secretKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("") {
                        Button(credentialsSaved ? "已保存" : "保存密钥") {
                            service.saveCredentials(
                                secretId: secretId.trimmingCharacters(in: .whitespaces),
                                secretKey: secretKey.trimmingCharacters(in: .whitespaces)
                            ) { ok in
                                if ok {
                                    secretId = ""
                                    secretKey = ""
                                    credentialsSaved = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        credentialsSaved = false
                                    }
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(secretId.trimmingCharacters(in: .whitespaces).isEmpty
                            || secretKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(service.credentialsConfigured ? "钥匙串：已配置" : "钥匙串：未配置")
                            .font(.system(size: 10))
                            .foregroundStyle(service.credentialsConfigured ? .green : .secondary)
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("请求预览")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(urlPreview)
                            .font(.system(size: 9.5).monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("认证走 AWS SigV4 签名头（Authorization / x-amz-date / x-amz-content-sha256）；只上传不删除，密钥仅存于 macOS 钥匙串。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Spacer()
                Button("完成") {
                    clampInterval()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: 520, height: 480)
        .font(.system(size: 11.5))
        .onAppear { service.refreshCredentialStatus() }
        .onDisappear { clampInterval() }
    }

    /// 自定义同步目录：任意本地目录 → 远端 custom/<远端名>/…
    @ViewBuilder
    private var customFoldersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("自定义目录")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("添加文件夹…") { pickFolder() }
                    .controlSize(.small)
            }
            if settings.customSyncFolders.isEmpty {
                Text("把任意本地目录纳入备份：远端键 = <前缀>/<主机>/custom/<远端名>/<相对路径>")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            ForEach($settings.customSyncFolders) { $folder in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.brand.opacity(0.8))
                    Text(folder.path)
                        .font(.system(size: 10).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Spacer(minLength: 4)
                    Text("→ custom/")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    TextField("远端名", text: $folder.remoteName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Toggle("", isOn: $folder.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(folder.enabled ? "已纳入备份" : "已暂停")
                    Button {
                        settings.customSyncFolders.removeAll { $0.id == folder.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("移除（不删除本地文件，远端已传内容保留）")
                }
            }
        }
    }

    /// 系统目录选择器（非沙盒，直接存路径）
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 同一路径不重复添加
        guard !settings.customSyncFolders.contains(where: { $0.path == url.path }) else { return }
        settings.customSyncFolders.append(CustomSyncFolder(
            path: url.path, remoteName: url.lastPathComponent))
    }

    /// 间隔钳制：最小 1 分钟
    private func clampInterval() {
        if settings.cosSyncIntervalMinutes < 1 || !settings.cosSyncIntervalMinutes.isFinite {
            settings.cosSyncIntervalMinutes = 1
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 64, alignment: .leading)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
