import SwiftUI
import Charts
import LedgerKit

/// a month or a year of the ledger at a glance: what went out against before, where it went, the latest entries and what wants doing
struct OverviewPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let git: FolderGitStatus?
    /// 值得留意 not checked yet
    let alerts: [Anomaly]
    /// the window's time: a year for a year or all time, else the month it's in
    @Binding var period: ViewPeriod
    @Binding var page: Page?
    /// the bar under the pointer: a month, or a year; the summary shows it until the pointer leaves
    @State private var hovered: String?
    /// the 值得留意 open under its row
    @State private var openAlert: String?
    @State private var notice: String?

    var body: some View {
        let span = MonthOrYear.span(byYear, month)
        let report = ledger.incomeStatementKept(from: span.0, to: span.1)
        ScrollView {
            VStack(spacing: 16) {
                summary
                SideBySide {
                    categories(report.expenses, span)
                    recent
                }
                todo
            }
            .padding(20)
            .pageWidth()
        }
        .background(Color.page)
        .onChange(of: byYear) { hovered = nil }
        .alert(notice ?? "", isPresented: $notice.present()) {}
    }

    private var byYear: Bool { period.byYear }

    /// the month shown, or in the year shown
    private var month: String { period.anchor }

    private var title: String { MonthOrYear.title(byYear, month) }

    /// the period the summary is about: the one under the pointer, else the one chosen
    private var shown: String {
        guard let hovered else { return month }
        return byYear ? hovered + "-01" : hovered
    }

    /// the same stretch of the period before: the current period only as far as today has got
    private func before(_ month: String) -> (String, String) {
        let today = Day.today(), span = MonthOrYear.span(byYear, month)
        let back = byYear ? 12 : 1
        let start = Day.addMonth(String(span.0.prefix(7)), -back) + "-01"
        guard MonthOrYear.isCurrent(byYear, month) else { return (start, Day.monthEnd(Day.addMonth(String(span.1.prefix(7)), -back))) }
        let monthBack = Day.addMonth(Day.ym(today), -back)
        let end = min(monthBack + "-" + today.suffix(2), Day.monthEnd(monthBack))
        return (start, end)
    }

    private var summary: some View {
        let month = shown, current = MonthOrYear.isCurrent(byYear, month), span = MonthOrYear.span(byYear, month)
        let report = ledger.incomeStatementKept(from: span.0, to: span.1)
        let spent = report.expenses.total, came = -report.income.total
        let earlier = before(month)
        let previous = ledger.incomeStatementKept(from: earlier.0, to: earlier.1).expenses.total
        let worth = ledger.netWorthKept(exclude: config?.netWorthExclude ?? [])
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Headline(label: (current ? (byYear ? "今年" : "本月") : MonthOrYear.title(byYear, month)) + "支出", value: money(spent, ledger.base))
                        // kept in place without a figure to compare with, so the card doesn't move under the pointer
                        let change = previous > 0.005 ? (spent - previous) / previous : 0
                        HStack(spacing: 6) {
                            Text((change < 0 ? "↓ " : "↑ ") + String(format: "%.1f%%", abs(change) * 100))
                                .foregroundStyle(change < 0 ? Color.gain : Color.loss)
                            Text((current ? "较上期同期 " : "较上期 ") + money(previous, ledger.base))
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        .opacity(previous > 0.005 ? 1 : 0)
                    }
                    Spacer(minLength: 0)
                    PeriodBars(ledger: ledger, byYear: byYear, chosen: self.month, hovered: $hovered) { picked in
                        period = byYear ? ViewPeriod(unit: .year, month: min(picked + "-" + String(self.month.suffix(2)), Day.ym(Day.today())))
                            : ViewPeriod(unit: period.unit == .quarter ? .quarter : .month, month: picked)
                        hovered = nil
                    }
                    .frame(maxWidth: 360)
                }
                SummaryFigures(items: [("收入", money(came, ledger.base), .gain),
                                       ("结余", money(came - spent, ledger.base), came - spent < 0 ? .loss : .primary),
                                       ("净资产", money(worth.assets + worth.liabilities, ledger.base), .primary)])
            }
        }
    }

    /// the largest categories, each with its share as a bar; a click opens what it counted
    private func categories(_ root: AccountNode, _ span: (String, String)) -> some View {
        let shown = DonutSlice.make(root, ledger)
        let total = shown.reduce(0) { $0 + $1.value }
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("支出分类").fontWeight(.medium).padding(.bottom, 8)
                ForEach(shown) { slice in
                    Divider()
                    let row = CategoryShare(label: slice.label, value: slice.value, share: total > 0 ? slice.value / total : 0, color: slice.color, base: ledger.base)
                    if slice.opens {
                        NavigationLink(value: JournalScope(title: slice.label + " · " + title, account: slice.id, from: span.0, to: span.1)) { row }
                            .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
        }
    }

    private var recent: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("最近").fontWeight(.medium)
                    Spacer()
                    Button("全部明细") { page = .journal }.buttonStyle(.link)
                }
                .padding(.bottom, 8)
                ForEach(Array(ledger.txns.reversed().lazy.filter { !$0.synthetic }.prefix(6)).map { JournalRow($0, ledger) }) { line in
                    let entry = line.entry
                    Divider()
                    HStack(spacing: 10) {
                        CategoryBadge(entry: entry, ledger: ledger, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.payee).lineLimit(1)
                            Text(entry.date.dropFirst(5).replacingOccurrences(of: "-", with: "/") + " · " + entry.route)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 1) {
                            ForEach(line.amounts.indices, id: \.self) { Text(line.amounts[$0].text).monospacedDigit().foregroundStyle(line.amounts[$0].tone.color) }
                        }
                        .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// what looks unusual, bills to pay, balances to check and changes not pushed; nothing wanting doing, no card
    @ViewBuilder private var todo: some View {
        let bills = ledger.cardCyclesKept().filter { $0.statementAmount - $0.paid > 0.005 }.sorted { $0.due < $1.due }
        let checks = ledger.reconcileDueKept()
        let unpushed = git.map { $0.paths.count + $0.ahead } ?? 0
        if !alerts.isEmpty || !bills.isEmpty || !checks.isEmpty || unpushed > 0 {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    // each opens in place: why it stands out, its entries, and 核对无误
                    ForEach(alerts) { alert in
                        Divider().opacity(alert.id == alerts.first?.id ? 0 : 1)
                        Button { openAlert = openAlert == alert.id ? nil : alert.id } label: {
                            TodoRow(color: .warn, symbol: alert.kind.symbol, text: alert.title, side: "", open: openAlert == alert.id)
                        }
                        .buttonStyle(.plain)
                        if openAlert == alert.id {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(alert.detail).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Button("核对无误") { confirm(alert) }
                                }
                                EntryListCard(entries: alert.entries, ledger: ledger, config: config, folder: folder,
                                              columns: [.date, .payee, .category, .accounts, .amount]) { EmptyView() }
                            }
                            .padding(.leading, 24)
                            .padding(.bottom, 8)
                        }
                    }
                    ForEach(bills) { bill in
                        Divider().opacity(alerts.isEmpty && bill.id == bills.first?.id ? 0 : 1)
                        NavigationLink(value: JournalScope(title: accountTitle(ledger, bill.account), account: bill.account)) {
                            TodoRow(color: .warn, text: accountTitle(ledger, bill.account) + " " + monthDay(bill.due) + "还款",
                                    side: money(bill.statementAmount - bill.paid, bill.currency))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(checks) { check in
                        Divider().opacity(alerts.isEmpty && bills.isEmpty && check.id == checks.first?.id ? 0 : 1)
                        Button { page = .accounts } label: {
                            TodoRow(color: .secondary, text: accountTitle(ledger, check.account) + " " + monthDay(check.day) + "核对余额", side: "")
                        }
                        .buttonStyle(.plain)
                    }
                    if unpushed > 0 {
                        Divider().opacity(alerts.isEmpty && bills.isEmpty && checks.isEmpty ? 0 : 1)
                        Button { page = .sync } label: {
                            TodoRow(color: .jade, text: "\(unpushed) 处改动没有推送", side: "")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func confirm(_ alert: Anomaly) {
        do {
            try confirmAlert(alert, folder: folder)
            openAlert = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    private func monthDay(_ day: String) -> String {
        "\(Int(day.dropFirst(5).prefix(2)) ?? 0) 月 \(Int(day.suffix(2)) ?? 0) 日"
    }
}

/// a month or a year of the pages that show one or the other (概览, 预算)
enum MonthOrYear {
    static func isCurrent(_ byYear: Bool, _ month: String) -> Bool {
        let today = Day.today()
        return byYear ? month.prefix(4) == today.prefix(4) : month == Day.ym(today)
    }

    static func span(_ byYear: Bool, _ month: String) -> (String, String) {
        let year = String(month.prefix(4))
        return byYear ? (year + "-01-01", year + "-12-31") : (month + "-01", Day.monthEnd(month))
    }

    static func title(_ byYear: Bool, _ month: String) -> String {
        byYear ? "\(month.prefix(4)) 年" : "\(month.prefix(4)) 年 \(Int(month.suffix(2)) ?? 0) 月"
    }
}

/// a category's name and amount over the bar of its share
private struct CategoryShare: View {
    let label: String
    let value: Double
    let share: Double
    let color: Color
    let base: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(money(value, base)).monospacedDigit().lineLimit(1)
                }
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        Capsule().fill(Color.primary.opacity(0.08))
                            .overlay(alignment: .leading) { Capsule().fill(color).frame(width: geometry.size.width * share) }
                    }
                    .frame(height: 4)
                    Text(String(format: "%.0f%%", share * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4).inset(by: -4))
        .onHover { hovering = $0 }
    }
}

private struct TodoRow: View {
    let color: Color
    /// what kind of thing it is, where a dot isn't enough
    var symbol: String?
    let text: String
    let side: String
    /// opens in place rather than going somewhere
    var open: Bool?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
            }
            .frame(width: 14)
            Text(text).lineLimit(1)
            Spacer(minLength: 12)
            Text(side).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open == true ? 90 : 0))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// what went out in each of the last twelve months, or the last six years, in the operating currency: the pointer over a bar
/// shows that period in the summary, a click goes to it
private struct PeriodBars: View {
    let ledger: Ledger
    let byYear: Bool
    /// the month chosen
    let chosen: String
    @Binding var hovered: String?
    let choose: (String) -> Void

    var body: some View {
        let now = Day.ym(Day.today())
        let keys: [String], values: [String: Double], picked: String
        if byYear {
            let last = Int(now.prefix(4)) ?? 2026
            keys = (0..<6).map { String(last - 5 + $0) }
            let months = (0..<72).map { Day.addMonth(String(last - 5) + "-01", $0) }
            let flows = ledger.monthlyFlowsKept(months, mode: .convert(ledger.base))
            values = Dictionary(grouping: months) { String($0.prefix(4)) }.mapValues { $0.reduce(0) { $0 + (flows[$1]?.expenses.amounts[ledger.base] ?? 0) } }
            picked = String(chosen.prefix(4))
        } else {
            // the year up to now, or the twelve months up to one chosen before that
            let last = chosen < Day.addMonth(now, -11) ? Day.addMonth(chosen, 11) : now
            keys = (0..<12).map { Day.addMonth(last, $0 - 11) }
            let flows = ledger.monthlyFlowsKept(keys, mode: .convert(ledger.base))
            values = Dictionary(uniqueKeysWithValues: keys.map { ($0, flows[$0]?.expenses.amounts[ledger.base] ?? 0) })
            picked = chosen
        }
        return Chart(keys, id: \.self) { key in
            BarMark(x: .value("期间", key), y: .value("支出", values[key] ?? 0))
                .foregroundStyle(key == (hovered ?? picked) ? Color.jade : Color.jade.opacity(0.35))
                .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: keys) { value in
                AxisValueLabel { if let key = value.as(String.self) { Text(byYear ? key : String(Int(key.suffix(2)) ?? 0)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = key(at: point, proxy, geometry).flatMap { keys.contains($0) ? $0 : nil }
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let key = key(at: tap.location, proxy, geometry), keys.contains(key) { choose(key) }
                    })
            }
        }
        .frame(height: 90)
        .accessibilityLabel(byYear ? "近 6 年支出" : "近 12 个月支出")
    }

    private func key(at point: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        return proxy.value(atX: point.x - geometry[plot].minX, as: String.self)
    }
}
