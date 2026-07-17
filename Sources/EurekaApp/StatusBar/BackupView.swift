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

    private let historyPageSize = 20

    private var provider: StorageProvider {
        StorageProvider(rawValue: settings.storageProvider) ?? .tencentCOS
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                if settings.cloudBackupEnabled {
                    if service.progress != nil || service.syncing {
                        progressCard
                    }
                    statsCard
                    if service.runsTotal > 0 {
                        historyCard
                    }
                } else {
                    emptyState
                }
            }
            .padding(12)
        }
        .onAppear {
            service.refreshCredentialStatus()
            service.refreshStats()
            service.loadRuns(page: historyPage, pageSize: historyPageSize)
        }
        .sheet(isPresented: $showConfig) {
            BackupConfigSheet(service: service, settings: settings)
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        card("备份状态", accent: Theme.backup) {
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
        card("同步进行中", accent: Theme.backup) {
            if let progress = service.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text("\(progress.completedFiles)/\(progress.totalFiles) 个文件")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    Text("\(formatBytes(UInt64(max(0, progress.transferredBytes)))) / \(formatBytes(UInt64(max(0, progress.totalBytes))))")
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
        card("备份统计", accent: Theme.backup) {
            HStack(spacing: 18) {
                stat("已备份文件", service.stats.map { "\($0.fileCount)" } ?? "—")
                stat("总大小", service.stats.map { formatBytes(UInt64(max(0, $0.totalBytes))) } ?? "—")
                stat("最近上传", service.stats?.lastUploadAt.map {
                    relativeFormatter.localizedString(for: $0, relativeTo: Date())
                } ?? "—")
            }
            compositionRow
            if let result = service.lastResult {
                Text("上轮：\(result)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 「按来源构成」chips：来源徽标（命中 AgentSource）/文件夹图标（custom/其它）+ 文件数 + 字节
    @ViewBuilder
    private var compositionRow: some View {
        let composition = service.sourceComposition.sorted { $0.value.count > $1.value.count }
        if !composition.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(composition, id: \.key) { key, value in
                        HStack(spacing: 4) {
                            if let source = AgentSource(rawValue: key) {
                                SourceBadge(source: source, size: 9)
                            } else {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Theme.backup.opacity(0.7))
                            }
                            Text("\(key) \(value.count)")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            Text(formatBytes(UInt64(max(0, value.bytes))))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                }
            }
        }
    }

    // MARK: - 历史卡（持久化 + 分页 + 可展开文件明细）

    private var totalHistoryPages: Int {
        max(1, (service.runsTotal + historyPageSize - 1) / historyPageSize)
    }

    private var historyCard: some View {
        card("同步历史（共 \(service.runsTotal) 轮）", accent: Theme.backup) {
            ForEach(service.runs) { run in
                runRow(run)
                Divider().opacity(0.35)
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    historyPage = max(1, historyPage - 1)
                    service.loadRuns(page: historyPage, pageSize: historyPageSize)
                } label: { Image(systemName: "chevron.left").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                .disabled(historyPage <= 1)
                Text("\(historyPage) / \(totalHistoryPages)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    historyPage = min(totalHistoryPages, historyPage + 1)
                    service.loadRuns(page: historyPage, pageSize: historyPageSize)
                } label: { Image(systemName: "chevron.right").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                .disabled(historyPage >= totalHistoryPages)
            }
        }
    }

    @ViewBuilder
    private func runRow(_ run: SyncRunsRepo.Run) -> some View {
        let expanded = expandedRuns.contains(run.id)
        Button {
            if expanded { expandedRuns.remove(run.id) } else { expandedRuns.insert(run.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(run.files.isEmpty ? 0 : 1)
                Circle()
                    .fill(run.error == nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(run.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("↑\(run.uploaded) 个")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                if run.uploadedBytes > 0 {
                    Text(formatBytes(UInt64(run.uploadedBytes)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if run.failed > 0 {
                    Text("失败 \(run.failed)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                if run.deferred > 0 {
                    Text("待传 \(run.deferred)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let error = run.error {
            Text(error)
                .font(.system(size: 9.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.leading, 22)
        }

        if expanded {
            VStack(alignment: .leading, spacing: 2) {
                // 按来源分组（category 首段；老记录无 category → "其他"）
                ForEach(groupedFiles(run.files), id: \.source) { group in
                    HStack(spacing: 5) {
                        if let source = AgentSource(rawValue: group.source) {
                            SourceBadge(source: source, size: 9)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.backup.opacity(0.7))
                        }
                        Text("\(group.source) · \(group.files.count) 个 · \(formatBytes(UInt64(max(0, group.bytes))))")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)
                    ForEach(Array(group.files.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Text(file.name)
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(formatBytes(UInt64(max(0, file.size))))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 14)
                    }
                }
                if run.uploaded > run.files.count {
                    Text("…等 \(run.uploaded - run.files.count) 个文件")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 22)
            .padding(.top, 1)
        }
    }

    /// 一轮的文件按来源分组（category 首段），组按文件数降序
    private func groupedFiles(
        _ files: [SyncRunsRepo.RunFile]
    ) -> [(source: String, files: [SyncRunsRepo.RunFile], bytes: Int64)] {
        var groups: [String: [SyncRunsRepo.RunFile]] = [:]
        for file in files {
            let source = file.category?.split(separator: "/").first.map(String.init) ?? "其他"
            groups[source, default: []].append(file)
        }
        return groups
            .map { (source: $0.key, files: $0.value, bytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.files.count > $1.files.count }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 34))
                .foregroundStyle(Theme.backup.opacity(0.5))
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
        _ title: String, accent: Color, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 7, content: content)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill(accent)))
        }
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

    private func summaryBadge(_ text: String, color: Color = Theme.backup) -> some View {
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
                        .foregroundStyle(Theme.backup.opacity(0.8))
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
