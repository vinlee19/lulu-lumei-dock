import Foundation
import EurekaKit

func localizationTests(_ t: TestRunner) {
    t.suite("Localization")

    t.test("缺省与无法识别的偏好都是英文") {
        let previous = L10n.current
        defer { L10n.current = previous }
        let defaults = UserDefaults(suiteName: "eureka.l10n.tests")!
        defaults.removePersistentDomain(forName: "eureka.l10n.tests")
        defer { defaults.removePersistentDomain(forName: "eureka.l10n.tests") }

        L10n.applyStoredPreference(defaults: defaults)
        try expectEqual(L10n.current, .english)

        defaults.set("zh-Hans", forKey: AppLanguage.defaultsKey)
        L10n.applyStoredPreference(defaults: defaults)
        try expectEqual(L10n.current, .simplifiedChinese)

        defaults.set("fr", forKey: AppLanguage.defaultsKey)
        L10n.applyStoredPreference(defaults: defaults)
        try expectEqual(L10n.current, .english)
        try expectEqual(AppLanguage.resolve(nil), .english)
    }

    t.test("英文是默认文案，中文走 zhHans") {
        let previous = L10n.current
        defer { L10n.current = previous }

        L10n.current = .english
        try expectEqual(L10n.text("History", zhHans: "历史"), "History")
        try expectEqual(
            L10n.format("%@s ago", zhHans: "%@秒前", "6"),
            "6s ago")

        L10n.current = .simplifiedChinese
        try expectEqual(L10n.text("History", zhHans: "历史"), "历史")
        try expectEqual(
            L10n.format("%@s ago", zhHans: "%@秒前", "6"),
            "6秒前")
    }

    t.test("健康登记键只在展示时翻译") {
        let previous = L10n.current
        defer { L10n.current = previous }

        L10n.current = .english
        try expectEqual(L10n.healthTitle("用量扫描 Claude"), "Usage scan Claude")
        try expectEqual(L10n.healthTitle("not-registered"), "not-registered")

        L10n.current = .simplifiedChinese
        try expectEqual(L10n.healthTitle("云端备份"), "云端备份")
        try expectEqual(L10n.healthTitle("not-registered"), "not-registered")
    }

    t.test("语言自称不随当前界面语言翻转") {
        try expectEqual(AppLanguage.english.endonym, "English")
        try expectEqual(AppLanguage.simplifiedChinese.endonym, "简体中文")
    }
}
