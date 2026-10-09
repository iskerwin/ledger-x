import SwiftUI
import UIKit

/// accent colours; the Apple system palette plus the original jade
enum AppTheme: String, CaseIterable, Identifiable {
    case jade, blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, graphite
    var id: String { rawValue }

    static let key = "ledger.theme"
    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .jade }

    var name: String {
        switch self {
        case .jade: return "翡翠"
        case .blue: return "蓝色"
        case .indigo: return "靛蓝"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .mint: return "薄荷"
        case .teal: return "青色"
        case .graphite: return "石墨"
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

/// 外观：跟随系统 / 浅色 / 深色
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    static let key = "ledger.appearance"
    var name: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
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
    @AppStorage(AppTheme.key) private var theme = AppTheme.jade.rawValue
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
    var body: some View {
        LazyVGrid(columns: cols, spacing: 14) {
            ForEach(AppTheme.allCases) { t in
                Button {
                    withAnimation(.snappy) { theme = t.rawValue }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 5) {
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
        .padding(.vertical, 8)
    }
}

// MARK: - cards

/// a rounded card used for summary headers (sits in a List row with clear background)
struct Card<Content: View>: View {
    var padding: CGFloat = 16
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

/// small "label: value" figure used in summary cards
struct Figure: View {
    let label: String
    let value: String
    var color: Color = .primary
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6).sensitive()
        }
    }
}
