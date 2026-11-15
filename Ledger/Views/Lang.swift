import SwiftUI
import LedgerKit

/// 界面语言：跟随系统 / 简体中文 / English
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }
    static let key = "ledger.language"

    static var stored: AppLanguage { AppLanguage(rawValue: AppSettings.shared.language) ?? .system }

    /// the language actually shown
    static var current: AppLanguage {
        let s = stored
        return s == .system ? ((Locale.preferredLanguages.first ?? "zh").hasPrefix("zh") ? .zh : .en) : s
    }

    var name: String {
        switch self {
        case .system: return LS("跟随系统")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    var locale: Locale { self == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN") }

    /// call after the setting changes (and at launch)
    static func apply() {
        KitLocale.chinese = current != .en
    }
}

/// Translate a Chinese UI string. `%@` in the key stands for each argument, in order;
/// a translation may use `%1$@`, `%2$@` to reorder them.
func LS(_ key: String, _ args: Any...) -> String {
    KitStrings.text(key, args, english: AppLanguage.current == .en)
}

extension SavedQuery {
    /// built-in query names are translated
    var title: String { source == "builtin" ? LS(name) : name }
}

/// Picker for 设置 → 语言
struct LanguagePicker: View {
    @Environment(Store.self) var store
    /// with its badge, as a row of 设置
    var badge = false
    var body: some View {
        Picker(selection: Binding(get: { AppSettings.shared.language }, set: { AppSettings.shared.language = $0 })) {
            ForEach(AppLanguage.allCases) { Text($0.name).tag($0.rawValue) }
        } label: {
            if badge { SettingsRow(symbol: "globe", title: LS("语言")) } else { Text(LS("语言")) }
        }
        .onChange(of: AppSettings.shared.language) { _, _ in
            Task { await store.rebuild(quietly: true) }   // messages LedgerKit computed ahead (checks, links)
        }
    }
}
