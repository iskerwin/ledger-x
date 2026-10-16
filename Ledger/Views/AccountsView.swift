import SwiftUI
import LedgerKit

struct AccountsView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @AppStorage("ledger.showClosed") private var showClosed = false
    /// account groups folded away on this page ("Assets:Bank", …)
    @AppStorage("ledger.accounts.collapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    /// 全部 / 资产 / 负债
    @AppStorage("ledger.accounts.side") private var side = "all"

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L { list(L) } else { ProgressView() }
            }
            .navigationTitle(LS("账户"))
            .toolbar {
                StandardToolbar(currency: true)
                ToolbarItemGroup(placement: .topBarLeading) {
                    NavigationLink(value: AccountManagerDest()) { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(LS("管理账户"))
                    // a plain button: a toggle's "on" background spills out of the toolbar's glass
                    Button { showClosed.toggle() } label: { Image(systemName: showClosed ? "archivebox.fill" : "archivebox") }
                        .accessibilityLabel(LS("显示已关闭和为零的账户"))
                        .accessibilityAddTraits(showClosed ? .isSelected : [])
                }
            }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name).privacyToolbar() }
            .navigationDestination(for: HoldingsDest.self) { _ in HoldingsView().privacyToolbar() }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar() }
            .subscriptionDestinations()
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: AccountManagerDest.self) { _ in AccountManagerView() }
            .navigationDestination(for: AccountEditDest.self) { AccountEditView(name: $0.name) }
            .navigationDestination(for: CounterpartyDest.self) { _ in CounterpartyView().privacyToolbar() }
            .navigationDestination(for: NetWorthSettingsDest.self) { _ in NetWorthSettingsView() }
            .navigationDestination(for: ReconcileDest.self) { _ in ReconcileView().privacyToolbar() }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            if store.demoEnv["LEDGER_MANAGE"] != nil, path.isEmpty { path.append(AccountManagerDest()) }
            if store.demoEnv["LEDGER_NW"] != nil, path.isEmpty { path.append(NetWorthSettingsDest()) }
            if let a = store.demoEnv["LEDGER_EDIT_ACCOUNT"], path.isEmpty { path.append(AccountEditDest(name: a)) }
            if let a = store.demoEnv["LEDGER_OPEN_ACCOUNT"], path.isEmpty { path.append(AccountDest(name: a)) }
            if store.demoEnv["LEDGER_OPEN_HOLDINGS"] != nil, path.isEmpty { path.append(HoldingsDest()) }
        }
    }

    /// an account: its balances in the chosen currencies as booked, the same valued as chosen, closed or not
    struct Row {
        let account: String
        let balances: [(String, Double)]
        let shown: Inventory
        let closed: Bool
    }

    /// what each account holds, valued as chosen (币种与换算); at cost needs the postings, the rest the balances
    private func valued(_ L: Ledger) -> (only: Set<String>?, at: (String, Inventory) -> Inventory) {
        let mode = store.cmode, only = store.conly
        if mode == .cost {
            let cost = valuedBalances(L, mode: .cost, only: only)
            return (only, { a, _ in cost[a] ?? Inventory() })
        }
        let today = Day.today()
        return (only, { _, inv in valueInventory(inv, mode, L, at: today) })
    }

    private func rows(_ L: Ledger, _ g: String, _ today: String, _ v: (only: Set<String>?, at: (String, Inventory) -> Inventory)) -> [Row] {
        var out: [Row] = []
        for a in L.accounts.keys.filter({ $0.hasPrefix(g + ":") }).sorted() {
            let cs = (L.final[a] ?? [:]).filter { abs($0.value) > 0.0049 && (v.only?.contains($0.key) ?? true) }
                .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            let closed = (L.accounts[a]?.close).map { $0 <= today } ?? false
            if !showClosed && (closed || cs.isEmpty) { continue }
            // an account with only other currencies is left out while they are switched off
            if v.only != nil && cs.isEmpty && !(L.final[a] ?? [:]).filter({ abs($0.value) > 0.0049 }).isEmpty { continue }
            var inv = Inventory()
            for (c, n) in cs { inv.add(n, c) }
            out.append(Row(account: a, balances: cs, shown: v.at(a, inv), closed: closed))
        }
        return out
    }

    private func total(_ rs: [Row]) -> Inventory { rs.reduce(Inventory()) { $0 + $1.shown } }

    /// accounts under a root, grouped by their second level ("Bank", "CreditCard", …)
    private func groups(_ L: Ledger, _ root: String, _ today: String, _ v: (only: Set<String>?, at: (String, Inventory) -> Inventory)) -> [(String, [Row])] {
        var by: [String: [Row]] = [:]
        for r in rows(L, root, today, v) {
            let p = r.account.components(separatedBy: ":")
            by[p.count > 1 ? p[1] : root, default: []].append(r)
        }
        return by.sorted { a, b in
            let ia = AccountKind.order.firstIndex(of: a.key) ?? 99, ib = AccountKind.order.firstIndex(of: b.key) ?? 99
            return ia != ib ? ia < ib : a.key < b.key
        }
    }

    private func groupSection(_ L: Ledger, _ root: String, _ g: String, _ rs: [Row]) -> some View {
        let kind = store.groupIcon(root + ":" + g)
        let failing = Set(L.balanceResults.filter { !$0.ok }.compactMap { $0.entry.account })
        let key = root + ":" + g
        let shut = collapsed.contains(key)
        return Section {
            if !shut {
                ForEach(rs, id: \.account) { row in
                    NavigationLink(value: AccountDest(name: row.account)) {
                        AccountRow(account: row.account, balances: row.balances, closed: row.closed, failing: failing.contains(row.account),
                                   kind: kind, shown: row.shown)
                    }
                }
            }
        } header: {
            // tap to fold the group away (remembered on this device); its total stays in sight
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    var s = collapsed
                    if shut { s.remove(key) } else { s.insert(key) }
                    collapsedRaw = s.sorted().joined(separator: ",")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(shut ? 0 : 90))
                    Text(groupName(g))
                    if AppLanguage.current != .en { Text(g).foregroundStyle(.tertiary).textCase(nil) }
                    if shut { Text(LS("%@ 个", rs.count)).foregroundStyle(.tertiary).textCase(nil) }
                    Spacer()
                    Text(total(rs).byCurrency(base: L.base).map { unitText($0.amount, $0.currency) }.joined(separator: " · "))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).sensitive().textCase(nil)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// 净资产 as chosen: one figure, or a line per currency
    private func heroSection(_ L: Ledger, assets: Inventory, liab: Inventory) -> some View {
        let a1 = assets.single(base: L.base), l1 = (-liab).single(base: L.base)
        let one = a1 != nil && l1 != nil && (a1!.currency == l1!.currency || abs(l1!.amount) < 0.005)
        return Section {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LS("净资产")).font(.subheadline).foregroundStyle(.secondary)
                        InventoryHeadline(inv: assets + liab, base: L.base)
                    }
                    HStack(alignment: .top) {
                        InventoryFigure(label: LS("资产"), inv: assets, base: L.base)
                        Spacer()
                        InventoryFigure(label: LS("负债"), inv: -liab, base: L.base)
                        Spacer()
                        Figure(label: LS("资产负债率"), value: one && a1!.amount > 0 && l1!.amount > 0.005 ? String(format: "%.1f%%", l1!.amount / a1!.amount * 100) : "—", alignment: .trailing)
                    }
                    if one, let a = a1?.amount, let l = l1?.amount {
                        RatioBar(parts: [(max(0, a - max(0, l)), Color.jade), (max(0, l), Color.loss)])
                    }
                    if !store.netWorthExclude.isEmpty {
                        NavigationLink(value: NetWorthSettingsDest()) {
                            Text(LS("不计入 %@ 个账户", store.netWorthExclude.count)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .cardRow()
        }
    }

    @ViewBuilder
    private func ytdSection(_ L: Ledger, _ year: String) -> some View {
        let ie = ytd(L, year)
        if !ie.isEmpty {
            Section {
                ForEach(ie, id: \.0) { item in
                    NavigationLink(value: AccountDest(name: item.0)) {
                        HStack(spacing: 12) {
                            IconBadge(symbol: item.0.hasPrefix("Income") ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                                      color: item.0.hasPrefix("Income") ? .green : .gray, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leaf(item.0))
                                Text(acctZH(item.0) ?? (item.0.hasPrefix("Income") ? LS("收入") : LS("支出"))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: -item.1, color: true)
                        }
                    }
                }
            } header: {
                Text(year + LS(" 年收支科目"))
            }
        }
    }

    /// 待核对 and 投资持仓 side by side (投资持仓 only with holdings)
    private func tilesSection(_ L: Ledger) -> some View {
        let due = reconcileDue(L)
        let failing = Set(L.balanceResults.filter { !$0.ok }.compactMap { $0.entry.account }).count
        let hs = holdings(L)
        return Section {
            HStack(spacing: 10) {
                NavigationLink(value: ReconcileDest()) {
                    tile(icon: "doc.text.magnifyingglass", color: .orange, title: LS("待核对"),
                         line: due.isEmpty ? (failing > 0 ? LS("%@ 个断言不符", failing) : LS("都已核对")) : LS("%@ 个账户", due.count),
                         sub: nil, subColor: .secondary, dot: !due.isEmpty || failing > 0)
                }
                .buttonStyle(.plain)
                if !hs.isEmpty {
                    let value = hs.reduce(0.0) { $0 + (toCNY(L, $1.value ?? $1.cost, $1.q) ?? 0) }
                    let cost = hs.reduce(0.0) { $0 + (toCNY(L, $1.cost, $1.q) ?? 0) }
                    NavigationLink(value: HoldingsDest()) {
                        tile(icon: "chart.line.uptrend.xyaxis", color: .jade, title: LS("投资持仓"), line: masked(money(value, L.base)),
                             sub: cost > 0 ? String(format: "%@%.1f%%", value >= cost ? "+" : "", (value - cost) / cost * 100) : nil,
                             subColor: value >= cost ? Color.gain : Color.loss, dot: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardRow()
        }
    }

    private func tile(icon: String, color: Color, title: String, line: String, sub: String?, subColor: Color, dot: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if let s = sub { Text(s).font(.caption.monospacedDigit()).foregroundStyle(subColor) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if dot { Circle().fill(Color.orange).frame(width: 8, height: 8).padding(10) }
        }
        .contentShape(Rectangle())
    }

    private func list(_ L: Ledger) -> some View {
        let today = Day.today()
        let v = valued(L)
        let ag = groups(L, "Assets", today, v)
        let lg = groups(L, "Liabilities", today, v)
        // the hero is 净资产: without the accounts left out of it (the group totals below are every account's)
        let counted = { (gs: [(String, [Row])]) in gs.flatMap { $0.1 }.filter { !isExcluded($0.account, store.netWorthExclude) } }
        let assets = total(counted(ag)), liab = total(counted(lg))
        return List {
            if !store.cview.isDefault { Section { CurrencyBanner() } }
            heroSection(L, assets: assets, liab: liab)
            tilesSection(L)
            Section {
                NavigationLink(value: CounterpartyDest()) { Label(LS("往来"), systemImage: "person.2") }
            }
            Section {
                Picker(LS("显示"), selection: $side) {
                    Text(LS("全部")).tag("all")
                    Text(LS("资产")).tag("assets")
                    Text(LS("负债")).tag("liabilities")
                }
                .pickerStyle(.segmented)
                .cardRow()
            }
            if side != "liabilities" { ForEach(ag, id: \.0) { g in groupSection(L, "Assets", g.0, g.1) } }
            if side != "assets" { ForEach(lg, id: \.0) { g in groupSection(L, "Liabilities", g.0, g.1) } }
            ytdSection(L, String(today.prefix(4)))
        }
        .listSectionSpacing(.compact)
        .refreshable { await store.refresh() }
    }

    private func ytd(_ L: Ledger, _ year: String) -> [(String, Double)] {
        var m: [String: Double] = [:]
        for t in L.txns where t.date.hasPrefix(year) {
            for p in t.postings where p.units != nil && (p.account.hasPrefix("Income:") || p.account.hasPrefix("Expenses:")) {
                m[catOf(p.account), default: 0] += toCNY(L, p.units!, p.currency ?? "CNY", t.date) ?? 0
            }
        }
        return m.sorted { abs($0.value) > abs($1.value) }.map { ($0.key, $0.value) }
    }
}

/// icon and colour for an account group
struct AccountKind {
    static let order = ["Bank", "EWallet", "Cash", "Brokerage", "Crypto", "Receivable", "CreditCard", "Loan"]
    let symbol: String
    let color: Color
    init(symbol: String, color: Color) { self.symbol = symbol; self.color = color }
    init(_ group: String) {
        switch group {
        case "Bank": symbol = "building.columns.fill"; color = .blue
        case "EWallet": symbol = "wallet.pass.fill"; color = .teal
        case "Cash": symbol = "banknote.fill"; color = .green
        case "Brokerage": symbol = "chart.line.uptrend.xyaxis"; color = .purple
        case "Crypto": symbol = "bitcoinsign"; color = .orange
        case "Receivable": symbol = "tray.and.arrow.down.fill"; color = .indigo
        case "CreditCard": symbol = "creditcard.fill"; color = .red
        case "Loan": symbol = "percent"; color = .pink
        default: symbol = "folder.fill"; color = .gray
        }
    }
    static func of(_ account: String) -> AccountKind {
        let p = account.components(separatedBy: ":")
        return AccountKind(p.count > 1 ? p[1] : account)
    }
}

struct AccountRow: View {
    @EnvironmentObject var store: Store
    let account: String
    let balances: [(String, Double)]
    let closed: Bool
    let failing: Bool
    var kind: AccountKind? = nil
    /// the balance valued as chosen (币种与换算), shown first when it differs from the balances as booked
    var shown: Inventory? = nil

    var body: some View {
        let p = account.components(separatedBy: ":")
        let leafName = p.count > 2 ? p[2...].joined(separator: ":") : (p.count > 1 ? p[1] : account)
        let shownName = store.displayName(account).flatMap { $0.isEmpty ? nil : $0 } ?? leafName
        let k = kind ?? store.groupIcon(account)
        let card = store.L.flatMap { L in cardCycles(L).first { $0.account == account } }
        let owed = account.hasPrefix("Liabilities:") && balances.contains { $0.1 < -0.005 }
        HStack(spacing: 12) {
            IconBadge(symbol: k.symbol, color: closed ? .gray : k.color, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shownName).foregroundStyle(closed ? Color.secondary : Color.primary).lineLimit(1)
                    if failing { Tag(text: LS("断言不符"), warn: true) }
                    if closed { Tag(text: LS("已关闭")) }
                    if isExcluded(account, store.netWorthExclude) { Tag(text: LS("不计入净资产")) }
                }
                HStack(spacing: 6) {
                    if let c = card, owed, c.statementAmount - c.paid > 0.005 {
                        let days = daysBetween(Day.today(), c.due)
                        Text(LS("%@还款", monthDay(c.due))).lineLimit(1)
                        if days >= 0 && days <= 7 {
                            Text(days == 0 ? LS("今天") : LS("%@天后", days))
                                .font(.caption2.weight(.semibold)).foregroundStyle(Color.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        }
                    } else {
                        Text(subtitle(leafName)).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if owed { Text(LS("待还")).font(.caption2).foregroundStyle(.secondary) }
                if balances.isEmpty { Text("0.00").foregroundStyle(.secondary).monospacedDigit() }
                let base = store.L?.base ?? "CNY"
                let valued = shown?.byCurrency(base: base) ?? []
                let same = shown == nil || Set(valued.map { $0.currency }) == Set(balances.map { $0.0 })
                if same {
                    ForEach(balances, id: \.0) { b in
                        Amount(n: b.1, c: b.0, d: abs(b.1) < 1 && b.0.count > 3 ? 4 : 2)
                            .font(balances.count > 1 ? .subheadline : .body)
                    }
                } else {
                    // valued (converted, at cost or market) first, what the account holds under it
                    ForEach(valued) { x in
                        Text(unitText(x.amount, x.currency)).monospacedDigit().sensitive()
                    }
                    Text(balances.map { unitText($0.1, $0.0) }.joined(separator: " · "))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7).sensitive()
                }
            }
        }
        .padding(.vertical, 1)
    }

    /// under the name: the currencies held, else the card's last digits, else when it was last checked, else its name
    private func subtitle(_ leafName: String) -> String {
        if balances.count > 1 { return balances.map { $0.0 }.joined(separator: " · ") }
        if let tail = store.repoConfig?.scanCards?.first(where: { $0.value == account && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) })?.key {
            return LS("尾号 %@", tail)
        }
        if let L = store.L, let last = L.balanceResults.filter({ $0.ok && $0.entry.account == account }).map({ $0.entry.date }).max() {
            // an assertion checks the start of its day: it was checked the day before
            let ago = daysBetween(last, Day.today()) + 1
            if ago >= 0 && ago <= 30 {
                return ago == 0 ? LS("今天已核对") : ago == 1 ? LS("昨天已核对") : LS("%@ 天前已核对", ago)
            }
        }
        return store.displayName(account) != nil ? leafName : account
    }

    /// "10月20日"
    private func monthDay(_ d: String) -> String {
        LS("%@月%@日", String(Int(d.dropFirst(5).prefix(2)) ?? 0), String(Int(d.suffix(2)) ?? 0))
    }
}

// MARK: - register

struct RegisterView: View {
    @EnvironmentObject var store: Store
    let account: String
    @State private var checking: CheckPreset?
    /// months opened or closed by hand (the rest follow `open`)
    @State private var opened: [String: Bool] = [:]
    @State private var reimb: ReimbTarget?
    @State private var deleting: Entry?
    @State private var noting: NoteEdit?

    enum Item { case txn(Entry, String), balance(BalanceResult), document(Entry), note(Entry) }

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { ProgressView() }
        }
        .navigationTitle(acctLabel(account).isEmpty ? account : acctLabel(account))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $checking) { p in CheckSheet(account: account, preset: p) }
        .sheet(item: $noting) { NoteSheet(account: account, note: $0.note) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { noting = NoteEdit(note: nil) } label: { Label(LS("添加备注"), systemImage: "text.bubble") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(LS("更多"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AccountEditDest(name: account)) { Image(systemName: "pencil.circle") }
                    .accessibilityLabel(LS("编辑账户"))
            }
        }
        .navigationDestination(for: AccountEditDest.self) { AccountEditView(name: $0.name) }
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .confirmationDialog(deleting.map { LS("删除 %@ 的余额断言？", $0.date) } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(LS("删除"), role: .destructive) {
                if let e = deleting { Task { await store.deleteBalance(e) } }
                deleting = nil
            }
        } message: {
            Text(LS("将从账本文件中移除这一行断言。"))
        }
        .task {
            if store.demoEnv["LEDGER_CHECK"] != nil { checking = CheckPreset(actual: store.demoEnv["LEDGER_CHECK"]) }
        }
    }

    private func canCheck(_ L: Ledger) -> Bool {
        (account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:")) && L.accounts[account]?.close == nil
    }

    private func page(_ L: Ledger) -> some View {
        let built = build(L)
        let (months, c) = monthGroups(built.0, L)
        let check = canCheck(L)
        let first = months.first?.ym
        return List {
            header(L, built.1)
            if account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:") { countsSection() }
            if let c = cardCycles(L).first(where: { $0.account == account }) { CardBillSection(cycle: c) }
            if months.isEmpty { Section { Text(LS("暂无记录")).foregroundStyle(.secondary) } }
            // a month to a section: its totals on top, its entries (newest first) once opened
            ForEach(months) { m in
                Section {
                    monthRow(m, c, first: first)
                    if open(m, first: first) {
                        ForEach(Array(m.items.reversed().enumerated()), id: \.offset) { pair in itemRow(pair.element, check) }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    /// one month of the register
    struct Month: Identifiable {
        let ym: String
        var items: [Item] = []
        /// money in and out of the account (or, for a category, its total), in `currency`
        var inflow = 0.0
        var outflow = 0.0
        var count = 0
        /// the running balance after the month's last entry
        var closing = ""
        var id: String { ym }
    }

    /// The register by month, newest first. Amounts are in the account's own currency when it has one, else
    /// converted to the operating currency on each day.
    private func monthGroups(_ items: [Item], _ L: Ledger) -> ([Month], String) {
        let pre = account + ":"
        let own = Set(L.txns.lazy.flatMap { $0.postings }.filter { $0.account == account || $0.account.hasPrefix(pre) }.compactMap { $0.currency })
        let single = own.count == 1 ? own.first : nil
        var by: [String: Month] = [:]
        for it in items {
            let date: String
            switch it {
            case .txn(let t, _): date = t.date
            case .balance(let r): date = r.entry.date
            case .document(let e): date = e.date
            case .note(let e): date = e.date
            }
            let ym = Day.ym(date)
            var m = by[ym] ?? Month(ym: ym)
            m.items.append(it)
            if case .txn(let t, let b) = it {
                m.count += 1
                m.closing = b
                for p in t.postings where p.account == account || p.account.hasPrefix(pre) {
                    guard let u = p.units, let c = p.currency else { continue }
                    let v = single != nil ? u : (toCNY(L, u, c, t.date) ?? 0)
                    if v > 0 { m.inflow += v } else { m.outflow -= v }
                }
            }
            by[ym] = m
        }
        return (by.values.sorted { $0.ym > $1.ym }, single ?? L.base)
    }

    /// the latest month with entries starts open
    private func open(_ m: Month, first: String?) -> Bool {
        opened[m.ym] ?? (m.ym == first)
    }

    private func monthRow(_ m: Month, _ c: String, first: String?) -> some View {
        let isIE = account.hasPrefix("Expenses") || account.hasPrefix("Income")
        let on = open(m, first: first)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { opened[m.ym] = !on }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Day.monthLabel(m.ym)).font(.headline)
                    Text(LS("%@ 笔", m.count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if isIE {
                        // a category: what it came to (spending positive, income positive)
                        let total = account.hasPrefix("Income") ? m.outflow - m.inflow : m.inflow - m.outflow
                        Text(money(total, c)).font(.subheadline.weight(.semibold).monospacedDigit()).sensitive()
                    } else {
                        if m.outflow > 0.004 {
                            Text(LS("流出 %@", money(m.outflow, c))).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Color.loss).sensitive()
                        }
                        if m.inflow > 0.004 {
                            Text(LS("流入 %@", money(m.inflow, c))).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Color.gain).sensitive()
                        }
                        if !m.closing.isEmpty {
                            Text(LS("月末 %@", m.closing)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(on ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(on ? LS("收起") : LS("展开"))
    }

    /// whether this account counts in 净资产 and in 资产负债表 (saved to ledger-x.json at once)
    private func countsSection() -> some View {
        let nwParent = store.netWorthExclude.first { account.hasPrefix($0 + ":") }
        let bsParent = store.balanceExclude.first { account.hasPrefix($0 + ":") }
        return Section {
            Toggle(LS("计入净资产"), isOn: Binding(get: { !isExcluded(account, store.netWorthExclude) },
                                                set: { on in Task { await store.setExcluded(account, netWorth: !on) } }))
                .disabled(nwParent != nil)
            Toggle(LS("显示在资产负债表"), isOn: Binding(get: { !isExcluded(account, store.balanceExclude) },
                                                  set: { on in Task { await store.setExcluded(account, balance: !on) } }))
                .disabled(bsParent != nil)
        } footer: {
            if let p = nwParent ?? bsParent { Text(LS("随 %@ 一起排除，在 %@ 里修改。", p, LedgerXConfig.path)) }
        }
        .tint(.jade)
    }

    private func header(_ L: Ledger, _ bal: [(String, Double)]) -> some View {
        let isIE = account.hasPrefix("Income") || account.hasPrefix("Expenses")
        let bs = bal.filter { abs($0.1) > 0.0049 }
        let closedNote = L.accounts[account]?.close.map { LS(" · 已于 %@ 关闭", $0) } ?? ""
        let check = canCheck(L)
        let k = store.groupIcon(account)
        let isIEIcon = account.hasPrefix("Income") ? ("arrow.down.circle.fill", Color.green) : ("arrow.up.circle.fill", Color.gray)
        return Section {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconBadge(symbol: isIE ? isIEIcon.0 : k.symbol, color: isIE ? isIEIcon.1 : k.color, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.displayName(account).map { acctLabel(account) + " · " + $0 } ?? acctDisplay(account)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(account + closedNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isIE ? LS("累计发生额") : LS("当前余额")).font(.caption).foregroundStyle(.secondary)
                        if bs.isEmpty { Text("0.00").font(.system(size: 30, weight: .bold, design: .rounded)) }
                        ForEach(bs, id: \.0) { b in
                            Text(money(isIE ? -b.1 : b.1, b.0)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                        }
                    }
                    HStack(spacing: 8) {
                        Button { store.journalAccount = account; store.tab = .journal } label: { Label(LS("查看明细"), systemImage: "list.bullet") }
                        if account == store.receivable, !(store.D?.unclaimed.isEmpty ?? true) {
                            Button { reimb = ReimbTarget(link: nil) } label: { Label(LS("登记报销回款"), systemImage: "arrow.down.left") }
                        }
                        if check { Button { checking = CheckPreset() } label: { Label(LS("余额核对"), systemImage: "checkmark.seal") } }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.subheadline.weight(.medium))
                }
            }
            .cardRow()
        }
    }

    @ViewBuilder
    private func itemRow(_ it: Item, _ check: Bool) -> some View {
        switch it {
        case .txn(let t, let b):
            NavigationLink(value: TxDest(t)) { TxRow(t: t, account: account, balance: b, showDate: true) }
        case .balance(let r):
            let own = r.entry.account == account && check
            BalanceRow(r: r) {
                if own { checking = CheckPreset(date: r.entry.date, currency: r.entry.currency, actual: jsNumberString(r.entry.number), original: r.entry) }
            }
            .swipeActions(edge: .trailing) {
                if r.entry.account == account {
                    Button(role: .destructive) { deleting = r.entry } label: { Label(LS("删除"), systemImage: "trash") }
                    if own {
                        Button { checking = CheckPreset(date: r.entry.date, currency: r.entry.currency, actual: jsNumberString(r.entry.number), original: r.entry) } label: { Label(LS("编辑"), systemImage: "pencil") }
                            .tint(.orange)
                    }
                }
            }
            .contextMenu {
                if r.entry.account == account {
                    if own {
                        Button { checking = CheckPreset(date: r.entry.date, currency: r.entry.currency, actual: jsNumberString(r.entry.number), original: r.entry) } label: { Label(LS("编辑断言"), systemImage: "pencil") }
                    }
                    Button(role: .destructive) { deleting = r.entry } label: { Label(LS("删除断言"), systemImage: "trash") }
                }
            }
        case .note(let n):
            Button { noting = NoteEdit(note: n) } label: { NoteRow(note: n, account: account) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { Task { _ = await store.deleteDirective(n, summary: LS("备注")) } } label: { Label(LS("删除"), systemImage: "trash") }
                    Button { noting = NoteEdit(note: n) } label: { Label(LS("编辑"), systemImage: "pencil") }.tint(.orange)
                }
                .contextMenu {
                    Button { noting = NoteEdit(note: n) } label: { Label(LS("编辑备注"), systemImage: "pencil") }
                    Button(role: .destructive) { Task { _ = await store.deleteDirective(n, summary: LS("备注")) } } label: { Label(LS("删除备注"), systemImage: "trash") }
                }
        case .document(let d):
            HStack {
                Image(systemName: "doc.text")
                Text(d.date + LS(" 对账单"))
                Spacer()
                if let p = d.path, let u = docURL(d) {
                    Link((p as NSString).lastPathComponent, destination: u).font(.caption)
                } else {
                    Text(((d.path ?? "") as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private func docURL(_ d: Entry) -> URL? {
        documentRepoPath(d).flatMap { store.githubURL($0) }
    }

    private func build(_ L: Ledger) -> ([Item], [(String, Double)]) {
        var items: [Item] = []
        var bal: [String: Double] = [:]
        var order: [String] = []
        let pre = account + ":"
        for e in L.entries {
            switch e.type {
            case .txn:
                let ps = e.postings.filter { $0.account == account || $0.account.hasPrefix(pre) }
                if ps.isEmpty { continue }
                for p in ps { if let u = p.units, let c = p.currency { if bal[c] == nil { order.append(c) }; bal[c, default: 0] += u } }
                let text = order.filter { abs(bal[$0]!) > 0.0049 }.map { money(bal[$0]!, $0) }.joined(separator: " ")
                items.append(.txn(e, text))
            case .balance:
                if let a = e.account, a == account || a.hasPrefix(pre), let r = L.balanceResults.first(where: { $0.entry === e }) { items.append(.balance(r)) }
            case .document:
                if e.account == account { items.append(.document(e)) }
            case .note:
                if let a = e.account, a == account || a.hasPrefix(pre) { items.append(.note(e)) }
            default: break
            }
        }
        // pad transactions are not in entries; fold them in from txns
        for t in L.txns where t.synthetic && t.postings.contains(where: { $0.account == account || $0.account.hasPrefix(pre) }) {
            for p in t.postings where p.account == account || p.account.hasPrefix(pre) {
                if let u = p.units, let c = p.currency { if bal[c] == nil { order.append(c) }; bal[c, default: 0] += u }
            }
        }
        return (items, order.map { ($0, bal[$0]!) })
    }
}

struct BalanceRow: View {
    let r: BalanceResult
    let tap: () -> Void
    var body: some View {
        let c = r.entry.currency ?? "CNY"
        Button(action: tap) {
            HStack {
                Text(r.entry.date + LS(" 余额断言")).font(.subheadline)
                Text(money(r.entry.number, c)).font(.subheadline.monospacedDigit()).sensitive()
                Spacer()
                if r.ok {
                    Label(LS("相符"), systemImage: "checkmark").font(.caption).foregroundStyle(Color.gain)
                } else {
                    Text(LS("实际 ") + money(r.got, c)).font(.caption.monospacedDigit()).foregroundStyle(Color.loss).sensitive()
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(r.ok ? Color.gain.opacity(0.06) : Color.loss.opacity(0.08))
    }
}

struct CheckPreset: Identifiable {
    let id = UUID()
    var date: String?
    var currency: String?
    var actual: String?
    /// editing an existing assertion: it is removed when the new one is written
    var original: Entry?
}

// MARK: - 对账

struct CheckSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let account: String
    let preset: CheckPreset
    @State private var date = Day.shift(Day.today(), 1)
    @State private var currency = "CNY"
    @State private var actual = ""
    @State private var armed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(preset.original != nil ? LS("编辑余额断言") : LS("余额核对"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    private func balanceFile(_ L: Ledger) -> String {
        var counts: [String: Int] = [:]
        for b in L.balances { counts[b.file, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? "accounts/balance.bean"
    }

    private func form(_ L: Ledger, _ D: Derived) -> some View {
        let ccys = currencies(L, D)
        let old = existingBalance(L, account: account, date: date, currency: currency)
        let a = evalAmount(actual)
        return Form {
            inputSection(ccys)
            infoSection(L, clash(old), a)
            saveSection(L, old, a)
            if let o = preset.original {
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        Task { await store.deleteBalance(o) }
                    } label: {
                        HStack(spacing: 6) { Spacer(minLength: 0); Image(systemName: "trash"); Text(LS("删除此断言")); Spacer(minLength: 0) }
                    }
                } footer: {
                    Text(LS("修改日期、币种或金额后保存，原断言（%@ %@）将被替换，不会产生重复记录。", o.date, money(o.number, o.currency ?? "CNY")))
                }
            }
        }
        .onAppear {
            if let d = preset.date { date = d }
            currency = preset.currency ?? ccys.first ?? "CNY"
            if let x = preset.actual { actual = x }
            focused = preset.actual == nil
        }
    }

    private func inputSection(_ ccys: [String]) -> some View {
        Section {
            HStack {
                Button {
                    let t = actual.trimmed
                    actual = t.hasPrefix("-") ? String(t.dropFirst()) : "-" + t
                    armed = false
                } label: {
                    Text("±").font(.title3).frame(width: 38, height: 34).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                TextField(account.hasPrefix("Liabilities") ? LS("负债以负数填写，如 -1200") : LS("金融机构显示的实际余额"), text: $actual)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .font(.title3.monospacedDigit())
                    .onChange(of: actual) { _, _ in armed = false }
            }
            if ccys.count > 1 {
                Picker(LS("币种"), selection: $currency) {
                    ForEach(ccys, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: currency) { _, _ in armed = false }
            }
            DatePicker(LS("断言日期"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0); armed = false }), displayedComponents: .date)
        } header: {
            Text(LS("实际余额"))
        } footer: {
            Text(LS("Beancount 余额断言在当日开始时校验；断言日期设为明天，即核对今日日终余额。"))
        }
    }

    private func infoSection(_ L: Ledger, _ old: BalanceResult?, _ a: Double?) -> some View {
        let book = bookAt(L)
        let diff = a.map { roundTo($0 - book, 2) }
        return Section {
            LabeledContent(LS("账本余额（%@ 之前）", date)) {
                Text(money(book, currency)).monospacedDigit().sensitive()
            }
            if let diff = diff {
                LabeledContent(LS("差额")) {
                    Text(abs(diff) > 0.004 ? signedMoney(diff, currency) + LS("，请先补录遗漏的交易") : LS("一致"))
                        .foregroundStyle(abs(diff) > 0.004 ? Color.loss : Color.gain)
                        .monospacedDigit()
                        .sensitive()
                }
            }
            if let o = old {
                LabeledContent(LS("%@ 已存在余额断言", date)) {
                    Text(money(o.entry.number, currency) + (o.ok ? LS("（相符）") : LS("（不符）"))).monospacedDigit().sensitive()
                }
                .foregroundStyle(.orange)
            }
            if let a = a {
                MonoText(text: balanceLine(date, account, a, currency))
                Text(old != nil ? LS("将覆盖 %@ 中的原断言。", old!.entry.file) : preset.original.map { LS("将替换 %@ 中的原断言。", $0.file) } ?? LS("将写入 %@，位于该账户已有断言之后。", balanceFile(L)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// another assertion (not the one being edited) already on this date and currency
    private func clash(_ old: BalanceResult?) -> BalanceResult? {
        guard let o = old else { return nil }
        if let orig = preset.original, o.entry === orig { return nil }
        return o
    }

    private func saveSection(_ L: Ledger, _ old0: BalanceResult?, _ a: Double?) -> some View {
        let old = clash(old0)
        let title = old != nil ? (armed ? LS("再次点按以确认覆盖") : LS("覆盖原断言")) : preset.original != nil ? LS("保存修改") : LS("写入余额断言")
        return Section {
            Button {
                save(L, old, a)
            } label: {
                Text(title).frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(old != nil ? Color.orange : Color.jade)
            .controlSize(.large)
            .disabled(a == nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func save(_ L: Ledger, _ old0: BalanceResult?, _ a: Double?) {
        guard let a = a else { store.show(LS("请填写实际余额")); return }
        if let orig = preset.original {
            saveEdit(L, orig, old0, a)
            return
        }
        let old = old0
        if old != nil && !armed { armed = true; return }
        var op = Op(kind: .balance, path: old?.entry.file ?? balanceFile(L))
        op.account = account
        op.date = date
        op.currency = currency
        op.replace = old != nil
        op.line = balanceLine(date, account, a, currency)
        op.label = (old != nil ? LS("覆盖余额断言：") : LS("余额核对：")) + account + " " + date
        op.summary = (old != nil ? LS("覆盖") : "") + LS("余额断言 ") + account
        op.amountText = plainMoney(a, currency)
        let word = old != nil ? LS("已更新余额断言") : LS("已写入余额断言")
        Task { await store.commit([op], word: word, closing: { dismiss() }) }
    }

    private func saveEdit(_ L: Ledger, _ orig: Entry, _ old0: BalanceResult?, _ a: Double) {
        let other = clash(old0)
        if other != nil && !armed { armed = true; return }
        let sameLine = old0.map { $0.entry === orig } ?? false
        var op = Op(kind: .balance, path: sameLine ? orig.file : (other?.entry.file ?? balanceFile(L)))
        op.account = account
        op.date = date
        op.currency = currency
        op.replace = sameLine || other != nil
        op.line = balanceLine(date, account, a, currency)
        op.amountText = plainMoney(a, currency)
        op.label = LS("修改余额断言：") + account + " " + date
        op.summary = LS("修改余额断言 ") + account
        Task {
            if sameLine {
                await store.commit([op], word: LS("已更新余额断言"), closing: { dismiss() })
                return
            }
            guard var rm = await store.balanceRemoveOp(orig) else { store.show(LS("未在 %@ 中找到原断言", orig.file)); return }
            rm.label = op.label
            op.label = nil
            op.silent = true
            await store.commit([rm, op], word: LS("已更新余额断言"), closing: { dismiss() })
        }
    }

    private func currencies(_ L: Ledger, _ D: Derived) -> [String] {
        var cs = (L.final[account] ?? [:]).filter { abs($0.value) > 0.0049 }.map { $0.key }.sorted()
        if let c = D.acctCcy[account], !cs.contains(c) { cs.append(c) }
        if cs.isEmpty { cs = ["CNY"] }
        if let p = preset.currency, !cs.contains(p) { cs.append(p) }
        return cs
    }

    private func bookAt(_ L: Ledger) -> Double {
        var n = 0.0
        let pre = account + ":"
        for t in L.txns {
            if t.date >= date { break }
            for p in t.postings where (p.account == account || p.account.hasPrefix(pre)) && p.currency == currency { n += p.units ?? 0 }
        }
        return roundTo(n, 2)
    }
}
