import SwiftUI
import LedgerKit

/// the search box's own words for these spans, so a period here means what it means there
enum ReportPeriod: String, CaseIterable {
    case thisMonth = "本月", lastMonth = "上月", thisYear = "今年", lastYear = "去年"

    var title: String { rawValue }

    var span: (String, String)? { TxQuery(rawValue).dateSpan }
}

private enum ReportTab: String, CaseIterable {
    case analysis = "收支分析", months = "按月对比", balance = "资产负债表", income = "损益表", trial = "试算平衡"

    var usesPeriod: Bool { self == .analysis || self == .income }
}

/// the reports, one above the other in a tab each; a period where the report covers one, the date it is as at where it doesn't
struct ReportsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    @State private var tab = ReportTab.analysis
    @State private var period = ReportPeriod.thisMonth

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(selection: $tab) {
                    ForEach(ReportTab.allCases, id: \.self) { Text($0.rawValue) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                // kept in place when hidden, so the tabs don't move
                Picker(selection: $period) {
                    ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title) }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .opacity(tab.usesPeriod ? 1 : 0)
                .disabled(!tab.usesPeriod)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    switch tab {
                    case .analysis: analysis
                    case .months: MonthsReport(ledger: ledger)
                    case .balance: balanceReport
                    case .income: incomeReport
                    case .trial: TrialReport(ledger: ledger)
                    }
                }
                .padding(20)
            }
            .background(Color.page)
        }
    }

    private func spanScope(_ title: String) -> (String) -> JournalScope {
        let span = period.span
        return { JournalScope(title: accountTitle(ledger, $0) + " · " + title, account: $0, from: span?.0, to: span?.1) }
    }

    private var statement: IncomeStatement {
        incomeStatement(ledger, from: period.span?.0, to: period.span?.1)
    }

    private func summary(_ report: IncomeStatement) -> some View {
        let income = -report.income.shown, expenses = report.expenses.shown
        let net = income + (-expenses)
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: period.title + "支出", value: amountsText(expenses, ledger))
                SummaryFigures(items: [("收入", amountsText(income, ledger), .gain),
                                       ("结余", amountsText(net, ledger), net.amounts.values.reduce(0, +) < 0 ? .loss : .primary)])
            }
        }
    }

    @ViewBuilder private var analysis: some View {
        let report = statement
        summary(report)
        Card(summary: true) { DonutCard(slices: DonutSlice.make(report.expenses, ledger), base: ledger.base, scope: spanScope(period.title)) }
    }

    @ViewBuilder private var incomeReport: some View {
        let report = statement
        summary(report)
        SideBySide {
            TreeCard(title: "收入", root: report.income, ledger: ledger, negated: true, scope: spanScope(period.title))
            TreeCard(title: "支出", root: report.expenses, ledger: ledger, scope: spanScope(period.title))
        }
    }

    /// as it stands today, all of it; each currency balances, 资产 = 负债 + 权益, as on the phone
    @ViewBuilder private var balanceReport: some View {
        let sheet = balanceSheet(ledger, at: nil, exclude: config?.balanceExclude ?? [])
        let scope: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0), account: $0) }
        let conversions = sheet.conversions.byCurrency(base: ledger.base).isEmpty ? [] : [("货币兑换", sheet.conversions)]
        SideBySide {
            TreeCard(title: "资产", root: sheet.assets, ledger: ledger, scope: scope)
            VStack(spacing: 16) {
                TreeCard(title: "负债", root: sheet.liabilities, ledger: ledger, negated: true, scope: scope)
                TreeCard(title: "权益", root: sheet.equity, ledger: ledger, negated: true, scope: scope,
                         lines: [("未结转损益", sheet.earningsByCurrency)] + conversions)
            }
        }
    }
}

private struct MonthsReport: View {
    let ledger: Ledger

    var body: some View {
        let all = ledger.txns.map { Day.ym($0.date) }
        let flows = monthlyFlows(ledger, months: all, mode: .units)
        let months = flows.keys.sorted()
        let recent = Array(months.suffix(12))
        let valued = monthlyFlows(ledger, months: recent, mode: .convert(ledger.base))
        Card(summary: true) {
            FlowCard(months: recent, income: valued.mapValues { $0.income.amounts[ledger.base] ?? 0 },
                     expenses: valued.mapValues { $0.expenses.amounts[ledger.base] ?? 0 }, base: ledger.base)
        }
        Card {
            VStack(spacing: 0) {
                MonthRow(month: "", income: "收入", expenses: "支出", net: "结余", negative: false, heading: true)
                    .padding(.bottom, 6)
                ForEach(months.reversed(), id: \.self) { month in
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

/// debits and credits of each currency, in their own signs: equal once the conversions are counted
private struct TrialReport: View {
    let ledger: Ledger

    var body: some View {
        let today = Day.today()
        let balances = periodBalances(ledger, to: today)
        let roots = ["Assets", "Liabilities", "Equity", "Income", "Expenses"].map { accountTree(balances, root: $0, ledger, at: today, shown: balances) }
        let conversion = conversions(of: balances)
        let totals = roots.map(\.shown) + [conversion]
        let debit = sum(totals) { $0 > 0 ? $0 : 0 }, credit = sum(totals) { $0 < 0 ? -$0 : 0 }
        let currencies = Set(debit.keys).union(credit.keys).sorted { a, b in a == ledger.base ? b != ledger.base : b == ledger.base ? false : a < b }
            .filter { (debit[$0] ?? 0) > 0.005 || (credit[$0] ?? 0) > 0.005 }
        Card(summary: true) {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("币种").gridColumnAlignment(.leading)
                    Text("借方合计")
                    Text("贷方合计")
                }
                .foregroundStyle(.secondary)
                ForEach(currencies, id: \.self) { currency in
                    Divider()
                    GridRow {
                        Text(currency)
                        Text(money(debit[currency] ?? 0, currency)).monospacedDigit()
                        Text(money(credit[currency] ?? 0, currency)).monospacedDigit()
                    }
                }
            }
        }
        SideBySide {
            VStack(spacing: 16) {
                ForEach(roots.prefix(3), id: \.name) { card($0) }
            }
            VStack(spacing: 16) {
                ForEach(roots.suffix(2), id: \.name) { card($0) }
            }
        }
    }

    private func card(_ root: AccountNode) -> some View {
        TreeCard(title: acctZH(root.name) ?? root.name, root: root, ledger: ledger) { JournalScope(title: accountTitle(ledger, $0), account: $0) }
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
    @State private var open: Set<String> = []

    var body: some View {
        Card {
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
