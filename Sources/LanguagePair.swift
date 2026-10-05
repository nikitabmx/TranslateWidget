import Foundation

/// A directed translation pair (source → target) shown as a quick-switch button
/// in the widget's top bar.
struct LanguagePair: Equatable {
    let source: String
    let target: String

    var id: String { "\(source)-\(target)" }

    /// Compact button label, e.g. "RU → EN".
    var label: String {
        "\(LanguagePair.name(source)) → \(LanguagePair.name(target))"
    }

    static func name(_ code: String) -> String {
        switch code {
        case "ru": return "RU"
        case "en": return "EN"
        case "sr": return "SR"
        case "sl": return "SL"
        default: return code.uppercased()
        }
    }

    /// Full human-readable language name (English), shown in the pickers/status.
    static func displayName(_ code: String) -> String {
        switch code {
        case "ru": return "Russian"
        case "en": return "English"
        case "sr": return "Serbian"
        case "sl": return "Slovenian"
        case "auto": return "Detect language"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
        }
    }

    /// Popular pairs: RU/EN, RU/SR, EN/SR — both directions each.
    static let all: [LanguagePair] = [
        LanguagePair(source: "ru", target: "en"),
        LanguagePair(source: "en", target: "ru"),
        LanguagePair(source: "ru", target: "sr"),
        LanguagePair(source: "sr", target: "ru"),
        LanguagePair(source: "en", target: "sr"),
        LanguagePair(source: "sr", target: "en"),
    ]

    static let `default` = all[0]
}
