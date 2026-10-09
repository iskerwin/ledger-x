import SwiftUI
import LedgerKit

/// 界面语言：跟随系统 / 简体中文 / English
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }
    static let key = "ledger.language"

    static var stored: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    /// the language actually shown
    static var current: AppLanguage {
        var s = stored
        if s == .system { s = (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh") ? .zh : .en }
        if KitLocale.chinese != (s != .en) { KitLocale.chinese = s != .en }   // LedgerKit labels follow along
        return s
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

enum Strings {
    /// zh → en, from en.json in the app bundle
    static let en: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }()
    /// keys ending in "：" translate a message prefix ("账户未开立：Assets:X")
    static let prefixes: [(String, String)] = en.filter { $0.key.hasSuffix("：") }.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
}

/// Translate a Chinese UI string. `%@` in the key stands for each argument, in order;
/// a translation may use `%1$@`, `%2$@` to reorder them.
func LS(_ key: String, _ args: Any...) -> String {
    var s = key
    if AppLanguage.current == .en {
        if let t = Strings.en[key] {
            s = t
        } else if let p = Strings.prefixes.first(where: { key.hasPrefix($0.0) }) {
            s = p.1 + key.dropFirst(p.0.count)
        }
    }
    if args.isEmpty { return s }
    let strs = args.map { "\($0)" }
    for (i, a) in strs.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
    var out = ""
    var idx = 0
    var rest = Substring(s)
    while let r = rest.range(of: "%@") {
        out += rest[..<r.lowerBound]
        out += idx < strs.count ? strs[idx] : ""
        idx += 1
        rest = rest[r.upperBound...]
    }
    return out + rest
}

/// English names for account groups (Chinese uses LedgerKit's ZH table)
func groupName(_ g: String) -> String {
    if AppLanguage.current != .en { return ZH[g] ?? g }
    let en = ["Bank": "Bank Accounts", "EWallet": "E-Wallets", "Cash": "Cash", "Brokerage": "Brokerage", "Crypto": "Crypto",
              "Receivable": "Receivables", "CreditCard": "Credit Cards", "Loan": "Loans",
              "Assets": "Assets", "Liabilities": "Liabilities", "Income": "Income", "Expenses": "Expenses", "Equity": "Equity"]
    return en[g] ?? g
}

extension SavedQuery {
    /// built-in query names are translated
    var title: String { source == "builtin" ? LS(name) : name }
}

/// Picker for 设置 → 语言
struct LanguagePicker: View {
    @EnvironmentObject var store: Store
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.system.rawValue
    var body: some View {
        Picker(LS("语言"), selection: $lang) {
            ForEach(AppLanguage.allCases) { Text($0.name).tag($0.rawValue) }
        }
        .onChange(of: lang) { _, _ in
            AppLanguage.apply()
            Task { await store.rebuild(quietly: true) }   // messages computed by LedgerKit
        }
    }
}
