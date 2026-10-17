import CryptoKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import Foundation

/// Syncs the eureka-relay shipped with the app to the stable path `~/Library/Application
/// Support/Eureka/bin/lululumei-relay`. hooks/notify configs only ever reference the stable path →
/// upgrading/moving the app never breaks the link.
///
/// The pre-0.36 stable name `bin/eureka-relay` is kept as a symlink to the new file, so configs
/// written by older versions keep delivering events until they are migrated
/// (`HookDiagnosis.legacyRelayName`).
enum RelaySyncer {
    static var binDirectory: URL {
        SpoolPaths.root().appendingPathComponent("bin", isDirectory: true)
    }

    static var stableRelayURL: URL {
        binDirectory.appendingPathComponent(RelayIdentity.binaryName)
    }

    static var legacyRelayURL: URL {
        binDirectory.appendingPathComponent(RelayIdentity.legacyBinaryName)
    }

    /// The relay in the same directory as the current executable (holds for both .build/debug/ and
    /// lulu-lumei-dock.app/Contents/MacOS/)
    static var bundledRelayURL: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("eureka-relay")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Syncs (overwrites only when the content differs) and returns the stable path; nil when no
    /// source is found
    @discardableResult
    static func sync() -> URL? {
        guard let source = bundledRelayURL else { return nil }
        let target = stableRelayURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: target),
               let fresh = try? Data(contentsOf: source),
               SHA256.hash(data: existing) == SHA256.hash(data: fresh) {
                linkLegacyName()
                return target  // Already up to date
            }
            // Write a temp file first, then replace, to avoid overwriting a binary that is
            // currently executing
            let tmp = target.deletingLastPathComponent()
                .appendingPathComponent(".\(RelayIdentity.binaryName).tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            linkLegacyName()
            return target
        } catch {
            fputs(L10n.format("[eureka] relay sync failed: %@\n", zhHans: "[eureka] relay 同步失败: %@\n", String(describing: error)), stderr)
            return fm.fileExists(atPath: target.path) ? target : nil
        }
    }

    /// Points `bin/eureka-relay` at `lululumei-relay` with a relative symlink.
    ///
    /// The old binary there may be executing right now (a hook firing mid-upgrade), so it is
    /// replaced by `rename(2)` over it rather than deleted first: a running process keeps its
    /// inode, and a hook starting at that instant sees either the old file or the link, never
    /// a gap.
    private static func linkLegacyName() {
        let legacy = legacyRelayURL
        let destination = RelayIdentity.binaryName
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) == destination { return }
        let tmp = binDirectory.appendingPathComponent(".\(RelayIdentity.legacyBinaryName).link.tmp")
        do {
            try? fm.removeItem(at: tmp)
            try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: destination)
            guard rename(tmp.path, legacy.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            fputs(L10n.format(
                "[eureka] failed to update the legacy relay symlink: %@\n",
                zhHans: "[eureka] 旧名 relay 软链更新失败: %@\n",
                String(describing: error)), stderr)
        }
    }
}
