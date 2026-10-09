import WidgetKit
import UIKit
import SwiftUI

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: context.isPreview ? (WidgetSnapshot.load() ?? .sample) : WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // the app pushes new data; refresh every few hours anyway
        let e = Entry(date: Date(), snap: WidgetSnapshot.load())
        completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(4 * 3600))))
    }
}

private func accent(_ theme: String) -> Color {
    switch theme {
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "mint": return .mint
    case "teal": return .teal
    case "graphite": return .gray
    default: return Color(red: 0x2B / 255, green: 0x80 / 255, blue: 0x6A / 255)
    }
}

private func fmt(_ n: Double, _ c: String, privacy: Bool, decimals: Int = 0) -> String {
    if privacy { return "••••" }
    let sym = ["CNY": "¥", "USD": "$", "HKD": "HK$", "EUR": "€", "GBP": "£"][c] ?? ""
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = decimals
    f.minimumFractionDigits = decimals
    return (n < 0 ? "-" : "") + sym + (f.string(from: NSNumber(value: abs(n))) ?? "\(n)")
}

private func t(_ zh: String, _ en: String, _ s: WidgetSnapshot?) -> String { (s?.english ?? false) ? en : zh }

struct LedgerWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        Group {
            if let s = entry.snap {
                switch family {
                case .systemMedium: medium(s)
                case .accessoryRectangular: rect(s)
                case .accessoryCircular: circular(s)
                default: small(s)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "chart.bar.fill").font(.title2).foregroundStyle(accent("jade"))
                    Text(t("打开 Ledger 以更新", "Open Ledger to update", nil)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(URL(string: "ledgerx://add"))
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    private func bar(_ ratio: Double, _ color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, ratio)))
            }
        }
        .frame(height: 6)
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        let c = accent(s.theme)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.month).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(c)
            }
            Spacer(minLength: 0)
            Text(t("本月支出", "Spent", s)).font(.caption).foregroundStyle(.secondary)
            Text(fmt(s.spent, s.currency, privacy: s.privacy)).font(.system(.title2, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.5).lineLimit(1)
            if s.budgetLimit > 0 {
                bar(s.budgetSpent / s.budgetLimit, s.budgetSpent > s.budgetLimit ? .red : c)
                Text(s.budgetSpent > s.budgetLimit
                     ? t("超支 ", "Over ", s) + fmt(s.budgetSpent - s.budgetLimit, s.currency, privacy: s.privacy)
                     : t("预算剩余 ", "Left ", s) + fmt(s.budgetLimit - s.budgetSpent, s.currency, privacy: s.privacy))
                    .font(.caption2).foregroundStyle(s.budgetSpent > s.budgetLimit ? .red : .secondary)
            } else {
                Text(t("上月 ", "Last month ", s) + fmt(s.lastMonth, s.currency, privacy: s.privacy)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        let c = accent(s.theme)
        return HStack(spacing: 14) {
            small(s).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                if s.budgets.isEmpty {
                    Text(t("收入", "Income", s)).font(.caption).foregroundStyle(.secondary)
                    Text(fmt(s.income, s.currency, privacy: s.privacy)).font(.headline).foregroundStyle(.green)
                    Text(t("结余", "Saved", s)).font(.caption).foregroundStyle(.secondary)
                    Text(fmt(s.income - s.spent, s.currency, privacy: s.privacy)).font(.headline)
                } else {
                    ForEach(s.budgets.prefix(3), id: \.self) { b in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(b.name).font(.caption2).lineLimit(1)
                                Spacer()
                                Text(s.privacy ? "" : String(format: "%.0f%%", b.ratio * 100)).font(.caption2.monospacedDigit())
                                    .foregroundStyle(b.over ? .red : .secondary)
                            }
                            bar(b.ratio, b.over ? .red : c)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func rect(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t("本月支出", "Spent this month", s)).font(.caption2)
            Text(fmt(s.spent, s.currency, privacy: s.privacy)).font(.headline)
            if s.budgetLimit > 0 { Gauge(value: min(1, s.budgetSpent / s.budgetLimit)) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity) }
        }
    }

    private func circular(_ s: WidgetSnapshot) -> some View {
        Gauge(value: s.budgetLimit > 0 ? min(1, s.budgetSpent / s.budgetLimit) : 0) {
            Image(systemName: "yensign")
        } currentValueLabel: {
            Text(s.budgetLimit > 0 ? String(format: "%.0f", s.budgetSpent / s.budgetLimit * 100) : "—")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

@main
struct LedgerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LedgerWidget", provider: Provider()) { e in LedgerWidgetView(entry: e) }
            .configurationDisplayName("Ledger")
            .description("本月支出与预算 · Spending and budget this month")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
