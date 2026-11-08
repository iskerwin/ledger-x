import SwiftUI
import Charts
import LedgerKit

/// a month or a year of the ledger at a glance: what went out against before, where it went, the latest entries and what wants doing
struct OverviewPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let git: FolderGitStatus?
    @Binding var page: Page?
    @State private var byYear = false
    /// the month shown, or the year's last month
    @State private var month = Day.ym(Day.today())

    var body: some View {
        let span = self.span
        let report = incomeStatement(ledger, from: span.0, to: span.1)
        VStack(spacing: 0) {
            PeriodStepper(byYear: $byYear, month: $month)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    summary(report)
                    SideBySide {
                        categories(report.expenses, span)
                        recent
                    }
                    todo
                }
                .padding(20)
            }
            .background(Color.page)
        }
    }

    private var year: String { String(month.prefix(4)) }
    private var isCurrent: Bool { PeriodStepper.isCurrent(byYear, month) }
    private var span: (String, String) { PeriodStepper.span(byYear, month) }
    private var title: String { PeriodStepper.title(byYear, month) }

    /// the same stretch of the period before: the current period only as far as today has got
    private var before: (String, String) {
        let today = Day.today()
        let back = byYear ? 12 : 1
        let start = Day.addMonth(String(span.0.prefix(7)), -back) + "-01"
        guard isCurrent else { return (start, Day.monthEnd(Day.addMonth(String(span.1.prefix(7)), -back))) }
        let monthBack = Day.addMonth(Day.ym(today), -back)
        let end = min(monthBack + "-" + today.suffix(2), Day.monthEnd(monthBack))
        return (start, end)
    }

    private func summary(_ report: IncomeStatement) -> some View {
        let spent = report.expenses.total, came = -report.income.total
        let previous = incomeStatement(ledger, from: before.0, to: before.1).expenses.total
        let worth = netWorthNow(ledger, exclude: config?.netWorthExclude ?? [])
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Headline(label: (isCurrent ? (byYear ? "今年" : "本月") : title) + "支出", value: money(spent, ledger.base))
                        if previous > 0.005 {
                            let change = (spent - previous) / previous
                            HStack(spacing: 6) {
                                Text((change < 0 ? "↓ " : "↑ ") + String(format: "%.1f%%", abs(change) * 100))
                                    .foregroundStyle(change < 0 ? Color.gain : Color.loss)
                                Text((isCurrent ? "较上期同期 " : "较上期 ") + money(previous, ledger.base))
                                    .foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    MonthBars(ledger: ledger, last: byYear ? year + "-12" : month, picked: byYear ? nil : month)
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
                ForEach(Array(ledger.txns.reversed().lazy.filter { !$0.synthetic }.prefix(6)), id: \.key) { entry in
                    Divider()
                    HStack(spacing: 10) {
                        CategoryBadge(entry: entry, ledger: ledger, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.payee.isEmpty ? (entry.narration.isEmpty ? "（无收付款方）" : entry.narration) : entry.payee).lineLimit(1)
                            Text(entry.date.dropFirst(5).replacingOccurrences(of: "-", with: "/") + " · " + entry.route)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 1) {
                            ForEach(entry.shownAmounts(ledger), id: \.0) { Text($0.0).monospacedDigit().foregroundStyle($0.1) }
                        }
                        .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// bills to pay, balances to check and changes not pushed; nothing wanting doing, no card
    @ViewBuilder private var todo: some View {
        let bills = cardCycles(ledger).filter { $0.statementAmount - $0.paid > 0.005 }.sorted { $0.due < $1.due }
        let checks = reconcileDue(ledger)
        let unpushed = git.map { $0.paths.count + $0.ahead } ?? 0
        if !bills.isEmpty || !checks.isEmpty || unpushed > 0 {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                        if index > 0 { Divider() }
                        NavigationLink(value: JournalScope(title: accountTitle(ledger, bill.account), account: bill.account)) {
                            TodoRow(color: .warn, text: accountTitle(ledger, bill.account) + " " + monthDay(bill.due) + "还款",
                                    side: money(bill.statementAmount - bill.paid, bill.currency))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 || !bills.isEmpty { Divider() }
                        Button { page = .accounts } label: {
                            TodoRow(color: .secondary, text: accountTitle(ledger, check.account) + " " + monthDay(check.day) + "核对余额", side: "")
                        }
                        .buttonStyle(.plain)
                    }
                    if unpushed > 0 {
                        if !bills.isEmpty || !checks.isEmpty { Divider() }
                        Button { page = .sync } label: {
                            TodoRow(color: .jade, text: "\(unpushed) 处改动没有推送", side: "")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func monthDay(_ day: String) -> String {
        "\(Int(day.dropFirst(5).prefix(2)) ?? 0) 月 \(Int(day.suffix(2)) ?? 0) 日"
    }
}

/// a month or a year, and the arrows to the one before and after; never past the current one
struct PeriodStepper: View {
    @Binding var byYear: Bool
    /// the month shown, or in the year shown
    @Binding var month: String

    var body: some View {
        HStack(spacing: 12) {
            Picker(selection: $byYear) {
                Text("月").tag(false)
                Text("年").tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("上一期", systemImage: "chevron.left") { step(-1) }
                .labelStyle(.iconOnly)
            Text(Self.title(byYear, month)).monospacedDigit().frame(minWidth: 96)
            Button("下一期", systemImage: "chevron.right") { step(1) }
                .labelStyle(.iconOnly)
                .disabled(Self.isCurrent(byYear, month))
        }
        .buttonStyle(.borderless)
    }

    private func step(_ by: Int) {
        let next = Day.addMonth(month, byYear ? by * 12 : by)
        let now = Day.ym(Day.today())
        month = next > now ? now : next
    }

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
    let text: String
    let side: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
            Spacer(minLength: 12)
            Text(side).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// the twelve months up to `last`, what went out in each, in the operating currency
private struct MonthBars: View {
    let ledger: Ledger
    let last: String
    /// the month stood out; none, the year's all alike
    let picked: String?

    var body: some View {
        let months = (0..<12).map { Day.addMonth(last, $0 - 11) }
        let flows = monthlyFlows(ledger, months: months, mode: .convert(ledger.base))
        Chart(months, id: \.self) { month in
            BarMark(x: .value("月份", month), y: .value("支出", flows[month]?.expenses.amounts[ledger.base] ?? 0))
                .foregroundStyle(picked == nil || month == picked ? Color.jade : Color.jade.opacity(0.35))
                .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: months) { value in
                AxisValueLabel { if let month = value.as(String.self) { Text(String(Int(month.suffix(2)) ?? 0)) } }
            }
        }
        .frame(height: 90)
        .accessibilityLabel("近 12 个月支出")
    }
}
