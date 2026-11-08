import SwiftUI
import LedgerKit

/// the search box's own words for these spans, so a period here means what it means there
enum ReportPeriod: String, CaseIterable {
    case thisMonth = "本月", lastMonth = "上月", thisYear = "今年", lastYear = "去年"

    var title: String { rawValue }

    var span: (String, String)? { TxQuery(rawValue).dateSpan }
}

private enum ReportTab: String, CaseIterable {
    case flow = "收支", statements = "财务报表"
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

/// two tabs over the same month or year: 收支 (where it went, month by month, what came in and from whom) and 财务报表 (损益表, 资产负债表 and 试算平衡 together)
struct ReportsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    @AppStorage("reportTab") private var tab = ReportTab.flow
    @State private var byYear = false
    @State private var month = Day.ym(Day.today())

    var body: some View {
        let span = PeriodStepper.span(byYear, month)
        let title = PeriodStepper.title(byYear, month)
        let scope: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0) + " · " + title, account: $0, from: span.0, to: span.1) }
        let report = incomeStatement(ledger, from: span.0, to: span.1)
        ReportScaffold {
            Picker(selection: $tab) {
                ForEach(ReportTab.allCases, id: \.self) { Text($0.rawValue) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            PeriodStepper(byYear: $byYear, month: $month)
        } content: {
            switch tab {
            case .flow:
                PeriodSummary(ledger: ledger, title: (PeriodStepper.isCurrent(byYear, month) ? (byYear ? "今年" : "本月") : title), report: report)
                SideBySide {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle("支出构成")
                            DonutCard(slices: DonutSlice.make(report.expenses, ledger), base: ledger.base, scope: scope)
                        }
                    }
                    Card { MonthsChart(ledger: ledger, months: chartMonths) }
                }
                SideBySide {
                    TreeCard(title: "收入", root: report.income, ledger: ledger, negated: true, scope: scope)
                    PayeesCard(ledger: ledger, span: span)
                }
                MonthsTable(ledger: ledger)
            case .statements:
                Statements(ledger: ledger, config: config, span: span, title: title, report: report, scope: scope)
            }
        }
    }

    /// the twelve months of the year, or the twelve up to the month
    private var chartMonths: [String] {
        byYear ? (1...12).map { String(month.prefix(4)) + String(format: "-%02d", $0) } : (0..<12).map { Day.addMonth(month, $0 - 11) }
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
        let valued = monthlyFlows(ledger, months: months, mode: .convert(ledger.base))
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("按月对比")
            FlowCard(months: months, income: valued.mapValues { $0.income.amounts[ledger.base] ?? 0 },
                     expenses: valued.mapValues { $0.expenses.amounts[ledger.base] ?? 0 }, base: ledger.base)
        }
    }
}

/// who the period's money went to, the five largest
private struct PayeesCard: View {
    let ledger: Ledger
    let span: (String, String)

    var body: some View {
        var spent: [String: (n: Int, amount: Double)] = [:]
        for entry in ledger.txns where !entry.synthetic && !entry.payee.isEmpty && entry.date >= span.0 && entry.date <= span.1 {
            let shown = classify(entry, ledger)
            guard shown.kind == .expense || shown.kind == .refund else { continue }
            spent[entry.payee, default: (0, 0)].n += 1
            spent[entry.payee, default: (0, 0)].amount -= shown.amount
        }
        let top = spent.sorted { $0.value.amount > $1.value.amount }.prefix(5)
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("收付款方")
                ForEach(Array(top), id: \.key) { payee in
                    Divider()
                    FigureRow(label: payee.key, caption: "\(payee.value.n) 笔", value: money(payee.value.amount, ledger.base))
                }
            }
        }
    }
}

/// every month of the ledger, the latest first, each opening its entries
private struct MonthsTable: View {
    let ledger: Ledger

    var body: some View {
        let flows = monthlyFlows(ledger, months: ledger.txns.map { Day.ym($0.date) }, mode: .units)
        Card {
            VStack(spacing: 0) {
                MonthRow(month: "", income: "收入", expenses: "支出", net: "结余", negative: false, heading: true)
                    .padding(.bottom, 6)
                ForEach(flows.keys.sorted(by: >), id: \.self) { month in
                    let flow = flows[month]
                    let net = (flow?.income ?? Inventory()) + -(flow?.expenses ?? Inventory())
                    Divider()
                    NavigationLink(value: JournalScope(title: month, from: Day.ym(month) + "-01", to: Day.monthEnd(month))) {
                        MonthRow(month: month, income: amountsText(flow?.income ?? Inventory(), ledger),
                                 expenses: amountsText(flow?.expenses ?? Inventory(), ledger), net: amountsText(net, ledger),
                                 negative: net.amounts.values.reduce(0, +) < 0, heading: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 损益表 of the period beside 资产负债表 at its end, and under them 试算平衡 at the same day, every account in three columns
private struct Statements: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let span: (String, String)
    let title: String
    let report: IncomeStatement
    let scope: (String) -> JournalScope

    var body: some View {
        let today = Day.today()
        let end = min(span.1, today)
        let sheet = balanceSheet(ledger, at: end == today ? nil : end, exclude: config?.balanceExclude ?? [])
        let standing: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0), account: $0, to: end) }
        let conversions = sheet.conversions.byCurrency(base: ledger.base).isEmpty ? [] : [("货币兑换", sheet.conversions)]
        let net = -report.income.shown + -report.expenses.shown
        SideBySide {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "损益表") { Text(title).foregroundStyle(.secondary) }
                    TreeCard(title: "收入", root: report.income, ledger: ledger, negated: true, scope: scope, bare: true)
                    TreeCard(title: "支出", root: report.expenses, ledger: ledger, scope: scope, bare: true)
                    Divider()
                    FigureRow(label: "净收益", value: amountsText(net, ledger), color: net.amounts.values.reduce(0, +) < 0 ? .loss : .primary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "资产负债表") { Text("截至 " + shortDay(end)).foregroundStyle(.secondary) }
                    TreeCard(title: "资产", root: sheet.assets, ledger: ledger, scope: standing, bare: true)
                    TreeCard(title: "负债", root: sheet.liabilities, ledger: ledger, negated: true, scope: standing, bare: true)
                    TreeCard(title: "权益", root: sheet.equity, ledger: ledger, negated: true, scope: standing,
                             lines: [("未结转损益", sheet.earningsByCurrency)] + conversions, bare: true)
                }
            }
        }
        TrialCard(ledger: ledger, end: end, scope: standing)
    }
}

/// debits and credits of each currency, in their own signs: equal once the conversions are counted; each account's balance under them
private struct TrialCard: View {
    let ledger: Ledger
    let end: String
    let scope: (String) -> JournalScope

    var body: some View {
        let balances = periodBalances(ledger, to: end)
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

private struct MonthRow: View {
    let month: String
    let income: String
    let expenses: String
    let net: String
    let negative: Bool
    let heading: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(month).frame(width: 72, alignment: .leading)
            Text(income).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(heading ? Color.secondary : Color.gain)
            Text(expenses).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(heading ? Color.secondary : Color.loss)
            Text(net).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(heading ? Color.secondary : negative ? Color.loss : Color.primary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.vertical, heading ? 0 : 6)
        .contentShape(Rectangle())
        .background(hovering && !heading ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4).inset(by: -4))
        .onHover { hovering = $0 }
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
