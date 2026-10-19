import Foundation

/// Interface language.
///
/// English is the default and the source language for new copy. No saved preference, or an
/// unrecognized saved value, falls back to English. Simplified Chinese is the only translation. To
/// add a language, add a case to this enum and a branch to `L10n.text`.
public enum AppLanguage: String, CaseIterable, Sendable, Equatable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// UserDefaults key. A stable contract; do not rename.
    public static let defaultsKey = "appLanguage"

    public var locale: Locale { Locale(identifier: rawValue) }

    /// The language's own name in the picker. Does not follow the current UI language, or after
    /// switching to English nobody could find Simplified Chinese.
    public var endonym: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    public static func resolve(_ raw: String?) -> AppLanguage {
        guard let raw, let language = AppLanguage(rawValue: raw) else { return .english }
        return language
    }
}

public extension Notification.Name {
    /// `L10n.current` has switched to the new language. Surfaces outside the SwiftUI settings tree
    /// (main menu, Dynamic Island) must redraw themselves.
    static let eurekaLanguageDidChange = Notification.Name("eureka.languageDidChange")
}

/// UI copy. English is the key and the default display; `zhHans` must be the original Chinese text
/// from before the change, which the test suite pins.
///
/// Call this at the moment the copy is read; don't store the result in a `static let`, which would
/// freeze the first language. Health-registry names are stable keys; display them via
/// `healthTitle`, and never translate one before passing it to `register` / `beat`.
public enum L10n {
    // This machine's Command Line Tools SDK has no OSAllocatedUnfairLock yet. NSLock is enough:
    // copy is read on the main thread and in a few background formatters, and the critical section
    // is a single enum read/write.
    private static let lock = NSLock()
    private static var language = AppLanguage.english

    public static var current: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return language
        }
        set {
            lock.lock()
            language = newValue
            lock.unlock()
        }
    }

    /// Read the saved preference; English when nothing is recorded. Both GUI and CLI must call this
    /// once before building any UI copy.
    public static func applyStoredPreference(defaults: UserDefaults = .standard) {
        current = AppLanguage.resolve(defaults.string(forKey: AppLanguage.defaultsKey))
    }

    public static func text(_ english: String, zhHans: String) -> String {
        switch current {
        case .english: return english
        case .simplifiedChinese: return zhHans
        }
    }

    /// Both templates must have the same placeholder count, order, and types. Pass numbers as `%@`
    /// with `String(n)` to avoid width mismatches between `%d` and `Int`. Write a literal percent
    /// sign in a template as `%%`.
    public static func format(_ english: String, zhHans: String, _ args: CVarArg...) -> String {
        let template = text(english, zhHans: zhHans)
        return String(format: template, locale: current.locale, arguments: args)
    }

    /// `Text` parses Markdown in string literals; runtime strings must go through here so asterisks
    /// don't leak into the UI.
    public static func markdown(_ english: String, zhHans: String) -> AttributedString {
        let value = text(english, zhHans: zhHans)
        return (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
    }
}
