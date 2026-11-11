import SwiftUI
import LedgerKit

/// an account's group look, the phone's (`AccountKind` in Ledger/Views/AccountsView.swift): this target shares none of its code
private enum AccountGroup {
    static let order = ["Bank", "EWallet", "Cash", "Brokerage", "Crypto", "Receivable", "CreditCard", "Loan"]

    static func look(_ group: String) -> (symbol: String, color: Color) {
        switch group {
        case "Bank": return ("building.columns.fill", .blue)
        case "EWallet": return ("wallet.pass.fill", .cyan)
        case "Cash": return ("banknote.fill", .brown)
        case "Brokerage": return ("chart.line.uptrend.xyaxis", .purple)
        case "Crypto": return ("bitcoinsign", .orange)
        case "Receivable": return ("tray.and.arrow.down.fill", .teal)
        case "CreditCard": return ("creditcard.fill", .indigo)
        case "Loan": return ("percent", .gray)
        default: return ("folder.fill", .gray)
        }
    }
}

/// an open account that holds something, under its group (its name's second part, as on the phone)
private struct AccountLine: Identifiable {
    let name: String
    let balance: Inventory
    var id: String { name }
    var group: String {
        let parts = name.components(separatedBy: ":")
        return parts.count > 1 ? parts[1] : name
    }
}

/// the accounts on the left as on the phone (净资产, then each group's accounts with their icon), the picked one on the right
struct AccountsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let scope: (String) -> JournalScope
    @State private var selected: String?
    /// groups folded away, on this Mac
    @AppStorage("accountsFolded") private var foldedRaw = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        let lines = accountLines
        // when each card's bill is due, where one is still owed
        let due = Dictionary(ledger.cardCyclesKept().filter { $0.statementAmount - $0.paid > 0.005 }.map { ($0.account, $0.due) }) { a, _ in a }
        HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        worthCard
                        ForEach(["Assets", "Liabilities"], id: \.self) { root in
                            ForEach(groups(lines.filter { $0.name.hasPrefix(root + ":") }), id: \.0) { group in
                                groupSection(root + ":" + group.0, group.0, group.1, due)
                            }
                        }
                    }
                    .padding(12)
                    // ↑ ↓ go through the accounts in sight, as in a list: on the content, since the scroll view takes the arrows for scrolling
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        let shown = lines.filter { !folded.contains(rootGroup($0)) }.map(\.name)
                        guard !shown.isEmpty else { return }
                        let at = selected.flatMap { shown.firstIndex(of: $0) } ?? -1
                        switch direction {
                        case .up: selected = shown[max(0, at - 1)]
                        case .down: selected = shown[min(shown.count - 1, at + 1)]
                        default: return
                        }
                        if let selected { scroller.scrollTo(selected) }
                    }
                }
            }
            .frame(width: 340)
            Divider()
            Group {
                if let selected, let line = lines.first(where: { $0.name == selected }) {
                    AccountDetail(ledger: ledger, config: config, account: line.name, balance: line.balance, folder: folder, scope: scope)
                        .id(selected)
                } else {
                    Color.page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // one ground on both sides: the cards need the page colour to show
        .background(Color.page)
        .onAppear {
            if selected == nil { selected = lines.first?.name }
            listFocused = true
        }
    }

    /// 净资产 as on the phone's card: what it comes to, what's held and owed, and how much of it is owed
    private var worthCard: some View {
        let worth = ledger.netWorthKept(exclude: config?.netWorthExclude ?? [])
        let owed = -worth.liabilities
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("净资产").foregroundStyle(.secondary)
                    Text(money(worth.assets + worth.liabilities, ledger.base))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                HStack(alignment: .top) {
                    figure("资产", money(worth.assets, ledger.base), .leading)
                    Spacer(minLength: 8)
                    figure("负债", money(owed, ledger.base), .leading)
                    Spacer(minLength: 8)
                    figure("资产负债率", worth.assets > 0 && owed > 0.005 ? String(format: "%.1f%%", owed / worth.assets * 100) : "—", .trailing)
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String, _ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    /// a group's name and total, folded away on a click; its accounts on a card under it
    private func groupSection(_ key: String, _ group: String, _ lines: [AccountLine], _ due: [String: String]) -> some View {
        let shut = folded.contains(key)
        let look = AccountGroup.look(group)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                var set = folded
                if shut { set.remove(key) } else { set.insert(key) }
                foldedRaw = set.sorted().joined(separator: ",")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(shut ? 0 : 90))
                    Text(ZH[group] ?? group)
                    if shut { Text("\(lines.count) 个").foregroundStyle(.tertiary) }
                    Spacer()
                    Text(amountsText(lines.reduce(Inventory()) { $0 + $1.balance }, ledger)).monospacedDigit().lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !shut {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider().padding(.leading, 52) }
                        row(line, look, due[line.name])
                            .id(line.name)
                    }
                }
                .padding(4)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func row(_ line: AccountLine, _ look: (symbol: String, color: Color), _ due: String?) -> some View {
        let picked = selected == line.name
        // a button, so a click, VoiceOver and the keyboard all pick it
        return Button {
            selected = line.name
            listFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: look.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(look.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName(line.name)).lineLimit(1)
                    Text(subtitle(line, due: due)).font(.caption).foregroundStyle(picked ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(amountsText(line.balance, ledger)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(picked ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(picked ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// the phone's line under the name: what a card owes and when, else when it was last checked, else where it sits
    private func subtitle(_ line: AccountLine, due: String?) -> String {
        let currencies = line.balance.byCurrency(base: ledger.base)
        if currencies.count > 1 { return currencies.map(\.currency).joined(separator: " · ") }
        if let due { return "\(Int(due.dropFirst(5).prefix(2)) ?? 0)月\(Int(due.suffix(2)) ?? 0)日还款" }
        // an assertion checks the start of its day: it was checked the day before
        if let last = ledger.balanceResults.filter({ $0.ok && $0.entry.account == line.name }).map(\.entry.date).max() {
            let ago = daysBetween(last, Day.today()) + 1
            if ago >= 0 && ago <= 30 { return ago == 0 ? "今天已核对" : ago == 1 ? "昨天已核对" : "\(ago) 天前已核对" }
        }
        return line.name
    }

    private var folded: Set<String> { Set(foldedRaw.split(separator: ",").map(String.init)) }

    private func rootGroup(_ line: AccountLine) -> String {
        line.name.components(separatedBy: ":").prefix(2).joined(separator: ":")
    }

    /// open accounts holding something, as the phone lists them
    private var accountLines: [AccountLine] {
        let today = Day.today()
        return ledger.accounts.keys
            .filter { ($0.hasPrefix("Assets:") || $0.hasPrefix("Liabilities:")) && !(ledger.accounts[$0]?.close.map { $0 <= today } ?? false) }
            .sorted()
            .compactMap { name in
                var balance = Inventory()
                for (currency, amount) in ledger.final[name] ?? [:] where abs(amount) > 0.0049 { balance.add(amount, currency) }
                return balance.byCurrency(base: ledger.base).isEmpty ? nil : AccountLine(name: name, balance: balance)
            }
    }

    /// in the phone's order of groups, then by name
    private func groups(_ lines: [AccountLine]) -> [(String, [AccountLine])] {
        Dictionary(grouping: lines, by: \.group).sorted { a, b in
            let ia = AccountGroup.order.firstIndex(of: a.key) ?? 99, ib = AccountGroup.order.firstIndex(of: b.key) ?? 99
            return ia != ib ? ia < ib : a.key < b.key
        }
    }

    /// the account's `name:` where it has one, else what follows its group
    private func accountName(_ name: String) -> String {
        let title = accountTitle(ledger, name)
        guard title == acctLabel(name) else { return title }
        let parts = name.components(separatedBy: ":")
        return parts.count > 2 ? parts[2...].joined(separator: ":") : title
    }
}

private struct AccountDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let account: String
    let balance: Inventory
    let folder: URL
    let scope: (String) -> JournalScope
    @State private var checking = false

    var body: some View {
        let amounts = balance.byCurrency(base: ledger.base)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountTitle(ledger, account)).font(.title2.weight(.semibold))
                        Text(account).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("核对余额…", systemImage: "checkmark.circle") { checking = true }
                }
                // each currency for itself: they aren't added up here
                ForEach(amounts.isEmpty ? [CurrencyAmount(ledger.base, 0)] : amounts, id: \.currency) { amount in
                    Card(summary: true) {
                        BalanceChart(points: monthlyBalances(ledger, account: account, currency: amount.currency), currency: amount.currency, current: amount.amount)
                    }
                }
                if let check = lastCheck {
                    Text("上次核对 " + check).font(.callout).foregroundStyle(.secondary)
                }
                EntryListCard(entries: recent, ledger: ledger, config: config, folder: folder, account: account) {
                    HStack {
                        Text("账户交易").fontWeight(.medium)
                        Spacer()
                        NavigationLink("查看全部", value: scope(account))
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.page)
        .sheet(isPresented: $checking) { CheckBalanceSheet(ledger: ledger, account: account, folder: folder) }
    }

    private var recent: [Entry] {
        Array(ledger.txns.reversed().lazy.filter { entry in entry.postings.contains { isExcluded($0.account, [account]) } }.prefix(8))
    }

    /// the latest assertion on this account that held
    private var lastCheck: String? {
        ledger.balanceResults.last { $0.ok && $0.entry.account == account }?.entry.date
    }
}
