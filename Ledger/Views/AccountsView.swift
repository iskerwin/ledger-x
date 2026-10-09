import SwiftUI
import LedgerKit

struct AccountsView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @AppStorage("ledger.showClosed") private var showClosed = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L { list(L) } else { ProgressView() }
            }
            .navigationTitle(LS("账户"))
            .toolbar {
                StandardToolbar()
                ToolbarItemGroup(placement: .topBarLeading) {
                    NavigationLink(value: AccountManagerDest()) { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(LS("管理账户"))
                    Toggle(isOn: $showClosed) { Image(systemName: "archivebox") }.toggleStyle(.button)
                        .accessibilityLabel(LS("显示已关闭和为零的账户"))
                }
            }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name) }
            .navigationDestination(for: HoldingsDest.self) { _ in HoldingsView() }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0) }
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: AccountManagerDest.self) { _ in AccountManagerView() }
            .navigationDestination(for: AccountEditDest.self) { AccountEditView(name: $0.name) }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            if store.demoEnv["LEDGER_MANAGE"] != nil, path.isEmpty { path.append(AccountManagerDest()) }
            if let a = store.demoEnv["LEDGER_EDIT_ACCOUNT"], path.isEmpty { path.append(AccountEditDest(name: a)) }
            if let a = store.demoEnv["LEDGER_OPEN_ACCOUNT"], path.isEmpty { path.append(AccountDest(name: a)) }
            if store.demoEnv["LEDGER_OPEN_HOLDINGS"] != nil, path.isEmpty { path.append(HoldingsDest()) }
        }
    }

    typealias Row = (String, [(String, Double)], Bool)

    private func rows(_ L: Ledger, _ g: String, _ today: String) -> [Row] {
        var out: [Row] = []
        for a in L.accounts.keys.filter({ $0.hasPrefix(g + ":") }).sorted() {
            let cs = (L.final[a] ?? [:]).filter { abs($0.value) > 0.0049 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            let closed = (L.accounts[a]?.close).map { $0 <= today } ?? false
            if !showClosed && (closed || cs.isEmpty) { continue }
            out.append((a, cs, closed))
        }
        return out
    }

    private func cnyTotal(_ L: Ledger, _ rs: [Row]) -> Double {
        var t = 0.0
        for r in rs { for (c, n) in r.1 { t += toCNY(L, n, c) ?? 0 } }
        return t
    }

    /// accounts under a root, grouped by their second level ("Bank", "CreditCard", …)
    private func groups(_ L: Ledger, _ root: String, _ today: String) -> [(String, [Row])] {
        var by: [String: [Row]] = [:]
        for r in rows(L, root, today) {
            let p = r.0.components(separatedBy: ":")
            by[p.count > 1 ? p[1] : root, default: []].append(r)
        }
        return by.sorted { a, b in
            let ia = AccountKind.order.firstIndex(of: a.key) ?? 99, ib = AccountKind.order.firstIndex(of: b.key) ?? 99
            return ia != ib ? ia < ib : a.key < b.key
        }
    }

    private func groupSection(_ L: Ledger, _ root: String, _ g: String, _ rs: [Row]) -> some View {
        let kind = AccountKind(g)
        let failing = Set(L.balanceResults.filter { !$0.ok }.compactMap { $0.entry.account })
        return Section {
            ForEach(rs, id: \.0) { row in
                NavigationLink(value: AccountDest(name: row.0)) {
                    AccountRow(account: row.0, balances: row.1, closed: row.2, failing: failing.contains(row.0), kind: kind)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(groupName(g))
                if AppLanguage.current != .en { Text(g).foregroundStyle(.tertiary).textCase(nil) }
                Spacer()
                Text(money(cnyTotal(L, rs))).monospacedDigit().sensitive().textCase(nil)
            }
        }
    }

    private func heroSection(_ L: Ledger, assets: Double, liab: Double) -> some View {
        Section {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LS("净资产")).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(assets + liab)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                    }
                    HStack(alignment: .top) {
                        Figure(label: LS("资产"), value: money(assets))
                        Spacer()
                        Figure(label: LS("负债"), value: money(-liab), color: liab < -0.005 ? Color.loss : Color.primary)
                        Spacer()
                        Figure(label: LS("资产负债率"), value: assets > 0 && liab < -0.005 ? String(format: "%.1f%%", -liab / assets * 100) : "—", alignment: .trailing)
                    }
                    RatioBar(parts: [(max(0, assets + liab), Color.jade), (-liab, Color.loss)])
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

    @ViewBuilder
    private func holdingsSection(_ L: Ledger) -> some View {
        let hs = holdings(L)
        if !hs.isEmpty {
            let value = hs.reduce(0.0) { $0 + (toCNY(L, $1.value ?? $1.cost, $1.q) ?? 0) }
            let cost = hs.reduce(0.0) { $0 + (toCNY(L, $1.cost, $1.q) ?? 0) }
            let names = NSOrderedSet(array: hs.map { $0.c }).array.compactMap { $0 as? String }.joined(separator: LS("、"))
            Section {
                NavigationLink(value: HoldingsDest()) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "chart.line.uptrend.xyaxis", color: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LS("投资持仓"))
                            Text(names).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Amount(n: value, c: L.base)
                            Text(signedMoney(value - cost, L.base) + (cost > 0 ? String(format: LS("（%@%.1f%%）"), value >= cost ? "+" : "", (value - cost) / cost * 100) : ""))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(value >= cost ? Color.gain : Color.loss).sensitive()
                        }
                    }
                }
            }
        }
    }

    private func list(_ L: Ledger) -> some View {
        let today = Day.today()
        let ag = groups(L, "Assets", today)
        let lg = groups(L, "Liabilities", today)
        let assets = ag.reduce(0.0) { $0 + cnyTotal(L, $1.1) }
        let liab = lg.reduce(0.0) { $0 + cnyTotal(L, $1.1) }
        return List {
            heroSection(L, assets: assets, liab: liab)
            holdingsSection(L)
            ForEach(ag, id: \.0) { g in groupSection(L, "Assets", g.0, g.1) }
            ForEach(lg, id: \.0) { g in groupSection(L, "Liabilities", g.0, g.1) }
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

    var body: some View {
        let p = account.components(separatedBy: ":")
        let name = p.count > 2 ? p[2...].joined(separator: ":") : (p.count > 1 ? p[1] : account)
        let k = kind ?? AccountKind.of(account)
        HStack(spacing: 12) {
            IconBadge(symbol: k.symbol, color: closed ? .gray : k.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).foregroundStyle(closed ? Color.secondary : Color.primary).lineLimit(1)
                    if failing { Tag(text: LS("断言不符"), warn: true) }
                    if closed { Tag(text: LS("已关闭")) }
                }
                Text(balances.count > 1 ? balances.map { $0.0 }.joined(separator: " · ") : (store.displayName(account) ?? account))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if balances.isEmpty { Text("0.00").foregroundStyle(.secondary).monospacedDigit() }
                ForEach(balances, id: \.0) { b in
                    Amount(n: b.1, c: b.0, d: abs(b.1) < 1 && b.0.count > 3 ? 4 : 2)
                        .font(balances.count > 1 ? .subheadline : .body)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - register

struct RegisterView: View {
    @EnvironmentObject var store: Store
    let account: String
    @State private var checking: CheckPreset?
    @State private var reimb: ReimbTarget?
    @State private var deleting: Entry?

    enum Item { case txn(Entry, String), balance(BalanceResult), document(Entry) }

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { ProgressView() }
        }
        .navigationTitle(acctLabel(account).isEmpty ? account : acctLabel(account))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $checking) { p in CheckSheet(account: account, preset: p) }
        .toolbar {
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
        let items = Array(built.0.suffix(300).reversed())
        let total = built.0.count
        return List {
            header(L, built.1)
            if let c = cardCycles(L).first(where: { $0.account == account }) { CardBillSection(cycle: c) }
            Section(total > 300 ? LS("最近 300 条") : LS("共 %@ 条", total)) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    itemRow(pair.element, canCheck(L))
                }
                if items.isEmpty { Text(LS("暂无记录")).foregroundStyle(.secondary) }
            }
        }
    }

    private func header(_ L: Ledger, _ bal: [(String, Double)]) -> some View {
        let isIE = account.hasPrefix("Income") || account.hasPrefix("Expenses")
        let bs = bal.filter { abs($0.1) > 0.0049 }
        let closedNote = L.accounts[account]?.close.map { LS(" · 已于 %@ 关闭", $0) } ?? ""
        let check = canCheck(L)
        let k = AccountKind.of(account)
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
        case .document(let d):
            HStack {
                Image(systemName: "doc.text")
                Text(d.date + LS(" 对账单"))
                Spacer()
                if let p = d.path, let u = docURL(p) {
                    Link((p as NSString).lastPathComponent, destination: u).font(.caption)
                } else {
                    Text(((d.path ?? "") as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private func docURL(_ p: String) -> URL? {
        guard let r = p.range(of: "/documents/") else { return nil }
        return store.githubURL(String(p[p.index(after: r.lowerBound)...]))
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
                        Label(LS("删除此断言"), systemImage: "trash").frame(maxWidth: .infinity)
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
        op.amountText = money(a, currency)
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
        op.amountText = money(a, currency)
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
