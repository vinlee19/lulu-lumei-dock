import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// 「计划」浏览服务：物化 Codex/opencode 计划到暂存，索引三源计划 .md（Claude 直接文件）。
/// 与 S3 同步共用同一批物化产物（`PlanMaterializer`）。只读浏览，不改写来源。
final class PlansService: ObservableObject {
    @Published private(set) var plans: [PlanMaterializer.PlanEntry] = []
    @Published private(set) var scanning = false

    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.plans", qos: .userInitiated)
    private var all: [PlanMaterializer.PlanEntry] = []

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let staging = PlanMaterializer.defaultStagingRoot()
            PlanMaterializer.materializeCodex(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), into: staging)
            PlanMaterializer.materializeOpencode(dbPath: OpencodePaths.db(), into: staging)
            PlanMaterializer.materializeGrok(
                sessionsRoot: GrokPaths.sessionsRoot(), into: staging)
            PlanMaterializer.materializeKimi(
                sessionsRoot: KimiPaths.sessionsRoot(), into: staging)
            let entries = PlanMaterializer.index(
                claudePlansDir: PlanMaterializer.defaultClaudePlansDir(), stagingRoot: staging)
            DispatchQueue.main.async {
                self.all = entries
                self.scanning = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            plans = all
            return
        }
        plans = all.filter { "\($0.title) \($0.path)".lowercased().contains(query) }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func plans(for source: AgentSource) -> [PlanMaterializer.PlanEntry] {
        plans.filter { $0.source == source }
    }

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// 原子写入：写前留 .bak.eureka.<ts> 备份（仅 Claude 计划是真实文件可编辑；
    /// 其它源为物化副本，改了也会被下一轮扫描覆盖——调用方负责只对 claude 开放）
    func save(path: String, content: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: path) {
                    let backup = path + ".bak.eureka.\(Int(Date().timeIntervalSince1970))"
                    try? fm.removeItem(atPath: backup)
                    try? fm.copyItem(atPath: path, toPath: backup)
                }
                try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                ok = true
            } catch {
                ok = false
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
        }
    }

    /// 删除计划 → 废纸篓（仅 Claude：真实文件；物化副本删了会被下一轮复原，不提供）
    func delete(_ entry: PlanMaterializer.PlanEntry, completion: ((Bool) -> Void)? = nil) {
        guard entry.source == .claude else { completion?(false); return }
        queue.async { [weak self] in
            let ok = (try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)) != nil
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
        }
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
