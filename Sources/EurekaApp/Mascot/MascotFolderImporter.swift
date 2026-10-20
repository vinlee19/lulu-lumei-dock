import EurekaKit
import Foundation

/// Imports a user's own pet folder as a new UI-editable companion under mascots/.
///
/// Two kinds of folder are accepted:
/// - with a `manifest.json`: validated first (a blocking problem aborts with the reasons), then the
///   manifest and only the files it references are copied, and the pack is marked editable
/// - without one: images are bound to states by file name (`MascotFolderMapper`); still images go
///   through the usual import (≤ 512px, optional background removal), GIF / APNG are kept as is
///
/// The source folder is only read. A failed import removes its half-built pack directory.
enum MascotFolderImporter {
    static let maxFiles = 300

    struct Report: Equatable {
        var packID: String
        var name: String
        /// State → source files it was bound to (relative to the chosen folder)
        var bound: [MascotState: [String]]
        var unmatched: [String]
        /// idle had no art of its own and reused this (a file or a state name)
        var idleBorrowedFrom: String?
        var fromManifest: Bool
        /// Non-blocking manifest problems (missing files, unknown states)
        var warnings: [MascotManifestValidator.Issue]
    }

    static func importFolder(
        _ folder: URL, into root: URL, removeBackground: Bool
    ) throws -> Report {
        let fm = FileManager.default
        let files = relativeFiles(in: folder, maxDepth: 3)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let dirName = directoryName(for: folder.lastPathComponent, existing: existing)
        let dest = root.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        do {
            var report = files.contains("manifest.json")
                ? try importManifestPack(from: folder, files: files, into: dest)
                : try importNamedImages(
                    from: folder, files: files, into: dest, removeBackground: removeBackground)
            report.packID = MascotPackRef.custom(dirName).id
            return report
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    // MARK: - Folder with a manifest

    private static func importManifestPack(
        from folder: URL, files: [String], into dest: URL
    ) throws -> Report {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else {
            throw MascotImportError.unreadable
        }
        let issues = MascotManifestValidator.validate(data, existingFiles: Set(files))
        let blocking = issues.filter(\.isBlocking)
        if !blocking.isEmpty {
            throw MascotImportError.invalidManifest(
                blocking.map(describe).joined(separator: L10n.text("; ", zhHans: "；")))
        }
        let fm = FileManager.default
        let referenced = MascotManifestEditor.referencedFiles(data).intersection(files)
        guard referenced.count <= maxFiles else { throw MascotImportError.tooManyFiles }
        for path in referenced.sorted() {
            // Only plain relative paths inside the folder; a manifest pointing at ../ stays out
            let parts = path.split(separator: "/").map(String.init)
            guard parts.allSatisfy(MascotPackRef.isSafeDirectoryName) else { continue }
            let source = folder.appendingPathComponent(path)
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= MascotImageImporter.maxFileBytes else {
                throw MascotImportError.tooLarge
            }
            let target = dest.appendingPathComponent(path)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                throw MascotImportError.writeFailed
            }
        }
        let marked = try MascotManifestEditor.markingUpload(data)
        try marked.write(to: dest.appendingPathComponent("manifest.json"), options: .atomic)
        return Report(
            packID: "",
            name: MascotManifestEditor.name(data) ?? folder.lastPathComponent,
            bound: MascotManifestEditor.stateSources(data),
            unmatched: [], idleBorrowedFrom: nil, fromManifest: true,
            warnings: issues.filter { !$0.isBlocking })
    }

    // MARK: - Folder of named images

    private static func importNamedImages(
        from folder: URL, files: [String], into dest: URL, removeBackground: Bool
    ) throws -> Report {
        let mapping = MascotFolderMapper.map(files)
        guard !mapping.states.isEmpty else { throw MascotImportError.noImagesFound }
        guard mapping.states.values.reduce(0, { $0 + $1.count }) <= maxFiles else {
            throw MascotImportError.tooManyFiles
        }
        var imported: [MascotState: [String]] = [:]
        for (state, sources) in mapping.states {
            imported[state] = try sources.enumerated().map { index, path in
                try MascotImageImporter.importImage(
                    from: folder.appendingPathComponent(path), into: dest, state: state,
                    frame: sources.count > 1 ? index + 1 : nil,
                    removeBackground: removeBackground)
            }
        }
        let hasFrames = imported.values.contains { $0.count > 1 }
        let name = MascotUploadNaming.displayName(fromFileName: folder.lastPathComponent)
        let manifest = MascotManifestEditor.makeUploadManifest(
            name: name, states: imported, fps: hasFrames ? 6 : 2)
        try manifest.write(to: dest.appendingPathComponent("manifest.json"), options: .atomic)
        return Report(
            packID: "", name: name, bound: mapping.states, unmatched: mapping.unmatched,
            idleBorrowedFrom: mapping.idleBorrowedFrom, fromManifest: false, warnings: [])
    }

    // MARK: - Helpers

    /// Regular, non-hidden files under `dir` as relative paths, at most `maxDepth` levels deep
    /// (capped, so pointing at a huge folder by mistake stays cheap)
    static func relativeFiles(in dir: URL, maxDepth: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = dir.standardizedFileURL.pathComponents.count
        var result: [String] = []
        for case let url as URL in enumerator {
            let components = url.standardizedFileURL.pathComponents
            let depth = components.count - base
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            result.append(components.suffix(depth).joined(separator: "/"))
            if result.count >= maxFiles * 2 { break }
        }
        return result.sorted()
    }

    /// The folder's own name when it is a safe directory name, otherwise a timestamped one;
    /// a clash gets -2, -3…
    static func directoryName(for folderName: String, existing: Set<String>) -> String {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MascotPackRef.isSafeDirectoryName(trimmed), !trimmed.hasPrefix("upload-") else {
            return MascotUploadNaming.directoryName(now: Date(), existing: existing)
        }
        guard existing.contains(trimmed) else { return trimmed }
        var index = 2
        while existing.contains("\(trimmed)-\(index)") { index += 1 }
        return "\(trimmed)-\(index)"
    }

    static func describe(_ issue: MascotManifestValidator.Issue) -> String {
        switch issue {
        case .malformed:
            return L10n.text("manifest.json is not valid JSON", zhHans: "manifest.json 不是合法的 JSON")
        case .noIdle:
            return L10n.text(
                "no usable idle art (states.idle or variants.idle)",
                zhHans: "缺少可用的基础形象 idle（states.idle 或 variants.idle）")
        case .missingFile(let state, let file):
            return L10n.format(
                "%1$@: file %2$@ not found", zhHans: "%1$@：找不到文件 %2$@", state, file)
        case .unknownState(let state):
            return L10n.format(
                "unknown state \"%@\"", zhHans: "未知状态「%@」", state)
        }
    }
}
