import Foundation

/// How installers recognise the relay they wrote, across the rename.
///
/// Up to 0.35 the stable path ended in `eureka-relay`; from 0.36 it is `lululumei-relay`,
/// a product-prefixed name nothing else on the machine is likely to share. Both names
/// must keep matching: uninstall has to remove entries an older version wrote, and the
/// legacy name stays on disk as a symlink to the new binary so those entries keep working
/// until they are migrated.
public enum RelayIdentity {
    /// File name at the stable path; every newly written config references it.
    public static let binaryName = "lululumei-relay"
    /// File name used up to 0.35. Kept at the stable path as a symlink to `binaryName`.
    public static let legacyBinaryName = "eureka-relay"

    /// Whether a hook command / notify line was written by us (either name).
    public static func isOurs(_ text: String) -> Bool {
        text.contains(binaryName) || text.contains(legacyBinaryName)
    }

    /// Whether `path` is the legacy-named sibling of the expected stable path.
    ///
    /// Only that exact sibling counts: it is our own previous stable path, so migrating it is
    /// safe to do automatically. Any other mismatch (an old app-bundle path, a hand edit)
    /// remains `.driftedPath`, which is never rewritten without the user asking.
    public static func isLegacyStablePath(_ path: String, expected: String) -> Bool {
        let found = URL(fileURLWithPath: path)
        let wanted = URL(fileURLWithPath: expected)
        return found.lastPathComponent == legacyBinaryName
            && wanted.lastPathComponent != legacyBinaryName
            && found.deletingLastPathComponent().path == wanted.deletingLastPathComponent().path
    }

    /// Splits our own commands by where they point; commands at the expected path are dropped.
    static func classify(
        commands: [String], expectedRelayPath: String
    ) -> (drifted: [String], legacy: [String]) {
        var drifted: [String] = []
        var legacy: [String] = []
        for command in commands {
            guard let path = HookCommandPath.extract(from: command) else {
                drifted.append(command)
                continue
            }
            if path == expectedRelayPath { continue }
            if isLegacyStablePath(path, expected: expectedRelayPath) {
                legacy.append(command)
            } else {
                drifted.append(command)
            }
        }
        return (drifted.sorted(), legacy.sorted())
    }
}
