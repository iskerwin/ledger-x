import SwiftUI
import LedgerKit

struct AccountsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let scope: (String) -> JournalScope
    @State private var checking: CheckedAccount?

    private struct CheckedAccount: Identifiable {
        let id: String
    }

    var body: some View {
        let sheet = balanceSheet(ledger, at: nil, exclude: config?.balanceExclude ?? [])
        let worth = netWorthNow(ledger, exclude: config?.netWorthExclude ?? [])
        let series = netWorthSeries(ledger, exclude: config?.netWorthExclude ?? []).suffix(12)
        ScrollView {
            VStack(spacing: 16) {
                Card(summary: true) { WorthCard(assets: worth.assets, liabilities: worth.liabilities, points: Array(series), base: ledger.base) }
                SideBySide {
                    TreeCard(title: "资产", root: sheet.assets, ledger: ledger, scope: scope) { checking = CheckedAccount(id: $0) }
                    TreeCard(title: "负债", root: sheet.liabilities, ledger: ledger, scope: scope) { checking = CheckedAccount(id: $0) }
                }
            }
            .padding(20)
        }
        .background(Color.page)
        .sheet(item: $checking) { CheckBalanceSheet(ledger: ledger, account: $0.id, folder: folder) }
    }
}

/// the search box's own words for these spans, so a period here means what it means there
enum ReportPeriod: String, CaseIterable {
    case thisMonth = "本月", lastMonth = "上月", thisYear = "今年", lastYear = "去年"

    var title: String { rawValue }

    var span: (String, String)? { TxQuery(rawValue).dateSpan }
}

struct ReportsPage: View {
    let ledger: Ledger
    @Binding var period: ReportPeriod

    var body: some View {
        let span = period.span
        let report = incomeStatement(ledger, from: span?.0, to: span?.1)
        let income = -report.income.shown, expenses = report.expenses.shown
        let net = income + (-expenses)
        let shown = period.title
        let scope: (String) -> JournalScope = { JournalScope(title: accountTitle(ledger, $0) + " · " + shown, account: $0, from: span?.0, to: span?.1) }
        ScrollView {
            VStack(spacing: 16) {
                Card(summary: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Headline(label: shown + "支出", value: amountsText(expenses, ledger))
                        SummaryFigures(items: [("收入", amountsText(income, ledger), .gain),
                                               ("结余", amountsText(net, ledger), net.amounts.values.reduce(0, +) < 0 ? .loss : .primary)])
                    }
                }
                Card(summary: true) { DonutCard(slices: DonutSlice.make(report.expenses, ledger), base: ledger.base, scope: scope) }
                SideBySide {
                    TreeCard(title: "收入", root: report.income, ledger: ledger, negated: true, scope: scope)
                    TreeCard(title: "支出", root: report.expenses, ledger: ledger, scope: scope)
                }
            }
            .padding(20)
        }
        .background(Color.page)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $period) {
                    ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct MonthsPage: View {
    let ledger: Ledger
    let scope: (String) -> JournalScope

    var body: some View {
        let all = ledger.txns.map { Day.ym($0.date) }
        let flows = monthlyFlows(ledger, months: all, mode: .units)
        let months = flows.keys.sorted()
        let recent = Array(months.suffix(12))
        let valued = monthlyFlows(ledger, months: recent, mode: .convert(ledger.base))
        ScrollView {
            VStack(spacing: 16) {
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
                            NavigationLink(value: scope(month)) {
                                MonthRow(month: month, income: amountsText(flow?.income ?? Inventory(), ledger),
                                         expenses: amountsText(flow?.expenses ?? Inventory(), ledger), net: amountsText(net, ledger),
                                         negative: net.amounts.values.reduce(0, +) < 0, heading: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.page)
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
private func amountsText(_ amounts: Inventory, _ ledger: Ledger) -> String {
    let shown = amounts.byCurrency(base: ledger.base)
    return (shown.isEmpty ? [CurrencyAmount(ledger.base, 0)] : shown).map { money($0.amount, $0.currency) }.joined(separator: " · ")
}

/// a group of accounts on a card: an arrow opens what's under a row, the row itself the entries it counts
private struct TreeCard: View {
    let title: String
    let root: AccountNode
    let ledger: Ledger
    /// income is written as a negative amount; shown here as what came in
    var negated = false
    let scope: (String) -> JournalScope
    /// only where the row's account can hold an assertion
    var check: ((String) -> Void)?
    @State private var open: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(amountsText(negated ? -root.shown : root.shown, ledger))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                ForEach(visible, id: \.name) { node in
                    Divider()
                    row(node)
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
                TreeRow(name: name(node), amount: amountsText(negated ? -node.shown : node.shown, ledger))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(node.depth - 1) * 16)
        .padding(.vertical, 6)
        .contextMenu {
            if let check, ledger.accounts[node.name] != nil {
                Button("核对余额…") { check(node.name) }
            }
        }
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
