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
        List {
            TreeSection(title: chinese ? "资产" : "Assets", root: sheet.assets, ledger: ledger, open: open) { checking = CheckedAccount(id: $0) }
            TreeSection(title: chinese ? "负债" : "Liabilities", root: sheet.liabilities, ledger: ledger, open: open) { checking = CheckedAccount(id: $0) }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            Totals(items: [(chinese ? "净资产" : "Net Worth", money(worth.assets + worth.liabilities, ledger.base))])
        }
        .sheet(item: $checking) { CheckBalanceSheet(ledger: ledger, account: $0.id, folder: folder) }
    }
}

/// the search box's own words for these spans, so a period here means what it means there
enum ReportPeriod: String, CaseIterable {
    case thisMonth = "本月", lastMonth = "上月", thisYear = "今年", lastYear = "去年"

    var title: String {
        if chinese { return rawValue }
        switch self {
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .thisYear: return "This Year"
        case .lastYear: return "Last Year"
        }
    }

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
        List {
            TreeSection(title: chinese ? "收入" : "Income", root: report.income, ledger: ledger, negated: true, open: open)
            TreeSection(title: chinese ? "支出" : "Expenses", root: report.expenses, ledger: ledger, open: open)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            Totals(items: [(chinese ? "收入" : "Income", amountsText(income, ledger)),
                           (chinese ? "支出" : "Expenses", amountsText(expenses, ledger)),
                           (chinese ? "结余" : "Net", amountsText(income + (-expenses), ledger))])
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
    let open: (String) -> Void
    /// only where the row's account can hold an assertion
    var check: ((String) -> Void)?

    var body: some View {
        Section {
            OutlineGroup(root.children, children: \.kids) { node in
                HStack(spacing: 16) {
                    Text(name(node))
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    Text(amountsText(negated ? -node.shown : node.shown, ledger))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { open(node.name) }
                .contextMenu {
                    if let check, ledger.accounts[node.name] != nil {
                        Button(chinese ? "核对余额…" : "Check Balance…") { check(node.name) }
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

private extension AccountNode {
    var kids: [AccountNode]? { children.isEmpty ? nil : children }
}
