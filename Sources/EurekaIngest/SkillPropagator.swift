import Foundation

/// 技能跨源传播：把一个技能目录完整复制到另一个 agent 的技能根。
///
/// 12/14 个源的技能是字节级同构的 `<目录>/SKILL.md`（frontmatter name/description），
/// 所以"安装到另一个源"就是目录复制 —— 不改写内容、不碰任何配置文件，
/// 失败最多留下一个目标 CLI 读不懂的目录，可随时废纸篓删除。
///
/// 复制的剪枝口径与扫描不同：扫描剪掉 references/scripts/assets 是因为里面不会有
/// **独立技能**，但它们正是技能自带的素材，复制时必须保留；这里只剪依赖/缓存目录
/// 和隐藏项（.git 等由隐藏规则覆盖）。
public enum SkillPropagator {
    public enum PropagationError: Error, LocalizedError, Equatable {
        /// 目标根下已有同名技能目录（含停用区同名也算，避免"装上了却被停用区遮蔽"的错觉）
        case alreadyExists(String)
        /// 源目录里没有 SKILL.md（不是一个合法技能目录）
        case missingSkillFile(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let path): return "目标已存在同名技能：\(path)"
            case .missingSkillFile(let path): return "源目录缺少 SKILL.md：\(path)"
            }
        }
    }

    /// 复制时整棵跳过的目录（依赖 / 缓存；隐藏目录另有统一规则）
    static let prunedDirs: Set<String> = [
        "node_modules", "venv", "site-packages", "__pycache__",
    ]

    /// 把 `skillDirectory` 复制为 `targetRoot/<slug>`（slug 缺省 = 源目录名）。
    /// 返回目标技能目录。
    ///
    /// `overwrite = false`（默认）：目标已存在（启用区或停用区）则抛错——安装新技能的语义。
    /// `overwrite = true`：**覆盖更新**——先把新版整树复制进隐藏暂存目录（扫描器
    /// skipsHiddenFiles 看不到半成品），旧版移入废纸篓（可找回；废纸篓不可用时退回
    /// 隐藏备份目录），再把暂存换入。目标此前在停用区就更新停用区，不改变启停状态。
    @discardableResult
    public static func install(
        skillDirectory: URL, into targetRoot: URL, slug: String? = nil,
        overwrite: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let source = skillDirectory.standardizedFileURL
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw PropagationError.missingSkillFile(source.path)
        }
        let name = slug ?? source.lastPathComponent
        let dest = targetRoot.appendingPathComponent(name, isDirectory: true)
        let disabledTwin = SkillMemoryIndexer.disabledRoot(for: targetRoot)
            .appendingPathComponent(name, isDirectory: true)
        let existsEnabled = fm.fileExists(atPath: dest.path)
        let existsDisabled = fm.fileExists(atPath: disabledTwin.path)
        if !overwrite {
            if existsEnabled { throw PropagationError.alreadyExists(dest.path) }
            if existsDisabled { throw PropagationError.alreadyExists(disabledTwin.path) }
        }
        // 停用区同名且启用区没有 → 就地更新停用区，不悄悄"顺便启用"
        let finalDest = (!existsEnabled && existsDisabled) ? disabledTwin : dest

        // 先复制进隐藏暂存目录：复制半途失败时旧版一个字节都没动
        let staging = targetRoot.appendingPathComponent(
            ".\(name).eureka-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try copyTree(from: source, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if fm.fileExists(atPath: finalDest.path) {
            do {
                try fm.trashItem(at: finalDest, resultingItemURL: nil)
            } catch {
                // 无废纸篓的卷（网络盘/临时目录等）：退回隐藏备份，扫描器同样看不到
                let backup = targetRoot.appendingPathComponent(
                    ".\(name).eureka-replaced", isDirectory: true)
                try? fm.removeItem(at: backup)
                try fm.moveItem(at: finalDest, to: backup)
            }
        }
        try fm.moveItem(at: staging, to: finalDest)
        return finalDest
    }

    /// 递归复制目录树：跳过隐藏项与剪枝目录；符号链接不跟随（技能不该带链接，防越界复制）
    private static func copyTree(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        for child in children {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let target = dest.appendingPathComponent(name)
            if values?.isDirectory == true {
                if prunedDirs.contains(name) { continue }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: child, to: target)
            } else {
                try fm.copyItem(at: child, to: target)
            }
        }
    }
}
