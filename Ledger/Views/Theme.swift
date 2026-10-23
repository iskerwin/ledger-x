import SwiftUI
import UIKit
import Observation
import LedgerKit

/// accent colours; the Apple system palette plus the original jade
enum AppTheme: String, CaseIterable, Identifiable {
    case jade, blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, graphite
    var id: String { rawValue }

    static let key = "ledger.theme"
    static var current: AppTheme { AppTheme(rawValue: AppSettings.shared.theme) ?? .jade }

    var name: String {
        switch self {
        case .jade: return LS("翡翠")
        case .blue: return LS("蓝色")
        case .indigo: return LS("靛蓝")
        case .purple: return LS("紫色")
        case .pink: return LS("粉色")
        case .red: return LS("红色")
        case .orange: return LS("橙色")
        case .yellow: return LS("黄色")
        case .green: return LS("绿色")
        case .mint: return LS("薄荷")
        case .teal: return LS("青色")
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
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .graphite: return .systemGray
        }
    }

    var color: Color { Color(uiColor: uiColor) }
    /// text on a filled accent background
    var onColor: Color { self == .yellow || self == .mint ? .black : .white }
}

/// The app's display settings (theme, language, hidden amounts). Observable: a view that read one of
/// them while drawing — through Color.jade, LS() or money() — is redrawn in place when it changes, so
/// open pages, scroll positions and the toolbar stay as they are. Saved to UserDefaults as before.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    var theme: String = UserDefaults.standard.string(forKey: AppTheme.key) ?? AppTheme.jade.rawValue {
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
    var privacy: Bool = UserDefaults.standard.bool(forKey: "ledger.privacy") {
        didSet {
            UserDefaults.standard.set(privacy, forKey: "ledger.privacy")
            KitPrivacy.masked = privacy
        }
    }
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
    static var onJade: Color { AppTheme.current.onColor }
    /// semantic colours, independent of the theme
    static let gain = Color(uiColor: .systemGreen)
    static let loss = Color(uiColor: .systemRed)
    static let warn = Color(uiColor: .systemOrange)
}

/// a round-rect SF Symbol badge, like the Settings app
struct IconBadge: View {
    let symbol: String
    var color: Color = .jade
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
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
                            Circle().fill(t.color.gradient).frame(width: 34, height: 34)
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
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
    /// where each column's label and amount sit in it: leading under a card's headline, centred when the row
    /// stands alone (the calendar's 支出 · 收入 · 结余)
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
        Text(x.value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(x.color).sensitive()
    }
}
