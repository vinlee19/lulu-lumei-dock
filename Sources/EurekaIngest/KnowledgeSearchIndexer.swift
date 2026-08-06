import EurekaKit
import EurekaStore
import Foundation

/// 知识面全文索引器：挂在 SkillMemoryService / PlansService 扫描完成点（事件驱动，非定时），
/// 指纹（size+mtime）diff 增量重建。索引失败静默——面板会降级为元数据搜索，不挂功能。
///
/// 放在 `EurekaIngest`（而非计划草案写的 `EurekaApp`）：它只依赖 `EurekaStore`/`Foundation`，
/// 与同层的 `SkillMemoryIndexer`/`PlanMaterializer` 是天然邻居；`eureka-tests` 也只到这一层——
/// SwiftPM 的 `.executableTarget` 互相依赖只对类型检查可见，链接期拿不到对方目标码
/// （`swift run eureka-tests` 实测必链接失败），纯函数测不了，故不能放 app 层。
public final class KnowledgeSearchIndexer {
    /// 单文件正文索引截断上限（计划文档可能很大；知识面搜索按头部命中足够）
    static let bodyCap = 256 * 1024

    public struct Doc: Equatable {
        public var kind: String
        public var path: String
        public var source: String
        public var title: String
        public var project: String?
        public var size: Int64
        public var mtime: Double
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.knowledge-index", qos: .utility)
    private var store: EurekaStore?

    public init() {}

    /// 条目 → doc 的纯映射（可测）；正文读取推迟到索引队列
    public static func docs(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) -> [Doc] {
        var result: [Doc] = []
        for skill in skills {
            result.append(Doc(
                kind: "skill", path: skill.path, source: skill.source.rawValue,
                title: skill.name, project: nil,
                size: Int64(skill.sizeBytes), mtime: skill.modifiedAt.timeIntervalSince1970))
        }
        for memory in memories {
            result.append(Doc(
                kind: memory.kind == .instructions ? "instruction" : "memory",
                path: memory.path, source: memory.source.rawValue,
                title: memory.title, project: memory.projectName,
                size: Int64(memory.sizeBytes), mtime: memory.modifiedAt.timeIntervalSince1970))
        }
        for plan in plans {
            result.append(Doc(
                kind: "plan", path: plan.path, source: plan.source.rawValue,
                title: plan.title, project: plan.project,
                size: Int64(plan.sizeBytes), mtime: plan.modifiedAt.timeIntervalSince1970))
        }
        return result
    }

    public func index(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) {
        let docs = Self.docs(skills: skills, memories: memories, plans: plans)
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else { return }
            let fingerprints = (try? store.knowledge.fileFingerprints()) ?? [:]
            var failures = 0
            for doc in docs {
                if let old = fingerprints[doc.path],
                   old.size == doc.size, old.mtime == doc.mtime { continue }
                guard var body = try? String(contentsOfFile: doc.path, encoding: .utf8)
                else { failures += 1; continue }
                if body.utf8.count > Self.bodyCap {
                    // 按字节截断（prefix 按 Character 数，纯中文会超上限 ~3 倍）；
                    // 尾部可能出一个 U+FFFD，对索引无害
                    body = String(decoding: body.utf8.prefix(Self.bodyCap), as: UTF8.self)
                }
                do {
                    try store.knowledge.replaceDoc(
                        path: doc.path, kind: doc.kind, source: doc.source, title: doc.title,
                        project: doc.project, size: doc.size, mtime: doc.mtime, body: body)
                } catch { failures += 1 }
            }
            try? store.knowledge.prune(keeping: Set(docs.map(\.path)))
            // 降级保持静默（面板退回元数据搜索），但失败要可诊断（磁盘满/库损坏/非 UTF-8）
            if failures > 0 {
                NSLog("KnowledgeSearchIndexer: %d/%d 篇正文索引失败", failures, docs.count)
            }
        }
    }
}
