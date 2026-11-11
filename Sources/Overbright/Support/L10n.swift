import Foundation

/// Two languages, written side by side at the call site:
/// `L10n.tr("Quit", "退出")`. Add a language by adding a parameter here.
enum L10n {
    /// "auto", "en" or "zh". Set from the config.
    static var language = "auto"

    static var usesChinese: Bool {
        switch language {
        case "zh": return true
        case "en": return false
        default:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }

    static func tr(_ english: String, _ chinese: String) -> String {
        usesChinese ? chinese : english
    }
}
