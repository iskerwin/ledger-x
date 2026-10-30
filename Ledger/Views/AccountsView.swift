import SwiftUI
import LedgerKit

struct AccountsView: View {
    @Environment(Store.self) var store
    @State private var path = NavigationPath()
    @State private var pricing = false
    @AppStorage("ledger.showClosed") private var showClosed = false
    /// account groups folded away on this page ("Assets:Bank", …)
    @AppStorage("ledger.accounts.collapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    /// 全部 / 资产 / 负债
    @AppStorage("ledger.accounts.side") private var side = "all"

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L { list(L) } else { PageLoading() }
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
            .navigationDestination(for: CounterpartyDest.self) { _ in CounterpartyView().privacyToolbar() }
            .navigationDestination(for: TransactionAttachmentsDest.self) { _ in TransactionAttachmentsView().privacyToolbar() }
            .navigationDestination(for: NetWorthSettingsDest.self) { _ in NetWorthSettingsView() }
            .navigationDestination(for: YearReviewDest.self) { YearReviewView(year: $0.year).privacyToolbar(currency: true) }
            .navigationDestination(for: ReconcileDest.self) { _ in ReconcileView().privacyToolbar() }
        }
        .sheet(isPresented: $pricing) { PriceUpdateSheet() }
        // on the stack itself: the pages it opens inherit what is set here, not what is set on its first page
        .pushes(onto: $path)
        .ledgerNavigation("accounts", path: $path)
        .ledgerControls("accounts", value: Binding(get: {
            var context = BrowseContext(); context.query = collapsedRaw; context.filters = [side]; return context
        }, set: { collapsedRaw = $0.query; side = $0.filters.first ?? "all" }))
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            if let x = store.demoEnv["LEDGER_SIDE"] { side = x }
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
                withAnimation(AppMotion.standard) {
                    var s = collapsed
                    if shut { s.remove(key) } else { s.insert(key) }
                    collapsedRaw = s.sorted().joined(separator: ",")
                }
            } label: {
                HStack(spacing: AppSpacing.icon) {
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

    /// The page's card: 净资产, or (收支) this year's income and spending. Both are laid out in the one card and
    /// only the tab's is shown, so the card is as tall as the taller one and the tabs below never move when
    /// switching, whatever the ledger's currencies or left-out accounts make 净资产 take.
    private func heroSection(_ L: Ledger, assets: Inventory, liab: Inventory, year: String) -> some View {
        let flows = side == "flows"
        return Section {
            Card {
                // several currencies as booked (按原币): both tabs a table, a row per currency
                let several = CurrencyTable.rows([assets, liab], base: L.base).count > 1
                ZStack(alignment: .topLeading) {
                    netWorth(L, assets: assets, liab: liab, several: several).concealed(flows)
                    yearFlows(L, year, several: several).concealed(!flows)
                }
            }
            .cardRow()
        }
    }

    /// 净资产 as chosen: one figure, or (several currencies) a row per currency with its assets, debts and net
    @ViewBuilder
    private func netWorth(_ L: Ledger, assets: Inventory, liab: Inventory, several: Bool) -> some View {
        let a1 = assets.single(base: L.base), l1 = (-liab).single(base: L.base)
        let one = a1 != nil && l1 != nil && (a1!.currency == l1!.currency || abs(l1!.amount) < 0.005)
        VStack(alignment: .leading, spacing: AppSpacing.control) {
            if several {
                Text(LS("净资产")).font(.subheadline).foregroundStyle(.secondary)
                CurrencyTable(columns: [.init(title: LS("资产")), .init(title: LS("负债")), .init(title: LS("净额"), signed: true)],
                              rows: CurrencyTable.rows([assets, -liab, assets + liab], base: L.base))
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(LS("净资产")).font(.subheadline).foregroundStyle(.secondary)
                    InventoryHeadline(inv: assets + liab, base: L.base)
                }
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    InventoryFigure(label: LS("资产"), inv: assets, base: L.base)
                    Spacer()
                    InventoryFigure(label: LS("负债"), inv: -liab, base: L.base)
                    Spacer()
                    Figure(label: LS("资产负债率"), value: one && a1!.amount > 0 && l1!.amount > 0.005 ? String(format: "%.1f%%", l1!.amount / a1!.amount * 100) : "—", alignment: .trailing)
                }
                if one, let a = a1?.amount, let l = l1?.amount {
                    RatioBar(parts: [(max(0, a - max(0, l)), Color.jadeInk), (max(0, l), Color.secondary)])
                }
            }
            // a line under the bar here as under 收支's, so the two tabs say as much and are as tall
            NavigationLink(value: NetWorthSettingsDest()) {
                let change = netWorthSinceLastMonth(L, exclude: store.netWorthExclude)
                let left = store.netWorthExclude.isEmpty ? "" : LS(" · 不计入 %@ 个账户", store.netWorthExclude.count)
                (Text(LS("较上月末 ")) + (change.map { changeText($0, money(abs($0), L.base), more: .gain) } ?? Text("—")) + Text(left))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).sensitive()
            }
            .accessibilityIdentifier("accounts.nwLine")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// a change as an arrow and its figure: better green, worse red, unchanged grey; `more` is the colour of going up
    private func changeText(_ c: Double, _ figure: String, more: Color) -> Text {
        let color = Color.change(c, upIsWorse: more == .loss)
        return Text(Image(systemName: abs(c) <= 0.005 ? "minus" : c < 0 ? "arrow.down.right" : "arrow.up.right")).foregroundColor(color) + Text(figure).foregroundColor(color)
    }

    /// this year's income, spending and what is left, for 收支: in the base currency, or (several currencies, as
    /// 净资产 is shown) a row per currency as booked
    private func yearFlows(_ L: Ledger, _ year: String, several: Bool) -> some View {
        let ie = ytd(L, year)
        let income = -ie.filter { $0.0.hasPrefix("Income") }.reduce(0.0) { $0 + $1.1 }
        let spent = ie.filter { $0.0.hasPrefix("Expenses") }.reduce(0.0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: AppSpacing.control) {
            if several {
                let f = ytdByCurrency(L, year)
                Text(LS("%@ 年收支", year)).font(.subheadline).foregroundStyle(.secondary)
                CurrencyTable(columns: [.init(title: LS("收入"), color: .gain), .init(title: LS("支出"), color: .loss), .init(title: LS("结余"), signed: true)],
                              rows: CurrencyTable.rows([f.0, f.1, f.0 + (-f.1)], base: L.base))
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(LS("%@ 年结余", year)).font(.subheadline).foregroundStyle(.secondary)
                    Text(money(income - spent, L.base)).heroAmount().monospacedDigit()
                        .rollingNumber(income - spent)
                        .foregroundStyle(income - spent < 0 ? Color.loss : Color.primary).sensitive()
                }
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    Figure(label: LS("收入"), value: money(income, L.base), color: .gain)
                    Spacer()
                    Figure(label: LS("支出"), value: money(spent, L.base), color: .loss)
                    Spacer()
                    Figure(label: LS("储蓄率"), value: income > 0.005 ? String(format: "%.1f%%", (income - spent) / income * 100) : "—", alignment: .trailing)
                }
                RatioBar(parts: [(max(0, income - spent), Color.gain), (spent, Color.loss)])
            }
            // by the month, and the spending against the same days of last year (more in red, less in green)
            NavigationLink(value: YearReviewDest(year: year)) {
                let pace = yearPace(L, year: year)
                let then = pace.spentChange.map { Text(LS("比去年同期 ")) + changeText($0, String(format: "%.0f%%", abs($0) * 100), more: .loss) }
                    ?? Text(LS("月均结余 %@", money(pace.monthlySaved, L.base, 0)))
                (Text(LS("月均支出 %@", money(pace.monthlySpent, L.base, 0)) + " · ") + then)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).sensitive()
            }
            .accessibilityIdentifier("accounts.flowLine")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 收支: this year's income categories, then the spending ones, each group with its total
    @ViewBuilder
    private func ytdSection(_ L: Ledger, _ year: String) -> some View {
        let ie = ytd(L, year)
        let inc = ie.filter { $0.0.hasPrefix("Income") }, exp = ie.filter { $0.0.hasPrefix("Expenses") }
        if ie.isEmpty {
            Section { Text(LS("%@ 年还没有收支", year)).foregroundStyle(.secondary) }
        }
        ForEach([(LS("收入"), inc), (LS("支出"), exp)], id: \.0) { title, rows in
            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.0) { item in
                        NavigationLink(value: AccountDest(name: item.0)) {
                            HStack(spacing: AppSpacing.icon) {
                                IconBadge(symbol: item.0.hasPrefix("Income") ? "arrow.down.circle.fill" : store.catIcon(item.0),
                                          color: IconTint.color(store.catStyle.colors?[item.0]) ?? (item.0.hasPrefix("Income") ? .green : .gray), size: 28)
                                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                    Text(leaf(item.0))
                                    Text(acctZH(item.0) ?? (item.0.hasPrefix("Income") ? LS("收入") : LS("支出"))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Amount(n: -item.1, color: true)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: AppSpacing.control) {
                        Text(year + " " + title)
                        Spacer()
                        Text(money(abs(rows.reduce(0.0) { $0 + $1.1 }), L.base)).monospacedDigit().textCase(nil).sensitive()
                    }
                }
            }
        }
    }

    /// 待核对 and 投资持仓 side by side (投资持仓 only with holdings)
    private func tilesSection(_ L: Ledger) -> some View {
        let dueAccounts = Set(reconcileDue(L).map { $0.account })
        let failingAccounts = Set(L.balanceResults.filter { !$0.ok }.compactMap { $0.entry.account })
        // accounts to look at: due for a check, or with an assertion that fails (each counted once)
        let open = dueAccounts.union(failingAccounts).count
        let hs = holdings(L)
        return Section {
            HStack(spacing: AppSpacing.icon) {
                // buttons, not links: a link in a row draws its own chevron beside the tile
                Button { path.append(ReconcileDest()) } label: {
                    if open == 0 {
                        tile(icon: "checkmark.seal", color: .gain, title: LS("核对完成"), line: LS("账户都已核对"),
                             sub: nil, subColor: .secondary, dot: false)
                    } else {
                        tile(icon: "doc.text.magnifyingglass", color: Color.warn, title: LS("待核对 · %@ 个", open),
                             line: [dueAccounts.isEmpty ? nil : LS("%@ 个到核对日", dueAccounts.count),
                                    failingAccounts.isEmpty ? nil : LS("%@ 个断言不符", failingAccounts.count)].compactMap { $0 }.joined(separator: " · "),
                             sub: nil, subColor: .secondary, dot: true)
                    }
                }
                .buttonStyle(.plain)
                if !hs.isEmpty {
                    let value = hs.reduce(0.0) { $0 + (toCNY(L, $1.value ?? $1.cost, $1.q) ?? 0) }
                    let cost = hs.reduce(0.0) { $0 + (toCNY(L, $1.cost, $1.q) ?? 0) }
                    Button { path.append(HoldingsDest()) } label: {
                        tile(icon: "chart.line.uptrend.xyaxis", color: .jade, title: LS("投资持仓"), line: masked(money(value, L.base)),
                             sub: cost > 0 ? (value >= cost ? LS("持仓浮盈 %@", String(format: "+%.1f%%", (value - cost) / cost * 100))
                                                           : LS("持仓浮亏 %@", String(format: "−%.1f%%", (cost - value) / cost * 100))) : nil,
                             subColor: value >= cost ? Color.gain : Color.loss, dot: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardRow()
        }
    }

    private func tile(icon: String, color: Color, title: String, line: String, sub: String?, subColor: Color, dot: Bool) -> some View {
        HStack(spacing: AppSpacing.icon) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                if let s = sub { Text(s).font(.caption.monospacedDigit()).foregroundStyle(subColor).lineLimit(1).minimumScaleFactor(0.7) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(AppSpacing.control)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if dot { Circle().fill(Color.warn).frame(width: 8, height: 8).padding(AppSpacing.icon) }
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
        let year = String(today.prefix(4))
        return List {
            if !store.cview.isDefault { Section { CurrencyBanner() } }
            // the hero follows the tab (收支: this year's income and spending); 待核对, 投资持仓 and 往来 stay in every tab
            heroSection(L, assets: assets, liab: liab, year: year)
            tilesSection(L)
            Section {
                NavigationLink(value: CounterpartyDest()) { Label(LS("往来"), systemImage: "person.2").labelStyle(ControlLabelStyle()) }
                NavigationLink(value: TransactionAttachmentsDest()) {
                    LabeledContent {
                        let n = transactionAttachments(L).count
                        if n > 0 { Text(LS("%@ 个", n)) }
                    } label: { Label(LS("交易附件"), systemImage: "paperclip").labelStyle(ControlLabelStyle()) }
                }
                let prices = PriceUpdateSheet.items(L)
                if !prices.isEmpty {
                    // a row with its words: the icon on 投资持仓 alone was easy to miss, and there is none without holdings
                    Button { pricing = true } label: {
                        LabeledContent {
                            let latest = prices.compactMap { $0.date }.max()
                            if let d = latest { Text(LS("最新 %@", d)) }
                        } label: { Label(LS("更新价格"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle()) }
                    }
                    .accessibilityIdentifier("accounts.updatePrices")
                }
            }
            Section {
                Picker(LS("显示"), selection: $side) {
                    Text(LS("全部")).tag("all")
                    Text(LS("资产")).tag("assets")
                    Text(LS("负债")).tag("liabilities")
                    Text(LS("收支")).tag("flows")
                }
                .pickerStyle(.segmented)
                .cardRow()
            }
            if side == "flows" {
                ytdSection(L, year)
            } else {
                if side != "liabilities" { ForEach(ag, id: \.0) { g in groupSection(L, "Assets", g.0, g.1) } }
                if side != "assets" { ForEach(lg, id: \.0) { g in groupSection(L, "Liabilities", g.0, g.1) } }
            }
        }
        .listSectionSpacing(.compact)
        .refreshable { await store.refresh() }
    }

    /// this year's income and spending in the currencies they were booked in (the ones counted, 币种与换算)
    private func ytdByCurrency(_ L: Ledger, _ year: String) -> (Inventory, Inventory) {
        let only = store.conly
        var inc = Inventory(), exp = Inventory()
        for t in L.txns where t.date.hasPrefix(year) {
            for p in t.postings {
                guard let u = p.units, let c = p.currency, only?.contains(c) ?? true else { continue }
                if p.account.hasPrefix("Income:") { inc.add(-u, c) } else if p.account.hasPrefix("Expenses:") { exp.add(u, c) }
            }
        }
        return (inc, exp)
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

/// icon and colour for an account group: never the green of money in or the red of money out, which a badge beside a balance would seem to say
struct AccountKind {
    static let order = ["Bank", "EWallet", "Cash", "Brokerage", "Crypto", "Receivable", "CreditCard", "Loan"]
    let symbol: String
    let color: Color
    init(symbol: String, color: Color) { self.symbol = symbol; self.color = color }
    init(_ group: String) {
        switch group {
        case "Bank": symbol = "building.columns.fill"; color = .blue
        case "EWallet": symbol = "wallet.pass.fill"; color = .cyan
        case "Cash": symbol = "banknote.fill"; color = .brown
        case "Brokerage": symbol = "chart.line.uptrend.xyaxis"; color = .purple
        case "Crypto": symbol = "bitcoinsign"; color = .orange
        case "Receivable": symbol = "tray.and.arrow.down.fill"; color = .teal
        case "CreditCard": symbol = "creditcard.fill"; color = .indigo
        case "Loan": symbol = "percent"; color = .gray
        default: symbol = "folder.fill"; color = .gray
        }
    }
    static func of(_ account: String) -> AccountKind {
        let p = account.components(separatedBy: ":")
        return AccountKind(p.count > 1 ? p[1] : account)
    }
}

struct AccountRow: View {
    @Environment(Store.self) var store
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
        HStack(spacing: AppSpacing.icon) {
            IconBadge(symbol: k.symbol, color: closed ? .gray : k.color, size: 36)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                HStack(spacing: AppSpacing.icon) {
                    Text(shownName).foregroundStyle(closed ? Color.secondary : Color.primary).lineLimit(1)
                    if failing { Tag(text: LS("断言不符"), warn: true) }
                    if closed { Tag(text: LS("已关闭")) }
                    if isExcluded(account, store.netWorthExclude) { Tag(text: LS("不计入净资产")) }
                }
                HStack(spacing: AppSpacing.icon) {
                    if let c = card, owed, c.statementAmount - c.paid > 0.005 {
                        let today = Day.today()
                        let days = daysBetween(today, c.due)
                        let status = c.status(today: today)
                        Text(LS("%@还款", monthDay(c.due))).lineLimit(1)
                        if status == .overdue || status == .minimumPaid {
                            let look = CardStatusLook(c, today: today)
                            Text(look.text)
                                .font(.caption2.weight(.semibold)).foregroundStyle(look.color)
                                .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.detail)
                                .background(look.color.soft, in: RoundedRectangle(cornerRadius: AppRadius.mini))
                        } else if days >= 0 && days <= 7 {
                            Text(days == 0 ? LS("今天") : LS("%@天后", days))
                                .font(.caption2.weight(.semibold)).foregroundStyle(Color.warn)
                                .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.detail)
                                .background(Color.warn.soft, in: RoundedRectangle(cornerRadius: AppRadius.mini))
                        }
                    } else {
                        Text(subtitle(leafName)).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: AppSpacing.detail) {
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
        .padding(.vertical, AppSpacing.detail)
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
    @Environment(Store.self) var store
    let account: String
    @State private var checking: CheckPreset?
    /// months opened or closed by hand (the rest follow `open`)
    @State private var opened: [String: Bool] = [:]
    /// same search language as 明细, kept per account with the opened months
    @State private var query = ""
    @State private var reimb: ReimbTarget?
    @State private var noting: NoteEdit?
    @State private var viewing: DocItem?
    @State private var addingDocument = false

    enum Item { case txn(Entry, String), balance(BalanceResult), document(Entry), note(Entry) }

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { PageLoading() }
        }

        .ledgerControls("register." + account, value: Binding(get: {
            var context = BrowseContext(); context.opened = opened; context.query = query; return context
        }, set: { opened = $0.opened; query = $0.query }))
        .navigationTitle(acctLabel(account).isEmpty ? account : acctLabel(account))
        .navigationBarTitleDisplayMode(.inline)
        .appSearchable(text: $query, prompt: LS("收付款方、摘要、金额、日期"))
        .sheet(item: $checking) { p in CheckSheet(account: account, preset: p) }
        .sheet(item: $noting) { NoteSheet(account: account, note: $0.note) }
        .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
        .sheet(isPresented: $addingDocument) { AccountDocumentSheet(account: account) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addingDocument = true } label: { Label(LS("添加票据 / 对账单"), systemImage: "doc.badge.plus") }
                    Button { noting = NoteEdit(note: nil) } label: { Label(LS("添加备注"), systemImage: "text.bubble") }
                    if let L = store.L, cardCycles(L).contains(where: { $0.account == account }) {
                        Button { store.showInJournal(.account(account)) } label: { Label(LS("查看明细"), systemImage: "list.bullet") }
                        if canCheck(L) { Button { checking = CheckPreset() } label: { Label(LS("余额核对"), systemImage: "checkmark.seal") } }
                        Divider()
                        Toggle(isOn: Binding(get: { !isExcluded(account, store.netWorthExclude) },
                                             set: { on in Task { await store.setExcluded(account, netWorth: !on) } })) { Text(LS("计入净资产")) }
                        Toggle(isOn: Binding(get: { !isExcluded(account, store.balanceExclude) },
                                             set: { on in Task { await store.setExcluded(account, balance: !on) } })) { Text(LS("显示在资产负债表")) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(LS("更多"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AccountEditDest(name: account)) { Image(systemName: "pencil.circle") }
                    .accessibilityLabel(LS("编辑账户"))
            }
        }
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .task {
            if store.demoEnv["LEDGER_CHECK"] != nil { checking = CheckPreset(actual: store.demoEnv["LEDGER_CHECK"]) }
            if store.demoEnv["LEDGER_ADD_DOCUMENT"] != nil { addingDocument = true }
        }
    }

    private func canCheck(_ L: Ledger) -> Bool {
        (account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:")) && L.accounts[account]?.close == nil
    }

    private func page(_ L: Ledger) -> some View {
        let built = build(L)
        let (months, c) = monthGroups(kept(built.0, L), L)
        let check = canCheck(L)
        let first = months.first?.ym
        let card = cardCycles(L).first(where: { $0.account == account })
        return List {
            if let c = card {
                // a card: its bill first; the account's settings are in ⋯
                CardHeroSection(cycle: c)
                CardLimitSection(cycle: c)
            } else {
                header(L, built.1)
                if account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:") { countsSection() }
            }
            if months.isEmpty {
                Section {
                    switch browseEmpty(count: 0, filtered: !query.trimmed.isEmpty) {
                    case .nothingMatches:
                        Text(LS("没有符合筛选的记录")).foregroundStyle(.secondary)
                    default:
                        Text(LS("暂无记录")).foregroundStyle(.secondary)
                    }
                }
            }
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

    /// A search uses the same words as 明细. Balance rows, notes and documents stay when they match too.
    private func kept(_ items: [Item], _ L: Ledger) -> [Item] {
        let text = query.trimmed
        guard !text.isEmpty else { return items }
        let q = TxQuery(text)
        return items.filter { q.matches(entry(of: $0), L) }
    }

    private func entry(of item: Item) -> Entry {
        switch item {
        case .txn(let t, _): return t
        case .balance(let r): return r.entry
        case .document(let e), .note(let e): return e
        }
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
            withAnimation(AppMotion.standard) { opened[m.ym] = !on }
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.icon) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(Day.monthLabel(m.ym)).font(.headline)
                    Text(LS("%@ 笔", m.count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: AppSpacing.detail) {
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
                        if query.trimmed.isEmpty, !m.closing.isEmpty {
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

    private func accountActions(check: Bool) -> [ActionRow.Item] {
        var items = [ActionRow.Item(title: LS("查看明细"), systemImage: "list.bullet", emphasis: .primary) {
            store.showInJournal(.account(account))
        }]
        if account == store.receivable, !(store.D?.unclaimed.isEmpty ?? true) {
            items.append(ActionRow.Item(title: LS("登记报销回款"), systemImage: "arrow.down.left") {
                reimb = ReimbTarget(link: nil)
            })
        }
        if check {
            items.append(ActionRow.Item(title: LS("余额核对"), systemImage: "checkmark.seal") {
                checking = CheckPreset()
            })
        }
        return items
    }

    private func header(_ L: Ledger, _ bal: [(String, Double)]) -> some View {
        let isIE = account.hasPrefix("Income") || account.hasPrefix("Expenses")
        let bs = bal.filter { abs($0.1) > 0.0049 }
        let closedNote = L.accounts[account]?.close.map { LS(" · 已于 %@ 关闭", $0) } ?? ""
        let check = canCheck(L)
        let k = store.groupIcon(account)
        let isIEIcon = account.hasPrefix("Income") ? ("arrow.down.circle.fill", Color.gain) : ("arrow.up.circle.fill", Color.gray)
        return Section {
            Card {
                VStack(alignment: .leading, spacing: AppSpacing.icon) {
                    HStack(spacing: AppSpacing.icon) {
                        IconBadge(symbol: isIE ? isIEIcon.0 : k.symbol, color: isIE ? isIEIcon.1 : k.color, size: 34)
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(store.displayName(account).map { acctLabel(account) + " · " + $0 } ?? acctDisplay(account)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(account + closedNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(isIE ? LS("累计发生额") : LS("当前余额")).font(.caption).foregroundStyle(.secondary)
                        if bs.isEmpty { Text(masked("0.00")).font(.system(.largeTitle, design: .rounded).weight(.bold)).sensitive() }
                        ForEach(bs, id: \.0) { b in
                            Text(money(isIE ? -b.1 : b.1, b.0)).font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(2).minimumScaleFactor(0.7).sensitive()
                        }
                    }
                    ActionRow(size: .small, items: accountActions(check: check))
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
                .entryActions(t)
        case .balance(let r):
            let own = r.entry.account == account && check
            BalanceRow(r: r) {
                if own { checking = CheckPreset(date: r.entry.date, currency: r.entry.currency, actual: jsNumberString(r.entry.number), original: r.entry) }
            }
            .entryActions(r.entry, edit: own ? {
                checking = CheckPreset(date: r.entry.date, currency: r.entry.currency, actual: jsNumberString(r.entry.number), original: r.entry)
            } : nil)
        case .note(let n):
            Button { noting = NoteEdit(note: n) } label: { NoteRow(note: n, account: account) }
                .buttonStyle(.plain)
                .entryActions(n, edit: { noting = NoteEdit(note: n) })
        case .document(let d):
            Button {
                if let path = documentRepoPath(d) { viewing = DocItem(path: path) }
            } label: {
                HStack(spacing: AppSpacing.icon) {
                    Image(systemName: "doc.text").foregroundStyle(Color.jadeInk)
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(d.date + LS(" 对账单"))
                        Text(((d.path ?? "") as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .entryActions(d)
        }
    }

    private func build(_ L: Ledger) -> ([Item], [(String, Double)]) {
        var items: [Item] = []
        var bal: [String: Double] = [:]
        var order: [String] = []
        let pre = account + ":"
        // a transaction's attachments are listed under 交易附件, not with this account's statements
        let attached = Set(transactionAttachments(L).map { ObjectIdentifier($0) })
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
                if e.account == account && !attached.contains(ObjectIdentifier(e)) { items.append(.document(e)) }
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
            HStack(spacing: AppSpacing.control) {
                Text(r.entry.date + LS(" 余额断言")).font(.subheadline)
                Text(money(r.entry.number, c)).font(.subheadline.monospacedDigit()).sensitive()
                Spacer()
                if r.ok {
                    Label(LS("相符"), systemImage: "checkmark").labelStyle(ControlLabelStyle()).font(.caption).foregroundStyle(Color.gain)
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
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let account: String
    let preset: CheckPreset
    @State private var date = Day.shift(Day.today(), 1)
    @State private var currency = "CNY"
    @State private var actual = ""
    @State private var busy = false
    @State private var armed = false
    @State private var closeRequested = false
    @State private var baseline: [String]?
    @State private var deletion: EntryDeletion?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { PageLoading() }
            }
            .disabled(busy)
            .protectUnsavedChanges(dirty: baseline.map { $0 != [date, currency, actual] } ?? false,
                busy: busy, requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .entryDeletion($deletion)
            .keyboardDone()
            .navigationTitle(preset.original != nil ? LS("编辑余额断言") : LS("余额核对"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
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
                        deletion = EntryDeletion(o, ledgerID: store.cfg.id, onDeleted: { dismiss() })
                    } label: {
                        HStack(spacing: AppSpacing.icon) { Spacer(minLength: 0); Image(systemName: "trash"); Text(LS("删除此断言")); Spacer(minLength: 0) }
                    }
                } footer: {
                    Text(LS("修改日期、币种或金额后保存，原断言（%@ %@）将被替换，不会产生重复记录。", o.date, money(o.number, o.currency ?? "CNY")))
                }
            }
        }
        .onAppear {
            guard baseline == nil else { return }
            if let d = preset.date { date = d }
            currency = preset.currency ?? ccys.first ?? "CNY"
            if let x = preset.actual { actual = x }
            baseline = [date, currency, actual]
            focused = preset.actual == nil
        }
    }

    private func inputSection(_ ccys: [String]) -> some View {
        Section {
            HStack(spacing: AppSpacing.control) {
                Button {
                    let t = actual.trimmed
                    actual = t.hasPrefix("-") ? String(t.dropFirst()) : "-" + t
                    armed = false
                } label: {
                    Text("±").font(.title3).frame(width: 38, height: 34).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.tile))
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
            DateField(value: $date, title: LS("断言日期"), days: [1, 0])
                .onChange(of: date) { _, _ in armed = false }
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
                .foregroundStyle(Color.warn)
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
                Label(title, systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .primaryButton(tint: old != nil ? Color.warn : Color.jade)
            .disabled(a == nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func save(_ L: Ledger, _ old0: BalanceResult?, _ a: Double?) {
        guard !busy else { return }
        guard let a = a else { store.showFailure(LS("请填写实际余额")); return }
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
        busy = true
        Task {
            defer { busy = false }
            await store.commit([op], word: word, closing: { dismiss() })
        }
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
        busy = true
        Task {
            defer { busy = false }
            if sameLine {
                await store.commit([op], word: LS("已更新余额断言"), closing: { dismiss() })
                return
            }
            guard var rm = await store.balanceRemoveOp(orig) else { store.showFailure(LS("未在 %@ 中找到原断言", orig.file)); return }
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
