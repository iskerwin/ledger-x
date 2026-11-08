import SwiftUI
import LedgerKit

/// an account in the column, with those under it
private struct AccountItem: Identifiable {
    let node: AccountNode
    let children: [AccountItem]?
    var id: String { node.name }

    init(_ node: AccountNode) {
        self.node = node
        children = node.children.isEmpty ? nil : node.children.map(AccountItem.init)
    }
}

/// the accounts on the left, the picked one on the right
struct AccountsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let scope: (String) -> JournalScope
    @State private var selected: String?

    var body: some View {
        let sheet = balanceSheet(ledger, at: nil, exclude: config?.balanceExclude ?? [])
        let worth = netWorthNow(ledger, exclude: config?.netWorthExclude ?? [])
        let nodes = [sheet.assets, sheet.liabilities]
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("净资产").foregroundStyle(.secondary)
                    Text(money(worth.assets + worth.liabilities, ledger.base))
                        .font(.title2.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(12)
                Divider()
                List(selection: $selected) {
                    section("资产", sheet.assets)
                    section("负债", sheet.liabilities)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 280)
            // one ground with the detail beside it: the detail's cards need the page colour to show
            .background(Color.page)
            Divider()
            Group {
                if let selected, let node = find(selected, in: nodes) {
                    AccountDetail(ledger: ledger, node: node, folder: folder, scope: scope)
                        .id(selected)
                } else {
                    Color.page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selected == nil { selected = sheet.assets.children.first?.name }
        }
    }

    private func section(_ title: String, _ root: AccountNode) -> some View {
        Section {
            OutlineGroup(root.children.map(AccountItem.init), children: \.children) { item in
                HStack(spacing: 8) {
                    Text(accountName(item.node)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(amountsText(item.node.shown, ledger)).monospacedDigit().lineLimit(1)
                }
                .tag(item.id)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(amountsText(root.shown, ledger)).monospacedDigit().lineLimit(1)
            }
        }
    }

    /// the account's `name:` where it has one, else the last part of its name
    private func accountName(_ node: AccountNode) -> String {
        let title = accountTitle(ledger, node.name)
        return title == acctLabel(node.name) ? node.label : title
    }

    private func find(_ name: String, in nodes: [AccountNode]) -> AccountNode? {
        for node in nodes {
            if node.name == name { return node }
            if let found = find(name, in: node.children) { return found }
        }
        return nil
    }
}

private struct AccountDetail: View {
    let ledger: Ledger
    let node: AccountNode
    let folder: URL
    let scope: (String) -> JournalScope
    @State private var checking = false

    var body: some View {
        let amounts = node.balance.byCurrency(base: ledger.base)
        let held = ledger.accounts[node.name] != nil
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountTitle(ledger, node.name)).font(.title2.weight(.semibold))
                        Text(node.name).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if held {
                        Button("核对余额…", systemImage: "checkmark.circle") { checking = true }
                    }
                }
                // each currency for itself: they aren't added up here
                ForEach(amounts.isEmpty ? [CurrencyAmount(ledger.base, 0)] : amounts, id: \.currency) { amount in
                    Card(summary: true) {
                        BalanceChart(points: monthlyBalances(ledger, account: node.name, currency: amount.currency), currency: amount.currency, current: amount.amount)
                    }
                }
                if let check = lastCheck {
                    Text("上次核对 " + check).font(.callout).foregroundStyle(.secondary)
                }
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("账户交易").fontWeight(.medium)
                            Spacer()
                            NavigationLink("查看全部", value: scope(node.name))
                                .buttonStyle(.link)
                        }
                        .padding(.bottom, 8)
                        ForEach(recent, id: \.key) { entry in
                            Divider()
                            AccountEntryRow(entry: entry, ledger: ledger, account: node.name)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.page)
        .sheet(isPresented: $checking) { CheckBalanceSheet(ledger: ledger, account: node.name, folder: folder) }
    }

    private var recent: [Entry] {
        Array(ledger.txns.reversed().lazy.filter { entry in entry.postings.contains { isExcluded($0.account, [node.name]) } }.prefix(8))
    }

    /// the latest assertion on this account that held
    private var lastCheck: String? {
        ledger.balanceResults.last { $0.ok && $0.entry.account == node.name }?.entry.date
    }
}

private struct AccountEntryRow: View {
    let entry: Entry
    let ledger: Ledger
    let account: String

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.date.dropFirst(5).replacingOccurrences(of: "-", with: "/"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            CategoryBadge(entry: entry, ledger: ledger, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.payee.isEmpty ? (entry.narration.isEmpty ? "（无收付款方）" : entry.narration) : entry.payee).lineLimit(1)
                if !entry.payee.isEmpty && !entry.narration.isEmpty {
                    Text(entry.narration).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(entry.shownAmounts(ledger, account: account), id: \.0) { amount in
                    Text(amount.0).monospacedDigit().foregroundStyle(amount.1)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}
