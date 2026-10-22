import Foundation

/// One `--model` value an executor accepts, offered next to the free-text field. Suggestions only:
/// the field still takes any name, since every CLI also accepts full model ids it doesn't list.
public struct SummaryModelOption: Equatable, Identifiable, Sendable {
    /// Exactly what is passed as `--model`
    public var value: String
    /// Display name when the CLI has one that differs from the value
    public var label: String?
    /// The CLI's configured default (what an empty field runs)
    public var isDefault: Bool

    public var id: String { value }

    public init(value: String, label: String? = nil, isDefault: Bool = false) {
        self.value = value
        self.label = label
        self.isDefault = isDefault
    }
}

/// Where each executor's model list comes from — each CLI's own data, never a list we maintain:
/// - Claude Code: the aliases its `--help` names for `--model` (2.1.306: "e.g. 'fable', 'opus',
///   or 'sonnet'"); it has no command that lists models, and full ids are still accepted.
/// - Codex: `models_cache.json` beside `config.toml`, which Codex refreshes itself; entries with
///   `visibility: "list"` in `priority` order are what its own picker shows. The top-level
///   `model` in `config.toml` is marked as the default.
/// - OpenCode: `opencode models`, one `provider/model` per line (about 11 s on a cold cache, so
///   it only runs when the user opens the list).
public enum SummaryModelCatalog {
    public static let claudeAliases = ["fable", "opus", "sonnet"]

    /// Loads the suggestions for a resolved executor (call on a background queue).
    /// `codexConfigURL` is Codex's `config.toml`; its cache sits in the same directory.
    public static func load(
        for executor: ResolvedExecutor,
        codexConfigURL: URL?,
        probe: SummaryExecutorResolver.Probe = SummaryExecutorResolver.runProbe
    ) -> [SummaryModelOption] {
        switch executor.kind {
        case .claude:
            return claudeAliases.map { SummaryModelOption(value: $0) }
        case .codex:
            guard let configURL = codexConfigURL else { return [] }
            let cacheURL = configURL.deletingLastPathComponent().appendingPathComponent("models_cache.json")
            let defaultModel = (try? String(contentsOf: configURL, encoding: .utf8))
                .flatMap(codexDefaultModel(configTOML:))
            guard let data = try? Data(contentsOf: cacheURL) else {
                return defaultModel.map { [SummaryModelOption(value: $0, isDefault: true)] } ?? []
            }
            return codexModels(cacheJSON: data, defaultModel: defaultModel)
        case .opencode:
            // A timed-out probe still returns what was printed; partial lines are dropped
            guard let result = probe(executor.path, ["models"], executor.environment) else { return [] }
            return opencodeModels(output: result.output)
        }
    }

    /// Codex's own picker list: `visibility == "list"` entries by ascending `priority`, with the
    /// configured default marked (and prepended when the cache doesn't list it)
    public static func codexModels(cacheJSON: Data, defaultModel: String?) -> [SummaryModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: cacheJSON) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return defaultModel.map { [SummaryModelOption(value: $0, isDefault: true)] } ?? []
        }
        let listed = models
            .filter { ($0["visibility"] as? String) == "list" }
            .compactMap { entry -> (option: SummaryModelOption, priority: Int)? in
                guard let slug = entry["slug"] as? String, !slug.isEmpty else { return nil }
                let name = entry["display_name"] as? String
                return (SummaryModelOption(
                    value: slug,
                    label: name == slug ? nil : name,
                    isDefault: slug == defaultModel),
                        entry["priority"] as? Int ?? Int.max)
            }
            .sorted { $0.priority < $1.priority }
            .map(\.option)
        if let defaultModel, !listed.contains(where: { $0.value == defaultModel }) {
            return [SummaryModelOption(value: defaultModel, isDefault: true)] + listed
        }
        return listed
    }

    /// The top-level `model = "…"` of a Codex `config.toml` (keys inside `[tables]` are ignored)
    public static func codexDefaultModel(configTOML: String) -> String? {
        for rawLine in configTOML.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("model"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
                  let close = value.dropFirst().firstIndex(of: quote) else { return nil }
            let model = String(value[value.index(after: value.startIndex)..<close])
            return model.isEmpty ? nil : model
        }
        return nil
    }

    /// `opencode models` lines that look like `provider/model`; banners, warnings and blank lines
    /// are skipped, duplicates dropped, order kept
    public static func opencodeModels(output: String) -> [SummaryModelOption] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let slash = line.firstIndex(of: "/"), slash != line.startIndex,
                  line.index(after: slash) != line.endIndex,
                  !line.contains(where: \.isWhitespace),
                  seen.insert(line).inserted else { return nil }
            return SummaryModelOption(value: line)
        }
    }
}
