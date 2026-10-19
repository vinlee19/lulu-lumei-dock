import AppKit
import EurekaKit
import EurekaStore
import EurekaSync
import SwiftUI

/// Backup tab: one-stop panel for cloud backup status / progress / stats / history; configuration
/// (provider / connection / secrets / interval) lives in the separate ConfigSheet dialog.
struct BackupView: View {
    @ObservedObject var service: SyncService
    @ObservedObject var settings: AppSettings

    @State private var showConfig = false
    @State private var historyPage = 1
    @State private var expandedRuns: Set<Int64> = []
    @State private var expandedSources: Set<String> = []
    /// Expanded "run + category" entries, keyed `<runId>|<category>`
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

    // MARK: - Status card

    private var statusCard: some View {
        card(L10n.text("Backup status", zhHans: "备份状态")) {
            HStack {
                Toggle(L10n.text("Automatic backup (incremental upload, skipped when nothing changed)", zhHans: "自动备份（增量上传，无变化自动跳过）"), isOn: $settings.cloudBackupEnabled)
                    .toggleStyle(.themedSwitch)
                    .controlSize(.small)
                Spacer()
                Button(L10n.text("Configure…", zhHans: "配置…")) { showConfig = true }
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
                summaryBadge(L10n.format("Every %@ minutes", zhHans: "每 %@ 分钟", String(Int(service.intervalMinutes))))
                summaryBadge(
                    service.credentialsConfigured ? L10n.text("Key configured", zhHans: "密钥已配置") : L10n.text("Key not configured", zhHans: "密钥未配置"),
                    color: service.credentialsConfigured ? .green : .orange)
                Spacer(minLength: 0)
            }
            HStack {
                Button(L10n.text("Sync Now", zhHans: "立即同步")) {
                    pushConfig()
                    service.syncNow()
                }
                .controlSize(.small)
                .disabled(!configReady || service.syncing)
                Button(L10n.text("Test Connection", zhHans: "测试连接")) {
                    pushConfig()
                    service.testConnection()
                }
                .controlSize(.small)
                .disabled(!configReady)
                if service.syncing && service.progress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                switch service.connectionTest {
                case .running:
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("Testing…", zhHans: "测试中…"))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                case .success:
                    Label(L10n.text("Connected", zhHans: "连接成功"), systemImage: "checkmark.circle.fill")
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(Theme.enabledGreen)
                case .failure(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(Theme.failureRed)
                        .lineLimit(2)
                        .help(message)
                case nil:
                    EmptyView()
                }
            }
            if let error = service.lastError {
                Text(error)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Progress card

    private var progressCard: some View {
        card(L10n.text("Sync in progress", zhHans: "同步进行中")) {
            if let progress = service.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text(L10n.format("%@/%@ files", zhHans: "%@/%@ 个文件", String(progress.completedFiles), String(progress.totalFiles)))
                        .font(Theme.font.themedMono(10.5, .medium))
                    // Always use the GB-aware formatter: formatBytes would show a large backup as
                    // "1234.5 MB"
                    Text("\(formatSyncBytes(max(0, progress.transferredBytes))) / \(formatSyncBytes(max(0, progress.totalBytes)))")
                        .font(Theme.font.themedMono(10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let current = progress.currentFile {
                    Text(L10n.format("Uploading: %@", zhHans: "正在上传：%@", current))
                        .font(Theme.font.monoSkillName(10, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Scanning local files…", zhHans: "正在扫描本地文件…"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Stats card

    private var statsCard: some View {
        card(L10n.text("Backup statistics", zhHans: "备份统计")) {
            HStack(spacing: 18) {
                stat(L10n.text("Files backed up", zhHans: "已备份文件"), service.stats.map { "\($0.fileCount)" } ?? "—")
                stat(L10n.text("Total size", zhHans: "总大小"), service.stats.map { formatSyncBytes(max(0, $0.totalBytes)) } ?? "—")
                stat(L10n.text("Last upload", zhHans: "最近上传"), service.stats?.lastUploadAt.map {
                    relativeFormatter.localizedString(for: $0, relativeTo: Date())
                } ?? "—")
            }
            if let result = service.lastResult {
                Text(L10n.format("Last run: %@", zhHans: "上轮：%@", result))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Backup composition (overview card + collapsible group per source)

    /// Composition aggregated by source, bytes descending
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

    /// Composition area. The old version was a single-row horizontal ScrollView + 12 9.5pt
    /// capsules: at the minimum window width (~610pt usable) it inevitably overflowed, and
    /// `showsIndicators: false` meant users couldn't tell content was hidden. Now it is an overview
    /// card + one collapsible group row per source, expanding to show second-level category shares
    /// — the same language as the Skills/Memory/Plans/Agents pages (`StatOverviewCard` +
    /// `SourceSectionHeader`).
    @ViewBuilder
    private var compositionCard: some View {
        let bySource = compositionBySource
        if !bySource.isEmpty {
            let totalFiles = bySource.reduce(0) { $0 + $1.count }
            let totalBytes = bySource.reduce(Int64(0)) { $0 + $1.bytes }
            card(L10n.text("Backup makeup", zhHans: "备份构成")) {
                StatOverviewCard(
                    value: "\(totalFiles)",
                    unit: L10n.text("files", zhHans: "个文件"),
                    subtitle: formatSyncBytes(totalBytes),
                    distributionTitle: L10n.text("By source", zhHans: "按来源"),
                    segments: bySource.prefix(6).enumerated().map { index, item in
                        StatOverviewCard.Segment(
                            label: displayName(forSource: item.source),
                            count: item.count,
                            color: sourceColor(item.source, fallbackIndex: index))
                    },
                    trailingNote: bySource.count > 6 ? L10n.format("%@ more sources", zhHans: "另有 %@ 个来源", String(bySource.count - 6)) : nil)

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

    /// Second-level category row: name + share-of-source bar + file count + bytes
    private func kindRow(
        _ bucket: SyncStateRepo.CompositionBucket, sourceBytes: Int64
    ) -> some View {
        let ratio = sourceBytes > 0 ? Double(bucket.bytes) / Double(sourceBytes) : 0
        return HStack(spacing: 8) {
            Text(bucket.kind ?? L10n.text("Root files", zhHans: "根文件"))
                .font(Theme.font.themed(11))
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
            Text(L10n.format("%@ files", zhHans: "%@ 个", String(bucket.count)))
                .font(Theme.font.themedMono(10.5))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(formatSyncBytes(bucket.bytes))
                .font(Theme.font.themedMono(10.5))
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

    /// Source segment → display name. `custom` and unknown segments fall back to the raw text (the
    /// page used to print bare rawValues like `codebuddy`)
    private func displayName(forSource source: String) -> String {
        AgentSource(rawValue: source)?.displayName ?? source
    }

    /// Overview bar segment colors: matched sources use their brand color, the rest (custom) take
    /// the brand color at varying opacity in order
    private func sourceColor(_ source: String, fallbackIndex: Int) -> Color {
        if let agent = AgentSource(rawValue: source) { return agent.brandColor }
        return Theme.brand.opacity(max(0.25, 0.8 - Double(fallbackIndex) * 0.12))
    }

    // MARK: - History card (persisted + paginated + expandable file details)

    private var totalHistoryPages: Int {
        max(1, (service.runsTotal + historyPageSize - 1) / historyPageSize)
    }

    /// Sync history. The old version had no column headers or alignment (fields crammed left,
    /// misaligned across rows), 20 non-lazy rows, up to 500 files flattened when expanded, and
    /// grouping by source only (dropping `RunFile.category`'s second level). Now rebuilt after the
    /// two closest pages in the repo (`AuditView`'s LazyVStack + `UsageDashboardView`'s fixed-width
    /// column table), with a per-row source-share micro bar — you can see whose data the run
    /// uploaded without expanding.
    private var historyCard: some View {
        card(L10n.text("Sync history", zhHans: "同步历史")) {
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
            Color.clear.frame(width: 10)  // chevron column
            Text(L10n.text("Time", zhHans: "时间")).frame(width: 84, alignment: .leading)
            Text(L10n.text("Status", zhHans: "状态")).frame(width: 46, alignment: .leading)
            Text(L10n.text("Uploaded", zhHans: "上传")).frame(width: 58, alignment: .trailing)
            Text(L10n.text("Size", zhHans: "大小")).frame(width: 68, alignment: .trailing)
            Text(L10n.text("Makeup", zhHans: "构成")).frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font.themed(10, .semibold))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 2)
    }

    private var historyPager: some View {
        HStack(spacing: 8) {
            Text(L10n.format("%@ runs", zhHans: "共 %@ 轮", String(service.runsTotal)))
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                goToHistoryPage(historyPage - 1)
            } label: { Image(systemName: "chevron.left").font(Theme.font.themed(9)) }
            .buttonStyle(.borderless)
            .disabled(historyPage <= 1)
            Text("\(historyPage) / \(totalHistoryPages)")
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.secondary)
            Button {
                goToHistoryPage(historyPage + 1)
            } label: { Image(systemName: "chevron.right").font(Theme.font.themed(9)) }
            .buttonStyle(.borderless)
            .disabled(historyPage >= totalHistoryPages)
        }
    }

    private func goToHistoryPage(_ page: Int) {
        historyPage = min(max(1, page), totalHistoryPages)
        // The service refreshes in place at this page number after each sync, instead of bouncing
        // the user back to page 1
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
                    .font(Theme.font.themed(8, .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(run.files.isEmpty ? 0 : 1)
                    .frame(width: 10)
                Text(run.date, format: .dateTime.month().day().hour().minute())
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                HStack(spacing: 4) {
                    Circle()
                        .fill(run.error == nil ? Theme.enabledGreen : Theme.failureRed)
                        .frame(width: 6, height: 6)
                    Text(run.error == nil ? L10n.text("Succeeded", zhHans: "成功") : L10n.text("Failed", zhHans: "失败"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(run.error == nil ? .secondary : Color(Theme.failureRed))
                }
                .frame(width: 46, alignment: .leading)
                Text(L10n.format("%@ files", zhHans: "%@ 个", String(run.uploaded)))
                    .font(Theme.font.themedMono(10.5, .medium))
                    .frame(width: 58, alignment: .trailing)
                Text(run.uploadedBytes > 0 ? formatSyncBytes(run.uploadedBytes) : "—")
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
                compositionBar(groups)
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                if run.failed > 0 {
                    Text(L10n.format("Failed %@", zhHans: "失败 %@", String(run.failed)))
                        .font(Theme.font.themed(10)).foregroundStyle(Color(Theme.failureRed))
                }
                if run.deferred > 0 {
                    Text(L10n.format("Deferred %@", zhHans: "待传 %@", String(run.deferred)))
                        .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let error = run.error {
            Text(error)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(Color(Theme.failureRed))
                .lineLimit(2)
                .padding(.leading, 18)
        }

        if expanded {
            VStack(alignment: .leading, spacing: 1) {
                // Group by the **full category** (claude/skills rather than claude); each group is
                // collapsible again
                ForEach(groups, id: \.category) { group in
                    runGroupRow(run: run, group: group)
                }
                if run.uploaded > run.files.count {
                    Text(L10n.format(
                        "This run uploaded %@ files; only the first %@ are listed",
                        zhHans: "本轮共 %@ 个文件，只记录了前 %@ 个明细",
                        String(run.uploaded), String(run.files.count)))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 3)
        }
    }

    /// Per-row source-share micro bar (after UsageDashboardView.toolRow)
    @ViewBuilder
    private func compositionBar(_ groups: [RunGroup]) -> some View {
        let total = max(Int64(1), groups.reduce(Int64(0)) { $0 + $1.bytes })
        if groups.isEmpty {
            Text("—").font(Theme.font.themed(10.5)).foregroundStyle(.tertiary)
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

    /// A category group in the expanded area: collapsed by default, files listed only when opened
    /// (at most 30, instead of 500 flattened)
    @ViewBuilder
    private func runGroupRow(run: SyncRunsRepo.Run, group: RunGroup) -> some View {
        let key = "\(run.id)|\(group.category)"
        let open = expandedRunGroups.contains(key)
        Button {
            if open { expandedRunGroups.remove(key) } else { expandedRunGroups.insert(key) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(Theme.font.themed(7, .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                if let source = AgentSource(rawValue: group.source) {
                    SourceBadge(source: source, size: 10)
                } else {
                    Image(systemName: "folder.fill")
                        .font(Theme.font.themed(9))
                        .foregroundStyle(Theme.brandFg.opacity(0.7))
                }
                Text(group.category)
                    .font(Theme.font.themed(10.5, .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(L10n.format("%@ files", zhHans: "%@ 个", String(group.files.count)))
                    .font(Theme.font.themedMono(10))
                    .foregroundStyle(.secondary)
                Text(formatSyncBytes(group.bytes))
                    .font(Theme.font.themedMono(10))
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
                        .font(Theme.font.monoSkillName(10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatSyncBytes(max(0, file.size)))
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 20)
            }
            if group.files.count > shown.count {
                Text(L10n.format("…%@ more", zhHans: "…剩 %@ 个", String(group.files.count - shown.count)))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
    }

    /// A category group within one run
    struct RunGroup {
        var category: String
        var source: String
        var files: [SyncRunsRepo.RunFile]
        var bytes: Int64
    }

    /// A run's files grouped by **full category** (`claude/skills` rather than `claude`), bytes
    /// descending. The old version took only the first segment and lost the second level — even
    /// though `RunFile.category` already carries it.
    private func groupedFiles(_ files: [SyncRunsRepo.RunFile]) -> [RunGroup] {
        var groups: [String: [SyncRunsRepo.RunFile]] = [:]
        for file in files {
            let category = (file.category?.isEmpty == false ? file.category! : L10n.text("Other", zhHans: "其他"))
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.up")
                .font(Theme.font.themed(34))
                .foregroundStyle(Theme.brandFg.opacity(0.5))
            Text(L10n.text("After automatic backup is on, skills, memory, plans, and every session record upload incrementally to your cloud storage", zhHans: "开启自动备份后，技能、记忆、计划与全部会话记录会增量上传到你的云端存储"))
                .font(Theme.font.themed(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(L10n.text("Upload only, never delete · keys stay in the macOS Keychain · Tencent Cloud COS and custom S3-compatible storage", zhHans: "只上传不删除 · 密钥仅存于 macOS 钥匙串 · 支持腾讯云 COS 与自定义 S3 兼容存储"))
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
            Button(L10n.text("Configure…", zhHans: "配置…")) { showConfig = true }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Helpers

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
                .font(Theme.font.themedMono(15, .semibold))
            Text(label)
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
        }
    }

    private func summaryBadge(_ text: String, color: Color = Theme.brand) -> some View {
        Text(text)
            .font(Theme.font.themed(9.5, .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

// MARK: - Config dialog

/// Cloud backup config: provider / connection parameters / secrets / sync interval + live request
/// URL preview
private struct BackupConfigSheet: View {
    @ObservedObject var service: SyncService
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @State private var secretId = ""
    @State private var secretKey = ""
    @State private var credentialsSaved = false
    /// Keychain write failure shown inside the sheet; the status card's `lastError` is behind it.
    @State private var credentialsError: String?

    private var provider: StorageProvider {
        StorageProvider(rawValue: settings.storageProvider) ?? .tencentCOS
    }

    /// Live-assembled request URL preview (same shape as the real upload request)
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
            Text(L10n.text("Cloud backup configuration", zhHans: "云端备份配置"))
                .font(Theme.font.themed(13, .semibold))
                .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row(L10n.text("Provider", zhHans: "服务商")) {
                        Picker("", selection: $settings.storageProvider) {
                            ForEach(StorageProvider.selectable, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    row(L10n.text("Region", zhHans: "地域")) {
                        TextField(provider.regionHint, text: $settings.cosRegion)
                            .textFieldStyle(.roundedBorder)
                    }
                    row(L10n.text("Bucket", zhHans: "存储桶")) {
                        TextField(L10n.text("e.g. backup-1250000000", zhHans: "如 backup-1250000000"), text: $settings.cosBucket)
                            .textFieldStyle(.roundedBorder)
                    }
                    if provider == .custom {
                        row("Endpoint") {
                            TextField(L10n.text("e.g. s3.us-east-1.amazonaws.com", zhHans: "如 s3.us-east-1.amazonaws.com"),
                                      text: $settings.cosEndpointHost)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    row(L10n.text("Key prefix", zhHans: "键前缀")) {
                        TextField(L10n.text("Object key prefix", zhHans: "对象键前缀"), text: $settings.cosKeyPrefix)
                            .textFieldStyle(.roundedBorder)
                    }
                    row(L10n.text("Sync interval", zhHans: "同步间隔")) {
                        TextField("30", value: $settings.cosSyncIntervalMinutes,
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { clampInterval() }
                        Text(L10n.text("minutes (minimum 1)", zhHans: "分钟（最小 1）"))
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                    }
                    row(L10n.text("Retries", zhHans: "失败重试")) {
                        Stepper(value: $settings.cosRetryAttempts, in: 0...5) {
                            Text(L10n.format("%@ times", zhHans: "%@ 次", String(settings.cosRetryAttempts)))
                                .font(Theme.font.themedMono(11))
                        }
                        .controlSize(.small)
                        TextField("3", value: $settings.cosRetryBackoffSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.text("second backoff, doubling (network errors and 5xx only)", zhHans: "秒退避 ×2 递增（仅网络错误/5xx 重试）"))
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 2)

                    customFoldersSection

                    Divider().padding(.vertical, 2)

                    auditArchiveSection

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
                        Button(credentialsSaved ? L10n.text("Saved", zhHans: "已保存") : L10n.text("Save Keys", zhHans: "保存密钥")) {
                            service.saveCredentials(
                                secretId: secretId.trimmingCharacters(in: .whitespaces),
                                secretKey: secretKey.trimmingCharacters(in: .whitespaces)
                            ) { ok in
                                credentialsError = ok ? nil : L10n.text("Could not write the keys to the Keychain. Check Keychain access and try again.", zhHans: "密钥写入钥匙串失败，请检查钥匙串访问权限后重试")
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
                        Text(service.credentialsConfigured ? L10n.text("Keychain: configured", zhHans: "钥匙串：已配置") : L10n.text("Keychain: not configured", zhHans: "钥匙串：未配置"))
                            .font(Theme.font.themed(10))
                            .foregroundStyle(service.credentialsConfigured ? .green : .secondary)
                        if let credentialsError {
                            Text(credentialsError)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(Theme.failureRed)
                        }
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Request preview", zhHans: "请求预览"))
                            .font(Theme.font.themed(10.5, .medium))
                            .foregroundStyle(.secondary)
                        Text(urlPreview)
                            .font(Theme.font.monoSkillName(9.5, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(L10n.text("Auth uses AWS SigV4 headers (Authorization / x-amz-date / x-amz-content-sha256). Upload only, never delete, and keys stay in the macOS Keychain.", zhHans: "认证走 AWS SigV4 签名头（Authorization / x-amz-date / x-amz-content-sha256）；只上传不删除，密钥仅存于 macOS 钥匙串。"))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.text("Done", zhHans: "完成")) {
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
        .font(Theme.font.themed(11.5))
        .onAppear { service.refreshCredentialStatus() }
        .onDisappear { clampInterval() }
    }

    /// Custom sync folders: any local folder → remote custom/<remote name>/…
    @ViewBuilder
    /// Audit archive: redacted audit records written as daily Parquet files uploaded with backups
    /// (queryable directly with Athena / DuckDB)
    private var auditArchiveSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.text("Audit archive (Parquet)", zhHans: "审计归档（Parquet）"), isOn: $settings.auditArchiveEnabled)
                .font(Theme.font.themed(11))
            Text(L10n.text(
                "Audit records are written as Parquet per UTC day and uploaded to <prefix>/<host>/eureka/audit/dt=YYYY-MM-DD/. Secrets, tokens, and passwords in commands are redacted before upload (Authorization, KEY=, URL credentials, and common key formats). The rest of the command and paths are kept, so lock the bucket down and turn on server-side encryption. Once this is on, local cleanup only deletes days that uploaded successfully: a failed upload is kept past the retention window instead of being dropped.",
                zhHans: "把审计记录按 UTC 日写成 Parquet，上传到 <前缀>/<主机>/eureka/audit/dt=YYYY-MM-DD/。上传前自动遮掉命令里的密钥、令牌、密码（Authorization、KEY=、URL 凭证、常见密钥格式等），但命令、路径等其余内容保留，建议给存储桶配置访问控制与服务端加密。开启后，本地只清理已确认上传的日期：上传失败时记录会超过保留期继续保留，不会丢。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var customFoldersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Custom folders", zhHans: "自定义目录"))
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Add Folder…", zhHans: "添加文件夹…")) { pickFolder() }
                    .controlSize(.small)
            }
            if settings.customSyncFolders.isEmpty {
                Text(L10n.text("Include any local folder in the backup. Remote key = <prefix>/<host>/custom/<remote name>/<relative path>", zhHans: "把任意本地目录纳入备份：远端键 = <前缀>/<主机>/custom/<远端名>/<相对路径>"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
            }
            ForEach($settings.customSyncFolders) { $folder in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(Theme.font.themed(10))
                        .foregroundStyle(Theme.brandFg.opacity(0.8))
                    Text(folder.path)
                        .font(Theme.font.monoSkillName(10, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Spacer(minLength: 4)
                    Text("→ custom/")
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    TextField(L10n.text("Remote name", zhHans: "远端名"), text: $folder.remoteName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Toggle("", isOn: $folder.enabled)
                        .toggleStyle(.themedSwitch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(folder.enabled ? L10n.text("Included in backup", zhHans: "已纳入备份") : L10n.text("Paused", zhHans: "已暂停"))
                    Button {
                        settings.customSyncFolders.removeAll { $0.id == folder.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Remove (the local folder stays, and anything already uploaded stays remote)", zhHans: "移除（不删除本地文件，远端已传内容保留）"))
                }
            }
        }
    }

    /// System folder picker (not sandboxed, stores the path directly)
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Choose", zhHans: "选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Don't add the same path twice
        guard !settings.customSyncFolders.contains(where: { $0.path == url.path }) else { return }
        settings.customSyncFolders.append(CustomSyncFolder(
            path: url.path, remoteName: url.lastPathComponent))
    }

    /// Interval clamp: minimum 1 minute
    private func clampInterval() {
        if settings.cosSyncIntervalMinutes < 1 || !settings.cosSyncIntervalMinutes.isFinite {
            settings.cosSyncIntervalMinutes = 1
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 64, alignment: .leading)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
