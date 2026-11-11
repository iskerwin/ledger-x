import SwiftUI
import LedgerKit

/// the three statements, as Fava has them
private enum ReportTab: String, CaseIterable {
    case income = "损益表", balance = "资产负债表", trial = "试算平衡"
}

/// a report's page: what it is set to along the top, the report on the page colour under it, in the middle of a wide window
struct ReportScaffold<Bar: View, Content: View>: View {
    @ViewBuilder var bar: Bar
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if Bar.self != EmptyView.self {
                HStack(spacing: 12) { bar }
                    .frame(minHeight: 22)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Divider()
            }
            ScrollView {
                VStack(spacing: 16) { content }
                    .padding(20)
                    .pageWidth()
            }
            .background(Color.page)
        }
    }
}

extension ReportScaffold where Bar == EmptyView {
    /// a report of what stands today: nothing to set
    init(@ViewBuilder content: () -> Content) {
        self.init(bar: { EmptyView() }, content: content)
    }
}

/// the statements over the window's time, each on a tab: 损益表 (where it went and came from), 资产负债表 (what's held and
/// owed at the end) and 试算平衡 (every account). The first two show the period's totals, or a column for each month
struct ReportsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    /// the window's time; all of it runs from the first entry to today
    let period: ViewPeriod
    @AppStorage("reportTab") private var tab = ReportTab.income
    @AppStorage("reportByMonth") private var byMonth = false

    var body: some View {
        let today = Day.today()
        let span = period.span ?? (min(ledger.txns.first?.date ?? today, today), today)
        let end = min(span.1, today)
        let title = period.title
        let scope: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0) + " · " + title, account: $0, from: span.0, to: span.1) }
        let standing: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0), account: $0, to: end) }
        ReportScaffold {
            Picker(selection: $tab) {
                ForEach(ReportTab.allCases, id: \.self) { Text($0.rawValue) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            // every account at one day: nothing to split by month; kept in its place, so the tabs don't move
            Picker(selection: $byMonth) {
                Text("合计").tag(false)
                Text("按月").tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .opacity(tab == .trial ? 0 : 1)
            .disabled(tab == .trial)
        } content: {
            switch tab {
            case .income:
                let report = ledger.incomeStatementKept(from: span.0, to: span.1)
                PeriodSummary(ledger: ledger, title: period.isCurrent ? period.current : title, report: report)
                SideBySide {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle("支出构成")
                            DonutCard(slices: DonutSlice.make(report.expenses, ledger), base: ledger.base, scope: scope)
                        }
                    }
                    Card { MonthsChart(ledger: ledger, months: chartMonths) }
                }
                if byMonth {
                    MonthGridCard(columns: ledger.monthColumnsKept(gridMonths, roots: ["Income", "Expenses"], held: false), ledger: ledger,
                                  negated: ["Income"]) { account, month in
                        JournalScope(title: accountTitle(ledger, account) + " · " + month, account: account, from: month + "-01", to: Day.monthEnd(month))
                    }
                } else {
                    let net = -report.income.shown + -report.expenses.shown
                    SideBySide {
                        TreeCard(title: "收入", root: report.income, ledger: ledger, negated: true, scope: scope)
                        TreeCard(title: "支出", root: report.expenses, ledger: ledger, scope: scope)
                    }
                    Card {
                        FigureRow(label: "净收益", value: amountsText(net, ledger), color: net.amounts.values.reduce(0, +) < 0 ? .loss : .primary)
                    }
                }
            case .balance:
                let sheet = ledger.balanceSheetKept(at: end == today ? nil : end, exclude: config?.balanceExclude ?? [])
                WorthSummary(ledger: ledger, sheet: sheet, end: end, points: worthPoints(end))
                if byMonth {
                    MonthGridCard(columns: ledger.monthColumnsKept(gridMonths, roots: ["Assets", "Liabilities", "Equity"], held: true), ledger: ledger,
                                  negated: ["Liabilities", "Equity"]) { account, month in
                        JournalScope(title: accountTitle(ledger, account), account: account, to: Day.monthEnd(month))
                    }
                } else {
                    let conversions = sheet.conversions.byCurrency(base: ledger.base).isEmpty ? [] : [("货币兑换", sheet.conversions)]
                    SideBySide {
                        TreeCard(title: "资产", root: sheet.assets, ledger: ledger, scope: standing)
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                TreeCard(title: "负债", root: sheet.liabilities, ledger: ledger, negated: true, scope: standing, bare: true)
                                TreeCard(title: "权益", root: sheet.equity, ledger: ledger, negated: true, scope: standing,
                                         lines: [("未结转损益", sheet.earningsByCurrency)] + conversions, bare: true)
                            }
                        }
                    }
                }
            case .trial:
                TrialCard(ledger: ledger, end: end, scope: standing)
            }
        }
    }

    /// the twelve months of the year, or the twelve up to the period's last (this month at the latest)
    private var chartMonths: [String] {
        if period.unit == .year && period.day == nil { return (1...12).map { String(period.month.prefix(4)) + String(format: "-%02d", $0) } }
        let last = min(period.span.map { Day.ym($0.1) } ?? Day.ym(Day.today()), Day.ym(Day.today()))
        return (0..<12).map { Day.addMonth(last, $0 - 11) }
    }

    /// a column for each month of the period up to this one, at most the last twelve; a single month, with the five before
    private var gridMonths: [String] {
        let now = Day.ym(Day.today())
        let last = min(period.span.map { Day.ym($0.1) } ?? now, now)
        let first = period.span.map { Day.ym($0.0) } ?? Day.addMonth(last, -11)
        var months = [min(first, last)]
        while let month = months.last, month < last { months.append(Day.addMonth(month, 1)) }
        if months.count < 2 { months = (0..<6).map { Day.addMonth(last, $0 - 5) } }
        return Array(months.suffix(12))
    }

    /// net worth at the end of each of the twelve months up to the period's end
    private func worthPoints(_ end: String) -> [BalancePoint] {
        let series = ledger.netWorthSeriesKept(exclude: config?.netWorthExclude ?? [])
        let last = Day.ym(end)
        return series.filter { $0.month <= last }.suffix(12).map { BalancePoint(month: $0.month, amount: $0.assets + $0.liabilities) }
    }
}

/// a period's spending, big, with what came in, what's left and how much of it was kept under it
private struct PeriodSummary: View {
    let ledger: Ledger
    let title: String
    let report: IncomeStatement

    var body: some View {
        let income = -report.income.shown, expenses = report.expenses.shown
        let net = income + (-expenses)
        let came = income.amounts[ledger.base] ?? 0, kept = net.amounts[ledger.base] ?? 0
        Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: title + "支出", value: amountsText(expenses, ledger))
                SummaryFigures(items: [("收入", amountsText(income, ledger), .gain),
                                       ("结余", amountsText(net, ledger), net.amounts.values.reduce(0, +) < 0 ? .loss : .primary),
                                       ("储蓄率", came > 0.005 ? String(format: "%.1f%%", kept / came * 100) : "—", .primary)])
            }
        }
    }
}

/// income and spending of twelve months in the operating currency; a month's bar shows its figures
private struct MonthsChart: View {
    let ledger: Ledger
    let months: [String]

    var body: some View {
        let valued = ledger.monthlyFlowsKept(months, mode: .convert(ledger.base))
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("按月对比")
            FlowCard(months: months, income: valued.mapValues { $0.income.amounts[ledger.base] ?? 0 },
                     expenses: valued.mapValues { $0.expenses.amounts[ledger.base] ?? 0 }, base: ledger.base)
        }
    }
}

/// net worth at the period's end over its line of the twelve months before, and what's held and owed under it
private struct WorthSummary: View {
    let ledger: Ledger
    let sheet: BalanceSheet
    let end: String
    let points: [BalancePoint]

    var body: some View {
        let assets = sheet.assets.total, owed = -sheet.liabilities.total
        Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                BalanceChart(points: points, currency: ledger.base, current: assets - owed,
                             title: end == Day.today() ? "净资产" : "净资产 · 截至 " + shortDay(end))
                SummaryFigures(items: [("资产", money(assets, ledger.base), .primary), ("负债", money(owed, ledger.base), .primary),
                                       ("资产负债率", assets > 0 && owed > 0.005 ? String(format: "%.1f%%", owed / assets * 100) : "—", .primary)])
            }
        }
    }
}

/// accounts down the side, a column for each month, as Fava's changes and balances: an arrow opens what's under an
/// account, a figure opens that month's entries. Wider than the window, it scrolls sideways under the names
private struct MonthGridCard: View {
    let columns: MonthColumns
    let ledger: Ledger
    /// roots written as negative amounts, shown as what came in or is owed
    let negated: Set<String>
    let scope: (_ account: String, _ month: String) -> JournalScope
    @State private var open: Set<String> = []

    private let nameWidth: CGFloat = 220
    private let cellWidth: CGFloat = 104

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    line { Text("账户").foregroundStyle(.secondary) }
                    ForEach(rows, id: \.name) { node in
                        Divider()
                        line { name(node) }
                    }
                }
                .frame(width: nameWidth)
                ScrollView(.horizontal) {
                    VStack(alignment: .trailing, spacing: 0) {
                        line {
                            HStack(spacing: 0) {
                                ForEach(columns.months, id: \.self) { month in
                                    Text(monthTitle(month)).foregroundStyle(.secondary).frame(width: cellWidth, alignment: .trailing)
                                }
                            }
                        }
                        ForEach(rows, id: \.name) { node in
                            Divider()
                            line {
                                HStack(spacing: 0) {
                                    ForEach(columns.months, id: \.self) { month in
                                        cell(node, month)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// the roots and what's open under them
    private var rows: [AccountNode] {
        func under(_ node: AccountNode) -> [AccountNode] {
            [node] + (open.contains(node.name) ? node.children.flatMap(under) : [])
        }
        return columns.roots.flatMap(under)
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        content().lineLimit(1).frame(height: 30)
    }

    private func name(_ node: AccountNode) -> some View {
        HStack(spacing: 4) {
            Button {
                if open.contains(node.name) { open.remove(node.name) } else { open.insert(node.name) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open.contains(node.name) ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(node.children.isEmpty ? 0 : 1)
            .disabled(node.children.isEmpty)
            .accessibilityLabel(open.contains(node.name) ? "收起" : "展开")
            Text(node.depth == 0 ? (ZH[node.name] ?? node.name) : accountTitle(ledger, node.name) == acctLabel(node.name) ? node.label : accountTitle(ledger, node.name))
                .fontWeight(node.depth == 0 ? .medium : .regular)
        }
        .padding(.leading, CGFloat(node.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ node: AccountNode, _ month: String) -> some View {
        let root = String(node.name.prefix { $0 != ":" })
        let value = columns.value(node.name, month) * (negated.contains(root) ? -1 : 1)
        return NavigationLink(value: scope(node.name, month)) {
            Text(abs(value) < 0.005 ? "—" : money(value, ledger.base))
                .monospacedDigit()
                .foregroundStyle(abs(value) < 0.005 ? Color.secondary : Color.primary)
                .frame(width: cellWidth, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(node.depth == 0)
    }

    private func monthTitle(_ month: String) -> String {
        let number = Int(month.suffix(2)) ?? 0
        return number == 1 || month == columns.months.first ? "\(month.prefix(4)) 年 \(number) 月" : "\(number) 月"
    }
}

/// debits and credits of each currency, in their own signs: equal once the conversions are counted; each account's balance under them
private struct TrialCard: View {
    let ledger: Ledger
    let end: String
    let scope: (String) -> JournalScope

    var body: some View {
        let balances = ledger.periodBalancesKept(to: end)
        let roots = ["Assets", "Liabilities", "Equity", "Income", "Expenses"].map { accountTree(balances, root: $0, ledger, at: end, shown: balances) }
        let totals = roots.map(\.shown) + [conversions(of: balances)]
        let debit = sum(totals) { $0 > 0 ? $0 : 0 }, credit = sum(totals) { $0 < 0 ? -$0 : 0 }
        let currencies = Set(debit.keys).union(credit.keys).sorted { a, b in a == ledger.base ? b != ledger.base : b == ledger.base ? false : a < b }
            .filter { (debit[$0] ?? 0) > 0.005 || (credit[$0] ?? 0) > 0.005 }
        let accounts = roots.flatMap(leaves)
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("试算平衡")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 3), alignment: .leading, spacing: 0) {
                    ForEach(accounts, id: \.name) { node in
                        NavigationLink(value: scope(node.name)) {
                            HStack(spacing: 12) {
                                Text(accountTitle(ledger, node.name)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(amountsText(node.shown, ledger)).monospacedDigit().lineLimit(1)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(node.name)
                    }
                }
                ForEach(currencies, id: \.self) { currency in
                    Divider()
                    FigureRow(label: "借方 · 贷方" + (currencies.count > 1 ? " · " + currency : ""),
                              value: money(debit[currency] ?? 0, currency) + " · " + money(credit[currency] ?? 0, currency))
                }
            }
        }
    }

    /// the accounts with nothing under them, in the tree's order
    private func leaves(_ node: AccountNode) -> [AccountNode] {
        node.children.flatMap { $0.children.isEmpty ? [$0] : leaves($0) }
    }

    private func sum(_ inventories: [Inventory], _ part: (Double) -> Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for inventory in inventories {
            for (currency, value) in inventory.amounts { out[currency, default: 0] += part(value) }
        }
        return out
    }
}

/// one line whatever the currencies, so the page doesn't move when the period changes
func amountsText(_ amounts: Inventory, _ ledger: Ledger) -> String {
    let shown = amounts.byCurrency(base: ledger.base)
    return (shown.isEmpty ? [CurrencyAmount(ledger.base, 0)] : shown).map { money($0.amount, $0.currency) }.joined(separator: " · ")
}

/// a group of accounts on a card: an arrow opens what's under a row, the row itself the entries it counts
struct TreeCard: View {
    let title: String
    let root: AccountNode
    let ledger: Ledger
    /// income, liabilities and equity are written as negative amounts; shown here as what came in or is owed
    var negated = false
    let scope: (String) -> JournalScope
    /// what isn't an account but counts in the total, under the accounts: no entries to open
    var lines: [(String, Inventory)] = []
    /// a part of a larger card, without its own
    var bare = false
    @State private var open: Set<String> = []

    var body: some View {
        if bare {
            content
        } else {
            Card { content }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(amountsText(shown(lines.reduce(root.shown) { $0 + $1.1 }), ledger))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                ForEach(visible, id: \.name) { node in
                    Divider()
                    row(node)
                }
                ForEach(lines, id: \.0) { line in
                    Divider()
                    HStack(spacing: 16) {
                        Text(line.0).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 16)
                        Text(amountsText(shown(line.1), ledger)).monospacedDigit().lineLimit(1)
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 6)
                }
            }
    }

    private var visible: [AccountNode] {
        func under(_ node: AccountNode) -> [AccountNode] {
            node.children.flatMap { [$0] + (open.contains($0.name) ? under($0) : []) }
        }
        return under(root)
    }

    private func row(_ node: AccountNode) -> some View {
        HStack(spacing: 4) {
            Button {
                if open.contains(node.name) { open.remove(node.name) } else { open.insert(node.name) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open.contains(node.name) ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(node.children.isEmpty ? 0 : 1)
            .disabled(node.children.isEmpty)
            .accessibilityLabel(open.contains(node.name) ? "收起" : "展开")
            NavigationLink(value: scope(node.name)) {
                TreeRow(name: name(node), amount: amountsText(shown(node.shown), ledger))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(node.depth - 1) * 16)
        .padding(.vertical, 6)
    }

    private func shown(_ amounts: Inventory) -> Inventory {
        negated ? -amounts : amounts
    }

    /// the account's `name:` where it has one, else the last part of its name, with the Chinese group name on the top level unless it's the same
    private func name(_ node: AccountNode) -> String {
        let title = accountTitle(ledger, node.name)
        let shown = title == acctLabel(node.name) ? node.label : title
        guard node.depth == 1, let group = acctZH(node.name), group != shown else { return shown }
        return shown + " · " + group
    }
}

/// the highlight under the pointer shows that clicking opens the entries it counts
private struct TreeRow: View {
    let name: String
    let amount: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(amount)
                .monospacedDigit()
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4).inset(by: -4))
        .onHover { hovering = $0 }
    }
}
