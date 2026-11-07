import SwiftUI
import LedgerKit

struct AccountsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let open: (String) -> Void
    @State private var checking: CheckedAccount?

    private struct CheckedAccount: Identifiable {
        let id: String
    }

    var body: some View {
        let sheet = balanceSheet(ledger, at: nil, exclude: config?.balanceExclude ?? [])
        let worth = netWorthNow(ledger, exclude: config?.netWorthExclude ?? [])
        List(selection: opening(open)) {
            TreeSection(title: "资产", root: sheet.assets, ledger: ledger) { checking = CheckedAccount(id: $0) }
            TreeSection(title: "负债", root: sheet.liabilities, ledger: ledger) { checking = CheckedAccount(id: $0) }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            Totals(items: [("净资产", money(worth.assets + worth.liabilities, ledger.base))])
        }
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
    let open: (String) -> Void

    var body: some View {
        let span = period.span
        let report = incomeStatement(ledger, from: span?.0, to: span?.1)
        let income = -report.income.shown, expenses = report.expenses.shown
        List(selection: opening(open)) {
            TreeSection(title: "收入", root: report.income, ledger: ledger, negated: true)
            TreeSection(title: "支出", root: report.expenses, ledger: ledger)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            Totals(items: [("收入", amountsText(income, ledger)),
                           ("支出", amountsText(expenses, ledger)),
                           ("结余", amountsText(income + (-expenses), ledger))])
        }
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
    let open: (String) -> Void

    var body: some View {
        let flows = monthlyFlows(ledger, months: ledger.txns.map { Day.ym($0.date) }, mode: .units)
        List(selection: opening(open)) {
            Section {
                ForEach(flows.keys.sorted(by: >), id: \.self) { month in
                    let flow = flows[month] ?? MonthFlow()
                    MonthRow(month: month, income: amountsText(flow.income, ledger), expenses: amountsText(flow.expenses, ledger),
                             net: amountsText(flow.income + (-flow.expenses), ledger))
                }
            } header: {
                MonthRow(month: "", income: "收入", expenses: "支出", net: "结余")
            }
        }
        .listStyle(.inset)
    }
}

private struct MonthRow: View {
    let month: String
    let income: String
    let expenses: String
    let net: String

    var body: some View {
        HStack(spacing: 16) {
            Text(month).frame(width: 72, alignment: .leading)
            Text(income).frame(maxWidth: .infinity, alignment: .trailing)
            Text(expenses).frame(maxWidth: .infinity, alignment: .trailing)
            Text(net).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// A click on a row opens its account and leaves nothing selected. Through the list's selection, so it reaches this page:
/// a tap gesture on a row can go on answering for whatever the list showed in that place before.
private func opening(_ open: @escaping (String) -> Void) -> Binding<String?> {
    // after the list has finished with the click: changing page in the middle of it leaves the window no longer following the page
    Binding(get: { nil }, set: { account in if let account { DispatchQueue.main.async { open(account) } } })
}

/// one line whatever the currencies, so the page doesn't move when the period changes
private func amountsText(_ amounts: Inventory, _ ledger: Ledger) -> String {
    let shown = amounts.byCurrency(base: ledger.base)
    return (shown.isEmpty ? [CurrencyAmount(ledger.base, 0)] : shown).map { money($0.amount, $0.currency) }.joined(separator: " · ")
}

private struct Totals: View {
    let items: [(String, String)]

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.title2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct TreeSection: View {
    let title: String
    let root: AccountNode
    let ledger: Ledger
    /// income is written as a negative amount; shown here as what came in
    var negated = false
    /// only where the row's account can hold an assertion
    var check: ((String) -> Void)?

    var body: some View {
        Section {
            OutlineGroup(root.children, id: \.name, children: \.kids) { node in
                TreeRow(name: name(node), amount: amountsText(negated ? -node.shown : node.shown, ledger))
                .contextMenu {
                    if let check, ledger.accounts[node.name] != nil {
                        Button("核对余额…") { check(node.name) }
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(amountsText(negated ? -root.shown : root.shown, ledger))
                    .monospacedDigit()
            }
        }
    }

    /// the account's `name:` where it has one, else the last part of its name, with the Chinese group name on the top level
    private func name(_ node: AccountNode) -> String {
        let title = accountTitle(ledger, node.name)
        let shown = title == acctLabel(node.name) ? node.label : title
        guard node.depth == 1, let group = acctZH(node.name) else { return shown }
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

private extension AccountNode {
    var kids: [AccountNode]? { children.isEmpty ? nil : children }
}
