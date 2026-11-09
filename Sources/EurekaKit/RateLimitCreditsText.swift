import Foundation

/// One-line description of a source's paid overflow for the limits card. Pure function so the
/// wording per source is testable; the view only lays it out.
public enum RateLimitCreditsText {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// Raw server reason code, shown as a tooltip when the text only says "off"
        public var help: String?
    }

    public static func line(for credits: RateLimitCredits, source: AgentSource) -> Line {
        switch source {
        case .claude: return claudeExtraUsage(credits)
        case .codex: return codexCredits(credits)
        case .grok: return grokPayAsYouGo(credits)
        default: return generic(credits)
        }
    }

    /// "$12.30" for USD (the app's cost format), "12.30 EUR" otherwise, plain number for credits
    public static func amount(_ value: Double, currency: String?) -> String {
        guard let currency else {
            return value == value.rounded()
                ? String(Int(value)) : String(format: "%.2f", value)
        }
        return currency == "USD"
            ? String(format: "$%.2f", value) : String(format: "%.2f %@", value, currency)
    }

    private static func claudeExtraUsage(_ credits: RateLimitCredits) -> Line {
        let used = credits.used.map { amount($0, currency: credits.currency) }
        if credits.isEnabled {
            if let used, let limit = credits.limit {
                return Line(text: L10n.format("Extra usage %@ / %@ this month", zhHans: "额外用量 %@ / %@（本月）", used, amount(limit, currency: credits.currency)))
            }
            return Line(text: L10n.format("Extra usage on · %@ used", zhHans: "额外用量已开启 · 已用 %@", used ?? amount(0, currency: credits.currency)))
        }
        var parts = [credits.disabledReason == "out_of_credits"
            ? L10n.text("Extra usage off · out of credits", zhHans: "额外用量未开启 · 余额用尽")
            : L10n.text("Extra usage off", zhHans: "额外用量未开启")]
        if let spent = credits.used, spent > 0, let used {
            parts.append(L10n.format("%@ used this month", zhHans: "本月已用 %@", used))
        }
        return Line(text: parts.joined(separator: " · "), help: credits.disabledReason)
    }

    private static func codexCredits(_ credits: RateLimitCredits) -> Line {
        if credits.isUnlimited {
            return Line(text: L10n.text("Credits: unlimited", zhHans: "积分不限量"))
        }
        return Line(text: L10n.format("Credits balance %@", zhHans: "积分余额 %@", amount(credits.balance ?? 0, currency: nil)))
    }

    private static func grokPayAsYouGo(_ credits: RateLimitCredits) -> Line {
        var parts: [String] = []
        let used = amount(credits.used ?? 0, currency: credits.currency)
        if let limit = credits.limit {
            parts.append(L10n.format("Pay-as-you-go %@ / %@", zhHans: "按量付费 %@ / %@", used, amount(limit, currency: credits.currency)))
        } else if credits.isEnabled || (credits.used ?? 0) > 0 {
            parts.append(L10n.format("Pay-as-you-go %@ used", zhHans: "按量付费 已用 %@", used))
        }
        if let balance = credits.balance {
            parts.append(L10n.format("Prepaid balance %@", zhHans: "预付余额 %@", amount(balance, currency: credits.currency)))
        }
        if parts.isEmpty {
            parts.append(L10n.text("Pay-as-you-go off", zhHans: "按量付费未开启"))
        }
        return Line(text: parts.joined(separator: " · "))
    }

    private static func generic(_ credits: RateLimitCredits) -> Line {
        var parts: [String] = []
        if let used = credits.used {
            parts.append(L10n.format("%@ used", zhHans: "已用 %@", amount(used, currency: credits.currency)))
        }
        if let balance = credits.balance {
            parts.append(L10n.format("Balance %@", zhHans: "余额 %@", amount(balance, currency: credits.currency)))
        }
        return Line(text: parts.isEmpty
            ? L10n.text("Credits", zhHans: "额度") : parts.joined(separator: " · "))
    }
}
