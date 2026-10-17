import EurekaKit
import Foundation

/// Cross-source skill propagation: copies a whole skill directory into another agent's skills root.
///
/// For 12/14 sources a skill is a byte-identical `<dir>/SKILL.md` (frontmatter name/description),
/// so "install into another source" is just a directory copy: no content rewriting, no config files touched,
/// and a failure at worst leaves a directory the target CLI can't read, which can be trashed any time.
///
/// Copying prunes differently from scanning: the scan prunes references/scripts/assets because they never hold
/// **standalone skills**, but they are exactly the skill's own assets and must be kept when
/// copying; here we only prune dependency/cache directories and hidden entries (.git etc. are
/// covered by the hidden rule).
public enum SkillPropagator {
    public enum PropagationError: Error, LocalizedError, Equatable {
        /// A skill directory with the same name already exists under the target root (a same-named
        /// one in the disabled area counts too, to avoid the illusion of "installed but shadowed by
        /// the disabled area")
        case alreadyExists(String)
        /// The source directory has no SKILL.md (not a valid skill directory)
        case missingSkillFile(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let path): return L10n.format("A skill with the same name already exists at the destination: %@", zhHans: "目标已存在同名技能：%@", String(path))
            case .missingSkillFile(let path): return L10n.format("The source directory is missing SKILL.md: %@", zhHans: "源目录缺少 SKILL.md：%@", String(path))
            }
        }
    }

    /// Directories skipped wholesale when copying (dependencies / caches; hidden directories have
    /// their own rule)
    static let prunedDirs: Set<String> = [
        "node_modules", "venv", "site-packages", "__pycache__",
    ]

    /// Copies `skillDirectory` to `targetRoot/<slug>` (slug defaults to the source directory name).
    /// Returns the target skill directory.
    ///
    /// `overwrite = false` (default): throws if the target exists (enabled or disabled area); install-new-skill semantics.
    /// `overwrite = true`: **update in place**. First copy the new tree into a hidden staging directory (the scanner's
    /// skipsHiddenFiles can't see the half-built copy), move the old version to the Trash (recoverable; falls back to a
    /// hidden backup directory when the Trash is unavailable), then swap the staged copy in. A target in the disabled area is updated there, without changing its enabled state.
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
        // Same name in the disabled area and none in the enabled area → update the disabled area in
        // place, never silently "enable along the way"
        let finalDest = (!existsEnabled && existsDisabled) ? disabledTwin : dest

        // Copy into the hidden staging directory first: if the copy fails midway, the old version
        // is untouched
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
                // Volumes without a Trash (network drives / temp directories etc.): fall back to a
                // hidden backup, also invisible to the scanner
                let backup = targetRoot.appendingPathComponent(
                    ".\(name).eureka-replaced", isDirectory: true)
                try? fm.removeItem(at: backup)
                try fm.moveItem(at: finalDest, to: backup)
            }
        }
        try fm.moveItem(at: staging, to: finalDest)
        return finalDest
    }

    /// Recursively copy a directory tree: skip hidden entries and pruned directories; symlinks are
    /// not followed (skills shouldn't carry links; prevents copying outside the tree)
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
