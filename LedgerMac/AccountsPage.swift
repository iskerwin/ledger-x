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

/// what the 账户 page lists: what's held and owed, or the categories money came from or went to in the period
enum AccountsMode: String, CaseIterable {
    case worth = "资产负债", income = "收入", expenses = "支出"

    var root: String? { self == .income ? "Income" : self == .expenses ? "Expenses" : nil }
}

/// a category with what came or went in the period, the way it reads (income as a positive figure)
private struct CategoryLine {
    let name: String
    let amount: Double
    /// under a category of its own, a level down
    let sub: Bool
}

/// the accounts on the left as on the phone (净资产, then each group's accounts with their icon), or the categories with
/// what they took in the period as Fava's income statement; the picked one on the right
struct AccountsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let period: ViewPeriod
    @AppStorage("accountsMode") private var mode = AccountsMode.worth
    @State private var selected: String?
    /// groups folded away, on this Mac
    @AppStorage("accountsFolded") private var foldedRaw = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        let lines = accountLines
        // when each card's bill is due, where one is still owed
        let due = Dictionary(ledger.cardCyclesKept().filter { $0.statementAmount - $0.paid > 0.005 }.map { ($0.account, $0.due) }) { a, _ in a }
        let categories = categoryLines
        let names = mode == .worth ? lines.filter { !folded.contains(rootGroup($0)) }.map(\.name) : categories.lines.map(\.name)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker(selection: $mode) {
                    ForEach(AccountsMode.allCases, id: \.self) { Text($0.rawValue) }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 12)
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if mode == .worth {
                                worthCard
                                ForEach(["Assets", "Liabilities"], id: \.self) { root in
                                    ForEach(groups(lines.filter { $0.name.hasPrefix(root + ":") }), id: \.0) { group in
                                        groupSection(root + ":" + group.0, group.0, group.1, due)
                                    }
                                }
                            } else {
                                Card(summary: true) { Headline(label: mode.rawValue, value: money(categories.total, ledger.base)) }
                                if !categories.lines.isEmpty { categoryCard(categories.lines) }
                            }
                        }
                        .padding(12)
                        // ↑ ↓ go through the accounts in sight, as in a list: on the content, since the scroll view takes the arrows for scrolling
                        .focusable()
                        .focused($listFocused)
                        .focusEffectDisabled()
                        .onMoveCommand { direction in
                            let shown = names
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
            }
            .frame(width: 340)
            Divider()
            Group {
                if mode == .worth, let selected, let line = lines.first(where: { $0.name == selected }) {
                    AccountDetail(ledger: ledger, config: config, account: line.name, balance: line.balance, folder: folder, mode: mode, period: period)
                        .id(selected)
                } else if mode != .worth, let selected, categories.lines.contains(where: { $0.name == selected }) {
                    AccountDetail(ledger: ledger, config: config, account: selected, balance: Inventory(), folder: folder, mode: mode, period: period)
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
            if selected == nil { selected = names.first }
            listFocused = true
        }
        // a category that took nothing in the new period leaves the list, and the switch starts on the first line
        .onChange(of: names) { if !(selected.map(names.contains) ?? false) { selected = names.first } }
    }

    /// the period's span; all time runs from the first entry to today
    private var span: (String, String) {
        let today = Day.today()
        return period.span ?? (min(ledger.txns.first?.date ?? today, today), today)
    }

    /// each category a level under the root that took something in the period, the most first, each with those under it
    private var categoryLines: (total: Double, lines: [CategoryLine]) {
        guard let root = mode.root else { return (0, []) }
        let report = ledger.incomeStatementKept(from: span.0, to: span.1)
        let node = root == "Income" ? report.income : report.expenses
        let sign = root == "Income" ? -1.0 : 1.0
        func taken(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.filter { abs($0.total) > 0.005 }.sorted { sign * $0.total > sign * $1.total }
        }
        let lines = taken(node.children).flatMap { group in
            [CategoryLine(name: group.name, amount: sign * group.total, sub: false)]
                + taken(group.children).map { CategoryLine(name: $0.name, amount: sign * $0.total, sub: true) }
        }
        return (sign * node.total, lines)
    }

    /// the categories on one card: each with its icon and colour, those under it indented below
    private func categoryCard(_ lines: [CategoryLine]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.name) { index, line in
                if index > 0 { Divider().padding(.leading, line.sub ? 52 : 8) }
                categoryRow(line).id(line.name)
            }
        }
        .padding(4)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func categoryRow(_ line: CategoryLine) -> some View {
        let picked = selected == line.name
        return Button {
            selected = line.name
            listFocused = true
        } label: {
            HStack(spacing: 10) {
                if line.sub {
                    Color.clear.frame(width: 32, height: 1)
                } else {
                    Image(systemName: categorySymbol(line.name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(categoryColor(ledger, line.name), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(accountTitle(ledger, line.name)).lineLimit(1)
                Spacer(minLength: 8)
                Text(money(line.amount, ledger.base)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(line.sub ? .callout : .body)
            .foregroundStyle(picked ? Color.white : line.sub ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, line.sub ? 5 : 7)
            .background(picked ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(picked ? .isSelected : [])
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

private enum AccountTab: String, CaseIterable {
    case entries = "交易", months = "按月"
}

/// what an account's entries are listed by
private struct AccountKey: Hashable {
    let ledger: ObjectIdentifier
    let account: String
    let sort: [KeyPathComparator<JournalRow>]
    /// a category's entries keep to the period
    let span: [String]?
}

/// the picked account as Fava's account page: its balance over the year, then every entry with what it held after
/// each, or month by month what moved and what it held at the end
private struct AccountDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let account: String
    let balance: Inventory
    let folder: URL
    let mode: AccountsMode
    let period: ViewPeriod
    @AppStorage("accountTab") private var tab = AccountTab.entries
    @State private var checking = false
    @State private var lines: [JournalRow] = []
    @State private var balances: [ObjectIdentifier: Inventory] = [:]
    @State private var widths = EntryWidths()
    @State private var generation = 0
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\JournalRow.date, order: .reverse)]
    @State private var tasks = EntryTasks()

    var body: some View {
        let amounts = balance.byCurrency(base: ledger.base)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountTitle(ledger, account)).font(.title2.weight(.semibold))
                        Text(account).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if mode == .worth { Button("核对余额…", systemImage: "checkmark.circle") { checking = true } }
                }
                if let root = mode.root {
                    Card(summary: true) { MonthAmountChart(points: monthAmounts(root), currency: ledger.base, label: mode.rawValue) }
                } else {
                    // each currency for itself, side by side: they aren't added up here
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(amounts.isEmpty ? [CurrencyAmount(ledger.base, 0)] : amounts, id: \.currency) { amount in
                            Card(summary: true) {
                                BalanceChart(points: ledger.monthlyBalancesKept(account, currency: amount.currency), currency: amount.currency, current: amount.amount)
                            }
                        }
                    }
                }
                HStack {
                    Picker(selection: $tab) {
                        ForEach(AccountTab.allCases, id: \.self) { Text($0.rawValue) }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if mode == .worth, let check = lastCheck {
                        Text("上次核对 " + check).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            Divider()
            switch tab {
            case .entries:
                EntryList(lines: lines, generation: generation, balances: balances, widths: widths, ledger: ledger, config: config, folder: folder,
                          sortOrder: $sortOrder, selected: $selected, tasks: $tasks, focus: false)
            case .months:
                months
            }
        }
        .background(Color.page)
        .task(id: AccountKey(ledger: ObjectIdentifier(ledger), account: account, sort: sortOrder, span: mode == .worth ? nil : period.span.map { [$0.0, $0.1] })) {
            await rebuild()
        }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
        .sheet(isPresented: $checking) { CheckBalanceSheet(ledger: ledger, account: account, folder: folder) }
    }

    /// each month it moved in, the latest first: what moved and what it held at the end; a click opens that month's entries
    private var months: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                MonthLine(month: "月份", change: mode == .worth ? "变动" : "金额", end: mode == .worth ? "月末余额" : nil, heading: true)
                ForEach(accountMonths(ledger, account: account)) { month in
                    Divider()
                    NavigationLink(value: JournalScope(title: accountTitle(ledger, account) + " · " + month.month, account: account,
                                                       from: month.month + "-01", to: Day.monthEnd(month.month))) {
                        // income reads as a positive figure, as on the list
                        MonthLine(month: month.month, change: amountsText(mode == .income ? -month.change : month.change, ledger),
                                  end: mode == .worth ? amountsText(month.end, ledger) : nil, heading: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    /// every entry on the account, with what it held after each, worked out away from the main thread
    private func rebuild() async {
        let ledger = ledger, account = account, sortOrder = sortOrder
        // a category's entries in the period, without a running balance: what it took adds up over no span of its own
        let span = mode == .worth ? nil : period.span, worth = mode == .worth
        let next = await Task.detached { () -> ([JournalRow], [ObjectIdentifier: Inventory], EntryWidths) in
            let lines = journalRows(ledger, account: account)
                .filter { line in span.map { line.entry.date >= $0.0 && line.entry.date <= $0.1 } ?? true }
                .sorted(using: sortOrder)
            let balances = worth ? ledger.runningBalancesKept(account) : [:]
            return (lines, balances, EntryWidths.measure(lines, balances: balances))
        }.value
        guard !Task.isCancelled else { return }
        lines = next.0
        balances = next.1
        widths = next.2
        generation += 1
        let shown = Set(lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }

    /// what the category took each month in the operating currency, the twelve up to the period's end
    private func monthAmounts(_ root: String) -> [BalancePoint] {
        let now = Day.ym(Day.today())
        let last = min(period.span.map { Day.ym($0.1) } ?? now, now)
        let months = (0..<12).map { Day.addMonth(last, $0 - 11) }
        let columns = ledger.monthColumnsKept(months, roots: [root], held: false)
        let sign = root == "Income" ? -1.0 : 1.0
        return months.map { BalancePoint(month: $0, amount: sign * columns.value(account, $0)) }
    }

    /// the latest assertion on this account that held
    private var lastCheck: String? {
        ledger.balanceResults.last { $0.ok && $0.entry.account == account }?.entry.date
    }
}

private struct MonthLine: View {
    let month: String
    let change: String
    /// what it held at the month's end; a category holds nothing
    let end: String?
    let heading: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(month).monospacedDigit().frame(width: 80, alignment: .leading)
            Text(change).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            if let end { Text(end).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
        }
        .lineLimit(1)
        .foregroundStyle(heading ? Color.secondary : Color.primary)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(hovering && !heading ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }
}
