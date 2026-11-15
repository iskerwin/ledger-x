import Foundation
import LedgerKit

/// 设置 › 通用 › 语言: the system's (macOS's own list, or this app's in 系统设置 › 通用 › 语言与地区), or one chosen here
enum MacLanguage: String, CaseIterable {
    case system, zh, en
    static let key = "ledger.language"

    static var stored: MacLanguage { MacLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    /// the language shown
    static var current: MacLanguage {
        let s = stored
        guard s == .system else { return s }
        return (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") ? .zh : .en
    }

    var title: String {
        switch self {
        case .system: return LS("跟随系统")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    var locale: Locale { self == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN") }

    /// at launch and after the setting changes: the pages and LedgerKit's text at once, the menus the system draws
    /// (编辑 › 撤销) from the next launch
    static func apply() {
        KitLocale.chinese = current != .en
        switch stored {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .zh: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }
}

/// Translate a Chinese UI string (Ledger/en.json, shared with the phone). `%@` in the key stands for each argument, in
/// order; a translation may use `%1$@`, `%2$@` to reorder them.
func LS(_ key: String, _ args: Any...) -> String {
    KitStrings.text(key, args, english: !KitLocale.chinese)
}
