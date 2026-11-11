import SwiftUI
import Charts
import LedgerKit

/// the months to show a mark for: about eight labels however many there are
private func labelled(_ months: [String]) -> [String] {
    let step = months.count <= 8 ? 1 : months.count <= 14 ? 2 : 3
    return months.filter { ((Int($0.suffix(2)) ?? 1) - 1) % step == 0 }
}

private func monthNumber(_ month: String) -> String { String(Int(month.suffix(2)) ?? 0) + "月" }

/// how much an account held at each month's end; the pointer shows that month in the same place
struct BalanceChart: View {
    let points: [BalancePoint]
    let currency: String
    let current: Double
    /// what the figure over the line is, when it isn't the account's balance now
    var title: String?
    @State private var picked: String?

    var body: some View {
        let shown = points.first { $0.month == picked }
        let lo = points.map(\.amount).min() ?? 0, hi = points.map(\.amount).max() ?? 0
        let pad = max((hi - lo) * 0.1, 1)
        VStack(alignment: .leading, spacing: 12) {
            Headline(label: shown.map { $0.month + " 月末" } ?? title ?? "当前余额 · " + currency, value: money(shown?.amount ?? current, currency))
            Chart(points) { point in
                LineMark(x: .value("月份", point.month), y: .value("余额", point.amount))
                    .foregroundStyle(Color.jade)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if point.month == picked {
                    RuleMark(x: .value("月份", point.month))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("月份", point.month), y: .value("余额", point.amount))
                        .foregroundStyle(Color.jade)
                        .symbolSize(70)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: labelled(points.map(\.month))) { value in
                    AxisValueLabel { if let month = value.as(String.self) { Text(monthNumber(month)) } }
                }
            }
            .pickingMonth($picked)
            .frame(height: 180)
        }
    }
}

/// 月度收支, in the operating currency at each month's rates: a pair of bars a month. The figures are the latest month's, or the one under the pointer, in the same places.
struct FlowCard: View {
    let months: [String]
    let income: [String: Double]
    let expenses: [String: Double]
    let base: String
    @State private var picked: String?

    var body: some View {
        let month = picked ?? months.last
        let came = month.flatMap { income[$0] } ?? 0, went = month.flatMap { expenses[$0] } ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Headline(label: (month.map(monthNumber) ?? "") + "结余", value: money(came - went, base), color: came - went < 0 ? .loss : .primary)
            Chart {
                ForEach(months, id: \.self) { month in
                    BarMark(x: .value("月份", month), y: .value("金额", income[month] ?? 0))
                        .foregroundStyle(by: .value("类别", "收入"))
                        .position(by: .value("类别", "收入"))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == month ? 1 : 0.5)
                    BarMark(x: .value("月份", month), y: .value("金额", expenses[month] ?? 0))
                        .foregroundStyle(by: .value("类别", "支出"))
                        .position(by: .value("类别", "支出"))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == month ? 1 : 0.5)
                }
            }
            .chartForegroundStyleScale(["收入": Color.chartGain, "支出": Color.chartLoss])
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: labelled(months)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let month = value.as(String.self) { Text(monthNumber(month)) } }
                }
            }
            .pickingMonth($picked)
            .frame(height: 180)
            SummaryFigures(items: [("收入", money(came, base), .gain), ("支出", money(went, base), .loss)])
        }
    }
}

private extension View {
    func pickingMonth(_ picked: Binding<String?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let plot = proxy.plotFrame else { return }
                            picked.wrappedValue = proxy.value(atX: point.x - geometry[plot].minX, as: String.self)
                        case .ended:
                            picked.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

/// one piece of the spending: a category, or the rest together
struct DonutSlice: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
    /// false for the rest, which isn't one account to open
    let opens: Bool

    /// the largest six and the rest, each category in the colour it has on the phone
    static func make(_ root: AccountNode, _ ledger: Ledger) -> [DonutSlice] {
        let slots = categoryColorSlots(ledger, count: CategoryPalette.colors.count)
        let positive = root.children.filter { $0.total > 0.005 }.sorted { $0.total > $1.total }
        let head = positive.count > 7 ? Array(positive.prefix(6)) : positive
        var slices = head.map { node in
            DonutSlice(id: node.name, label: acctZH(node.name) ?? leaf(node.name), value: node.total,
                       color: CategoryPalette.color(slots[node.name] ?? stableColorSlot(node.name, count: CategoryPalette.colors.count)), opens: true)
        }
        let rest = positive.dropFirst(head.count).reduce(0) { $0 + $1.total }
        if rest > 0.005 { slices.append(DonutSlice(id: "__other", label: "其他", value: rest, color: .gray, opens: false)) }
        return slices
    }
}
