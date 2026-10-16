import Foundation

/// 界面语言。
///
/// 英文是默认语言，也是新增文案的源语言。没有存过偏好、或存了一个不认识的值，都落在英文。
/// 简体中文是唯一的翻译。再加一种语言时，给这个枚举加一个 case，并给 `L10n.text` 补一条分支。
public enum AppLanguage: String, CaseIterable, Sendable, Equatable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// UserDefaults 键。稳定契约，不要改名。
    public static let defaultsKey = "appLanguage"

    public var locale: Locale { Locale(identifier: rawValue) }

    /// 语言在选择器里的自称。不随当前界面语言翻转，否则切到英文后找不到「简体中文」。
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
    /// `L10n.current` 已切到新语言。主菜单、灵动岛等不在 SwiftUI 设置树里的表面要自己重绘。
    static let eurekaLanguageDidChange = Notification.Name("eureka.languageDidChange")
}

/// 界面文案。英文是 key，也是默认显示；`zhHans` 必须是改动前的中文原文，测试套件钉在中文上。
///
/// 调用发生在读文案的那一刻，不要把结果存进 `static let`——那会把第一次的语言冻住。
/// 健康登记的名字是稳定键，展示走 `healthTitle`，不要翻译后再拿去 `register` / `beat`。
public enum L10n {
    // 这台机器的 Command Line Tools SDK 还没有 OSAllocatedUnfairLock。NSLock 够用：
    // 读文案发生在主线程和少数后台格式化上，临界区只有一次枚举读写。
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

    /// 读已保存的偏好。没有记录时是英文。GUI 与 CLI 都要在造任何界面文案之前调一次。
    public static func applyStoredPreference(defaults: UserDefaults = .standard) {
        current = AppLanguage.resolve(defaults.string(forKey: AppLanguage.defaultsKey))
    }

    public static func text(_ english: String, zhHans: String) -> String {
        switch current {
        case .english: return english
        case .simplifiedChinese: return zhHans
        }
    }

    /// 两个模板的占位符个数、顺序、类型必须一致。数字用 `%@` 传入 `String(n)`，
    /// 避免 `%d` 和 `Int` 宽度不一致。模板里的字面百分号写成 `%%`。
    public static func format(_ english: String, zhHans: String, _ args: CVarArg...) -> String {
        let template = text(english, zhHans: zhHans)
        return String(format: template, locale: current.locale, arguments: args)
    }

    /// `Text` 的字符串字面量会解析 Markdown；换成运行时字符串后要走这里，星号才不会漏到界面上。
    public static func markdown(_ english: String, zhHans: String) -> AttributedString {
        let value = text(english, zhHans: zhHans)
        return (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
    }
}
