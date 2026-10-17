import Foundation

/// Install state of one target config (Claude settings.json / Codex config.toml)
public enum InstallStatus: String, Sendable {
    /// Eureka entries are fully installed
    case installed
    /// Partially installed (e.g. only some hook events)
    case partial
    /// Someone else's config conflicts (e.g. an existing non-Eureka notify); never overwritten
    /// automatically
    case foreign
    /// Not installed
    case none
}
