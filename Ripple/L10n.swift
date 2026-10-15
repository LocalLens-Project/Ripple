import Foundation

enum AppLanguage: String {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static func resolve(_ preferredLanguages: [String]) -> AppLanguage {
        let primary = (preferredLanguages.first ?? "en").replacingOccurrences(of: "_", with: "-").lowercased()
        return primary == "zh" || primary.hasPrefix("zh-") ? .simplifiedChinese : .english
    }
}

enum L10n {
    static let language = AppLanguage.resolve(Locale.preferredLanguages)
    static var locale: Locale { Locale(identifier: language.rawValue) }
    static var appName: String { text("轻点 · Ripple", "Ripple") }

    static func configureProcessLanguage() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [language.rawValue]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
    }

    static func seconds(_ value: Double) -> String {
        String(format: text("%.2f 秒", "%.2f s"), locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func effectCount(_ count: Int) -> String {
        text("\(count) 个点击效果", "\(count) click effect\(count == 1 ? "" : "s")")
    }

    static func breathSummary(_ count: Int) -> String {
        text("\(count) 次呼吸 · 节奏自动适配\n半透明 / 空心 / 快速扩张后回弹",
             "\(count) breath\(count == 1 ? "" : "s") · Automatic timing\nTranslucent / Hollow / Expand and rebound")
    }
}
