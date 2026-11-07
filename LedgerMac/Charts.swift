import SwiftUI
import Charts
import LedgerKit

/// the months to show a mark for: about eight labels however many there are
private func labelled(_ months: [String]) -> [String] {
    let step = months.count <= 8 ? 1 : months.count <= 14 ? 2 : 3
    return months.filter { ((Int($0.suffix(2)) ?? 1) - 1) % step == 0 }
}

private func monthNumber(_ month: String) -> String { String(Int(month.suffix(2)) ?? 0) + "月" }

/// 净资产: what it comes to, how it has moved, month by month. The pointer on the chart shows that month in the same place.
struct WorthCard: View {
    let total: Double
    let points: [NetWorthPoint]
    let base: String
    @State private var picked: String?

    var body: some View {
        let shown = points.first { $0.month == picked }
        let change = (points.last?.netWorth ?? 0) - (points.first?.netWorth ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.map { $0.month + " 月末" } ?? "净资产")
                        .foregroundStyle(.secondary)
                    Text(money(shown?.netWorth ?? total, base))
                        .font(.largeTitle.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Spacer()
                Text(signedMoney(change, base))
                    .monospacedDigit()
                    .foregroundStyle(change < 0 ? Color.loss : Color.gain)
                    .help("区间变动")
            }
            chart.frame(height: 180)
        }
    }

    private var chart: some View {
        let lo = points.map(\.netWorth).min() ?? 0, hi = points.map(\.netWorth).max() ?? 0
        let pad = max((hi - lo) * 0.1, 1)
        return Chart(points) { point in
            AreaMark(x: .value("月份", point.month), yStart: .value("下限", lo - pad), yEnd: .value("净资产", point.netWorth))
                .foregroundStyle(LinearGradient(colors: [Color.jade.opacity(0.32), Color.jade.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("月份", point.month), y: .value("净资产", point.netWorth))
                .foregroundStyle(Color.jade)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .interpolationMethod(.monotone)
            if point.month == picked {
                RuleMark(x: .value("月份", point.month))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("月份", point.month), y: .value("净资产", point.netWorth))
                    .foregroundStyle(Color.jade)
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartXAxis {
            AxisMarks(values: labelled(points.map(\.month))) { value in
                AxisValueLabel { if let month = value.as(String.self) { Text(monthNumber(month)) } }
            }
        }
        .pickingMonth($picked)
    }
}

/// 月度收支, in the operating currency at each month's rates: a pair of bars a month
struct FlowCard: View {
    let months: [String]
    let income: [String: Double]
    let expenses: [String: Double]
    let base: String
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            .chartForegroundStyleScale(["收入": Color.gain, "支出": Color.loss])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartXAxis {
                AxisMarks(values: labelled(months)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let month = value.as(String.self) { Text(monthNumber(month)) } }
                }
            }
            .pickingMonth($picked)
            .frame(height: 200)
            // always a line here, so pointing at a month moves nothing
            HStack(spacing: 12) {
                if let picked {
                    let net = (income[picked] ?? 0) - (expenses[picked] ?? 0)
                    Text(picked).fontWeight(.medium)
                    Text("收入 " + money(income[picked] ?? 0, base)).foregroundStyle(Color.gain)
                    Text("支出 " + money(expenses[picked] ?? 0, base)).foregroundStyle(Color.loss)
                    Spacer()
                    Text("结余 " + money(net, base)).foregroundStyle(net < 0 ? Color.loss : Color.secondary)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
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

/// one piece of the ring: a category, or the rest together
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

/// a ring and its legend: every piece named with its share and amount. The pointer on a line of the legend brings out its piece.
struct DonutCard: View {
    let slices: [DonutSlice]
    let base: String
    let scope: (String) -> JournalScope
    @State private var selected: String?

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                if slices.isEmpty {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 22).padding(14)
                } else {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("金额", slice.value), innerRadius: .ratio(0.64),
                                   outerRadius: .ratio(selected == slice.id ? 1 : 0.9), angularInset: 1.2)
                            .cornerRadius(3)
                            .foregroundStyle(slice.color.opacity(selected == nil || selected == slice.id ? 1 : 0.3))
                    }
                    .chartLegend(.hidden)
                }
                center
            }
            .frame(width: 170, height: 170)
            VStack(spacing: 2) {
                ForEach(slices) { slice in
                    if slice.opens {
                        NavigationLink(value: scope(slice.id)) { legendRow(slice) }
                            .buttonStyle(.plain)
                    } else {
                        legendRow(slice)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: 170)
    }

    private var center: some View {
        let slice = slices.first { $0.id == selected }
        return VStack(spacing: 2) {
            Text(slice?.label ?? "总支出")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(money(slice?.value ?? total, base, 0))
                .font(.headline)
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(width: 92)
    }

    private func legendRow(_ slice: DonutSlice) -> some View {
        HStack(spacing: 8) {
            Circle().fill(slice.color).frame(width: 8, height: 8)
            Text(slice.label).lineLimit(1)
            Spacer(minLength: 8)
            Text(String(format: "%.0f%%", slice.value / max(total, 0.01) * 100))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(money(slice.value, base))
                .monospacedDigit()
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(selected == slice.id ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { selected = $0 ? slice.id : (selected == slice.id ? nil : selected) }
    }
}
