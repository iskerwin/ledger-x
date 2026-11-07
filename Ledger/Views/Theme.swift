import SwiftUI
import UIKit
import Observation
import LedgerKit

/// accent colours: none of them the green of money in, the red of money out or the orange of a warning, each
/// readable as text (yellow wasn't); the original jade and the new plum set by hand for light and dark
enum AppTheme: String, CaseIterable, Identifiable {
    case jade, blue, indigo, purple, plum, graphite
    var id: String { rawValue }

    static let key = "ledger.theme"
    static var current: AppTheme { AppTheme(rawValue: AppSettings.shared.theme) ?? .jade }

    /// a theme kept from before 1.0.10 to the nearest one still offered: red and pink to plum, the rest to jade
    static func migrated(_ raw: String) -> String {
        if AppTheme(rawValue: raw) != nil { return raw }
        return ["red", "pink"].contains(raw) ? AppTheme.plum.rawValue : AppTheme.jade.rawValue
    }

    var name: String {
        switch self {
        case .jade: return LS("翡翠")
        case .blue: return LS("蓝色")
        case .indigo: return LS("靛蓝")
        case .purple: return LS("紫色")
        case .plum: return LS("梅")
        case .graphite: return LS("石墨")
        }
    }

    var uiColor: UIColor {
        switch self {
        case .jade:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0x4F / 255, green: 0xB5 / 255, blue: 0x98 / 255, alpha: 1)
                : UIColor(red: 0x2B / 255, green: 0x80 / 255, blue: 0x6A / 255, alpha: 1) }
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .plum:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0xE0 / 255, green: 0x7A / 255, blue: 0xB5 / 255, alpha: 1)
                : UIColor(red: 0xA6 / 255, green: 0x37 / 255, blue: 0x7A / 255, alpha: 1) }
        case .graphite: return .systemGray
        }
    }

    var color: Color { Color(uiColor: uiColor) }
    /// text on a filled accent background
    var onColor: Color { color.onFill }
}

/// The app's display settings (theme, language, hidden amounts). Observable: a view that read one of
/// them while drawing — through Color.jade, LS() or money() — is redrawn in place when it changes, so
/// open pages, scroll positions and the toolbar stay as they are. Saved to UserDefaults as before.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    var theme: String = AppTheme.migrated(UserDefaults.standard.string(forKey: AppTheme.key) ?? AppTheme.jade.rawValue) {
        didSet { UserDefaults.standard.set(theme, forKey: AppTheme.key) }
    }
    var language: String = UserDefaults.standard.string(forKey: AppLanguage.key) ?? AppLanguage.system.rawValue {
        didSet {
            UserDefaults.standard.set(language, forKey: AppLanguage.key)
            AppLanguage.apply()
        }
    }
    /// a single expense this large (base currency) is flagged in 值得留意; 0 = never
    var largeExpense: Double = UserDefaults.standard.object(forKey: "ledger.alerts.large") as? Double ?? 2000 {
        didSet { UserDefaults.standard.set(largeExpense, forKey: "ledger.alerts.large") }
    }
    /// 代码配色 (CodeTheme)
    var codeTheme: String = UserDefaults.standard.string(forKey: CodeTheme.key) ?? CodeTheme.system.rawValue {
        didSet { UserDefaults.standard.set(codeTheme, forKey: CodeTheme.key) }
    }
    var haptics: Bool = UserDefaults.standard.object(forKey: "ledger.feedback.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(haptics, forKey: "ledger.feedback.enabled") }
    }
    var hapticStrength: Int = UserDefaults.standard.object(forKey: "ledger.feedback.strength") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(hapticStrength, forKey: "ledger.feedback.strength") }
    }
    /// how a transaction row looks in every list (JournalStyle)
    var journalStyle: String = UserDefaults.standard.string(forKey: JournalStyle.key) ?? JournalStyle.plain.rawValue {
        didSet { UserDefaults.standard.set(journalStyle, forKey: JournalStyle.key) }
    }
    /// how the top of an account's page is drawn (AccountCardStyle)
    var accountCardStyle: String = UserDefaults.standard.string(forKey: AccountCardStyle.key) ?? AccountCardStyle.plain.rawValue {
        didSet { UserDefaults.standard.set(accountCardStyle, forKey: AccountCardStyle.key) }
    }
    /// 金额数字: rounded digits for the amounts in lists and summaries too (the big ones always were)
    var roundedAmounts: Bool = UserDefaults.standard.bool(forKey: "ledger.amounts.rounded") {
        didSet { UserDefaults.standard.set(roundedAmounts, forKey: "ledger.amounts.rounded") }
    }
    var privacy: Bool = UserDefaults.standard.bool(forKey: "ledger.privacy") {
        didSet {
            UserDefaults.standard.set(privacy, forKey: "ledger.privacy")
            KitPrivacy.masked = privacy
        }
    }
}

/// 明细样式: 简洁 (words only, as it always was), 图标 (the category's icon in front), 紧凑 (one line a transaction)
enum JournalStyle: String, CaseIterable, Identifiable {
    case plain, icon, compact
    var id: String { rawValue }
    static let key = "ledger.journal.style"
    static var current: JournalStyle { JournalStyle(rawValue: AppSettings.shared.journalStyle) ?? .plain }
    var name: String { self == .plain ? LS("简洁") : self == .icon ? LS("图标") : LS("紧凑") }
}

/// 账户卡片: 普通 (the card it always was) or 卡面 (the top of a credit card's, bank account's, wallet's or cash
/// page drawn as a card in its group's colour). The key is the one 信用卡账单 had, so a choice made then carries on.
enum AccountCardStyle: String, CaseIterable, Identifiable {
    case plain, card
    var id: String { rawValue }
    static let key = "ledger.card.style"
    static var current: AccountCardStyle { AccountCardStyle(rawValue: AppSettings.shared.accountCardStyle) ?? .plain }
    var name: String { self == .plain ? LS("普通") : LS("卡面") }
}

/// 外观：跟随系统 / 浅色 / 深色
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    static let key = "ledger.appearance"
    var name: String { self == .system ? LS("跟随系统") : self == .light ? LS("浅色") : LS("深色") }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}

extension Color {
    /// the accent colour chosen in 设置 → 外观
    static var jade: Color { AppTheme.current.color }
    static var jadeSoft: Color { AppTheme.current.color.opacity(0.28) }
    /// Text and thin marks need more contrast than a filled accent surface.
    static var jadeInk: Color { jade.readableInk }
    static var onJade: Color { AppTheme.current.onColor }
    /// semantic colours, independent of the theme: money in (income, inflow) is `gain`, money out (spending,
    /// outflow) is `loss`, on every page
    static let gain = Color(uiColor: .systemGreen).readableInk
    static let loss = Color(uiColor: .systemRed).readableInk
    static let warn = Color(uiColor: .systemOrange).readableInk

    /// a change: better green, worse red, unchanged grey. Up is better unless `upIsWorse` (spending: more is worse)
    static func change(_ d: Double, upIsWorse: Bool = false, tolerance: Double = 0.005) -> Color {
        if abs(d) <= tolerance { return .secondary }
        return (d > 0) != upIsWorse ? .gain : .loss
    }
}

extension View {
    /// an amount's digits: rounded when 设置 → 外观 → 金额数字 is 圆体, else the system's; Chinese is unchanged
    /// either way (only the digits and Latin letters have a rounded design)
    func amountDigits() -> some View { fontDesign(AppSettings.shared.roundedAmounts ? .rounded : nil) }
}

/// a round-rect SF Symbol badge, like the Settings app
extension Color {
    /// the light tint behind a badge, a chip or a notice in this colour: one strength everywhere (it was 0.12–0.15)
    var soft: Color { opacity(0.14) }

    /// Resolve against the actual light/dark fill, rather than guessing from a theme name.
    var onFill: Color {
        let fill = UIColor(self)
        return Color(uiColor: UIColor { traits in
            let light = fill.resolvedColor(with: traits).relativeLuminance
            return (light + 0.05) / 0.05 >= 1.05 / (light + 0.05) ? .black : .white
        })
    }

    /// Keep the hue, adjusting only as far as needed on the App's standard surfaces.
    var readableInk: Color {
        let original = UIColor(self)
        return Color(uiColor: UIColor { traits in
            let color = original.resolvedColor(with: traits)
            let surfaces = [UIColor.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground]
                .map { $0.resolvedColor(with: traits) }
            let backgrounds = surfaces.flatMap { [$0.relativeLuminance, color.blended(over: $0, opacity: 0.14).relativeLuminance] }
            func contrast(_ candidate: UIColor) -> Double {
                let value = candidate.relativeLuminance
                let soft = surfaces.map { candidate.blended(over: $0, opacity: 0.14).relativeLuminance }
                return (backgrounds + soft).map { (max(value, $0) + 0.05) / (min(value, $0) + 0.05) }.min() ?? 1
            }
            if contrast(color) >= 4.52 { return color }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let end: CGFloat = contrast(.black) >= contrast(.white) ? 0 : 1
            func mixed(_ amount: CGFloat) -> UIColor {
                UIColor(red: r + (end - r) * amount, green: g + (end - g) * amount,
                        blue: b + (end - b) * amount, alpha: 1)
            }
            var low: CGFloat = 0, high: CGFloat = 1
            for _ in 0..<20 {
                let middle = (low + high) / 2
                if contrast(mixed(middle)) >= 4.52 { high = middle } else { low = middle }
            }
            return mixed(high)
        })
    }
}

private extension UIColor {
    func blended(over background: UIColor, opacity: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: r * opacity + br * (1 - opacity), green: g * opacity + bg * (1 - opacity),
                       blue: b * opacity + bb * (1 - opacity), alpha: 1)
    }

    var relativeLuminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

struct IconBadge: View {
    let symbol: String
    var color: Color = .jade
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color.onFill)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// One row of 设置 (and the pages under it): the symbol on its badge, the title (with a line under it when there is
/// one), the value on the right, a chevron where the row opens something that isn't a navigation link
struct SettingsRow: View {
    let symbol: String
    let title: String
    var detail: String = ""
    var value: String = ""
    var color: Color = .jade
    var chevron = false

    var body: some View {
        HStack(spacing: AppSpacing.control) {
            IconBadge(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(title).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// grid of colour swatches for 设置 → 外观
struct ThemePicker: View {
    private var theme: String {
        get { AppSettings.shared.theme }
        nonmutating set { AppSettings.shared.theme = newValue }
    }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon), count: 6)
    var body: some View {
        LazyVGrid(columns: cols, spacing: AppSpacing.control) {
            ForEach(AppTheme.allCases) { t in
                Button {
                    withAnimation(AppMotion.quick) { theme = t.rawValue }
                    Haptics.selection()
                } label: {
                    VStack(spacing: AppSpacing.icon) {
                        ZStack {
                            Circle().fill(t.color).frame(width: 34, height: 34)
                            if theme == t.rawValue {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(t.onColor)
                            }
                        }
                        .overlay(Circle().strokeBorder(theme == t.rawValue ? t.color : .clear, lineWidth: 2).padding(-4))
                        Text(t.name).font(.caption2).foregroundStyle(theme == t.rawValue ? Color.primary : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
            }
        }
        .padding(.vertical, AppSpacing.icon)
    }
}

// MARK: - cards

/// a rounded card used for summary headers (sits in a List row with clear background)
struct Card<Content: View>: View {
    var padding: CGFloat = AppSpacing.content
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

extension View {
    /// a List row that draws its own card
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
    }

    /// iOS 26: let the tab bar shrink while scrolling
    @ViewBuilder func minimizingTabBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// laid out but not shown, read or tapped: keeps its place for a sibling shown in its stead
    @ViewBuilder func concealed(_ on: Bool) -> some View {
        if on { hidden() } else { self }
    }
}

/// small "label: value" figure used in summary cards
struct Figure: View {
    let label: String
    let value: String
    var color: Color = .primary
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: AppSpacing.detail) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().amountDigits().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6).sensitive()
        }
    }
}

/// The figures under a summary card's headline (收入 · 结余 · 净资产), side by side in equal columns, each label
/// over its amount. Amounts are never shrunk: when they no longer fit side by side (a long amount, a large text
/// size) the figures stack, each label over its amount, and the card grows instead.
struct FigureRow: View {
    struct Item {
        var label: String
        var value: String
        var color: Color = .primary
    }

    let items: [Item]
    /// where each column's label and amount sit in it: centred for a row of figures side by side (the calendar's
    /// 支出 · 收入 · 结余, the overview card's 收入 · 结余 · 净资产)
    var alignment: HorizontalAlignment = .leading
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    ForEach(items.indices, id: \.self) { i in
                        VStack(alignment: alignment, spacing: AppSpacing.detail) {
                            label(items[i])
                            value(items[i])
                        }
                        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                    }
                }
            }
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        label(items[i])
                        value(items[i])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func label(_ x: Item) -> some View {
        Text(x.label).font(.caption).foregroundStyle(.secondary)
    }

    private func value(_ x: Item) -> some View {
        Text(x.value).font(.subheadline.weight(.semibold)).monospacedDigit().amountDigits().foregroundStyle(x.color).sensitive()
    }
}
