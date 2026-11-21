import Foundation
import EurekaKit

/// WorkBuddy quota: zero network requests. WorkBuddy bills in credits; the balance lives only behind
/// its signed-in server API, which is never called. What is local is the per-model quota the server
/// echoes into each step's usage, `providerData.rawUsage.quota = {model, percent, reset_at,
/// shared_models}` in `~/.workbuddy/projects/**/*.jsonl` (null for paid models; seen for the free
/// `hy4` model). `percent` is the share used (it climbs 0 → 1 → 3 within one `reset_at` and starts
/// over after it), `reset_at` is epoch seconds about a day after first use.
///
/// The newest quota per model in recently written transcripts becomes one window each, kept in
/// `scopedWindows` like Antigravity's model groups: they are per model, so they add no forecast
/// samples. A window whose reset time has passed describes a quota that no longer exists and is
/// dropped; with none left the whole card hides.
public struct WorkBuddyQuotaProvider: RateLimitProvider {
    public let source = AgentSource.workbuddy
    private let projectsRoot: URL
    /// Transcripts last written longer ago than this are not read
    private let recentWindow: TimeInterval
    /// Bytes read from the end of each transcript
    private let tailBytes: UInt64

    public init(projectsRoot: URL, recentWindow: TimeInterval = 2 * 86400, tailBytes: UInt64 = 262_144) {
        self.projectsRoot = projectsRoot
        self.recentWindow = recentWindow
        self.tailBytes = tailBytes
    }

    public func snapshot() async -> RateLimitSnapshot? {
        snapshot(now: Date())
    }

    /// Same as `snapshot()` at a given time (tests pin the clock)
    public func snapshot(now: Date) -> RateLimitSnapshot? {
        var latest: [String: (asOf: Date, window: RateLimitWindow)] = [:]
        for file in recentTranscripts(now: now) {
            for (asOf, model, window) in Self.quotas(in: file, tailBytes: tailBytes)
            where (latest[model]?.asOf ?? .distantPast) < asOf {
                latest[model] = (asOf, window)
            }
        }
        let live = latest.filter { !$0.value.window.hasReset(at: now) }
        guard let asOf = live.values.map(\.asOf).max() else { return nil }
        return RateLimitSnapshot(
            source: .workbuddy, asOf: asOf,
            scopedWindows: live.sorted { $0.key < $1.key }.map(\.value.window),
            isStale: now.timeIntervalSince(asOf) > 600)
    }

    private func recentTranscripts(now: Date) -> [URL] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return projects.flatMap { dir -> [URL] in
            ((try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { file in
                    guard file.pathExtension == "jsonl",
                          let mtime = (try? file.resourceValues(
                            forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    else { return false }
                    return now.timeIntervalSince(mtime) < recentWindow
                }
        }
    }

    /// Every quota in the file's tail: (line time, model, window)
    static func quotas(
        in file: URL, tailBytes: UInt64
    ) -> [(asOf: Date, model: String, window: RateLimitWindow)] {
        guard let handle = FileHandle(forReadingAtPath: file.path),
              let size = try? handle.seekToEnd()
        else { return [] }
        defer { try? handle.close() }
        let length = min(size, tailBytes)
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return [] }
        let marker = Data("\"quota\":{".utf8)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            // Most lines carry `"quota":null`; skip them before parsing
            guard line.range(of: marker) != nil else { return nil }
            return parse(Data(line))
        }
    }

    static func parse(_ line: Data) -> (asOf: Date, model: String, window: RateLimitWindow)? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let providerData = root["providerData"] as? [String: Any],
              let quota = (providerData["rawUsage"] as? [String: Any])?["quota"] as? [String: Any],
              let model = quota["model"] as? String, !model.isEmpty,
              let percent = (quota["percent"] as? NSNumber)?.doubleValue,
              let millis = (root["timestamp"] as? NSNumber)?.doubleValue
        else { return nil }
        // reset_at arrives as a string of epoch seconds; accept a number too
        let resetSeconds = (quota["reset_at"] as? NSNumber)?.doubleValue
            ?? (quota["reset_at"] as? String).flatMap(Double.init)
        let window = RateLimitWindow(
            usedPercent: min(100, max(0, percent)),
            windowMinutes: 1440,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) },
            label: model)
        return (Date(timeIntervalSince1970: millis / 1000), model, window)
    }
}
