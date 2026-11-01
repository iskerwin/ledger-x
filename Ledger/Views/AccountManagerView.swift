import SwiftUI
import LedgerKit

struct AccountManagerDest: Hashable {}
/// nil name = a new account
struct AccountEditDest: Hashable { var name: String? }

extension Store {
    /// the `name:` metadata on the account's open directive, if any
    func displayName(_ a: String) -> String? {
        guard let m = L?.accounts[a]?.meta["name"], case .string(let s) = m, !s.isEmpty else { return nil }
        return s
    }
}

/// 管理账户: every account in the ledger, by root, then by group (Food, Bank…) folded away until opened
struct AccountManagerView: View {
    @Environment(Store.self) var store
    /// just one root ("Expenses" or "Income" as 科目管理 from the 记一笔 grid)
    var only: String? = nil
    @State private var q = ""
    @AppStorage("ledger.manager.closed") private var showClosed = true
    /// groups opened ("Expenses:Food"); while searching every group is open
    @State private var openGroups: Set<String> = []
    @State private var iconFor: IconTarget?

    static let roots = ["Assets", "Liabilities", "Income", "Expenses", "Equity"]

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { PageLoading() }
        }
        .navigationTitle(only == nil ? LS("管理账户") : LS("科目管理"))
        .task { if let g = store.demoEnv["LEDGER_MANAGE_OPEN"] { openGroups.insert(g) } }
        .sheet(item: $iconFor) { GroupIconSheet(group: $0.group).pickerSheet() }
        .navigationBarTitleDisplayMode(.inline)
        .appSearchable(text: $q, prompt: LS("搜索账户"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AccountEditDest(name: nil)) { Image(systemName: "plus") }
                    .accessibilityLabel(LS("新建账户"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showClosed.toggle() } label: { Image(systemName: showClosed ? "archivebox.fill" : "archivebox") }
                    .accessibilityLabel(LS("显示已关闭的账户"))
            }
        }
    }

    private func list(_ L: Ledger) -> some View {
        let today = Day.today()
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        let all = L.accounts.values.filter { !$0.implicit || L.final[$0.name] != nil }
            .filter { showClosed || ($0.close.map { $0 > today } ?? true) }
            .filter { t.isEmpty || $0.name.lowercased().contains(t) || (store.displayName($0.name)?.lowercased().contains(t) ?? false) }
        return List {
            if t.isEmpty && only == nil {
                Section {
                    NavigationLink(value: NetWorthSettingsDest()) {
                        LabeledContent(LS("净资产与资产负债表"), value: Set(store.netWorthExclude + store.balanceExclude).isEmpty
                                       ? LS("全部计入") : LS("已排除 %@ 个", Set(store.netWorthExclude + store.balanceExclude).count))
                    }
                }
            }
            ForEach(only.map { [$0] } ?? Self.roots, id: \.self) { root in
                let rows = all.filter { $0.name == root || $0.name.hasPrefix(root + ":") }.sorted { $0.name < $1.name }
                if !rows.isEmpty {
                    Section {
                        ForEach(groups(rows), id: \.0) { g in
                            // a group of its own account alone (Expenses:Travel) is just that row
                            if g.1.count == 1 && g.1[0].name == g.0 {
                                NavigationLink(value: AccountEditDest(name: g.1[0].name)) { row(g.1[0], today, icon: groupIcon(g.0)) }
                                    .contextMenu { Button { iconFor = IconTarget(group: g.0) } label: { Label(LS("更换图标"), systemImage: "photo") } }
                            } else {
                                groupRow(g.0, g.1.count, open: !t.isEmpty || openGroups.contains(g.0))
                                if !t.isEmpty || openGroups.contains(g.0) {
                                    ForEach(g.1, id: \.name) { a in
                                        NavigationLink(value: AccountEditDest(name: a.name)) { row(a, today, icon: nil) }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(groupName(root) + " · \(rows.count)")
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    /// accounts by their second level ("Expenses:Food"), in name order
    private func groups(_ rows: [Account]) -> [(String, [Account])] {
        var by: [String: [Account]] = [:], order: [String] = []
        for a in rows {
            let g = catOf(a.name)
            if by[g] == nil { order.append(g) }
            by[g, default: []].append(a)
        }
        return order.map { ($0, by[$0]!) }
    }

    /// a group's icon: the account kind's (Bank, CreditCard…) for assets and liabilities, the 记一笔 grid's for categories
    private func groupIcon(_ g: String) -> (String, Color) {
        let k = store.groupIcon(g)
        return (k.symbol, k.color)
    }

    /// a group's header row: the group's icon and name, how many, and a chevron; tap to open or fold it
    private func groupRow(_ g: String, _ n: Int, open: Bool) -> some View {
        let icon = groupIcon(g)
        return Button {
            withAnimation(AppMotion.standard) { if open { openGroups.remove(g) } else { openGroups.insert(g) } }
        } label: {
            HStack(spacing: AppSpacing.icon) {
                IconBadge(symbol: icon.0, color: icon.1, size: 28)
                Text(leaf(g)).foregroundStyle(.primary)
                if let z = acctZH(g) { Text(z).foregroundStyle(.secondary) }
                Spacer()
                Text(LS("%@ 个", n)).font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!q.trimmingCharacters(in: .whitespaces).isEmpty)
        .contextMenu {
            Button { iconFor = IconTarget(group: g) } label: { Label(LS("更换图标"), systemImage: "photo") }
        }
    }

    /// an account; inside an open group it has no icon of its own and lines up under the group's name
    private func row(_ a: Account, _ today: String, icon: (String, Color)?) -> some View {
        let closed = a.close.map { $0 <= today } ?? false
        return HStack(spacing: AppSpacing.control) {
            if let i = icon {
                IconBadge(symbol: i.0, color: closed ? .gray : i.1, size: 28)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                HStack(spacing: AppSpacing.icon) {
                    // under its group only the rest of the name ("Dining" in Food)
                    Text(icon == nil && a.name.count > catOf(a.name).count ? String(a.name.dropFirst(catOf(a.name).count + 1)) : acctLabel(a.name))
                        .foregroundStyle(closed ? Color.secondary : Color.primary).lineLimit(1)
                    if closed { Tag(text: LS("已关闭")) }
                    if a.implicit { Tag(text: LS("未开户"), warn: true) }
                }
                Text([store.displayName(a.name), a.open.map { LS("开立于 %@", $0) }, a.currencies.isEmpty ? nil : a.currencies.joined(separator: ",")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// new account, or edit / close / reopen / rename / merge an existing one
struct AccountEditView: View {
    /// return moves on: account name → display name → currencies
    private enum Field { case account, display, currencies }
    @FocusState private var field: Field?
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let name: String?

    @State private var account = ""
    @State private var root = "Expenses"
    @State private var openDate = Day.today()
    @State private var currencies = ""
    @State private var booking = ""
    @State private var display = ""
    @State private var creditLimitText = ""
    @State private var statementDay = 0
    @State private var dueDay = 0
    @State private var allowNegative = false
    @State private var closeDate = Day.today()
    @State private var newName = ""
    @State private var impact: (files: Int, places: Int)?
    @State private var confirmClose = false
    @State private var confirmRename = false
    @State private var loaded = false
    @State private var initialFields = ""

    private var fields: String { [openDate, currencies, booking, display, creditLimitText, allowNegative ? "1" : "", "\(statementDay)", "\(dueDay)"].joined(separator: "|") }
    private var acctName: String { isNew ? account.trimmed : (name ?? "") }

    private static let bookings = ["", "STRICT", "FIFO", "LIFO", "HIFO", "AVERAGE", "NONE"]

    private var isNew: Bool { name == nil }
    private func openEntry(_ L: Ledger) -> Entry? { name.flatMap { n in L.entries.last { $0.type == .open && $0.account == n } } }
    private func closeEntry(_ L: Ledger) -> Entry? { name.flatMap { n in L.entries.last { $0.type == .close && $0.account == n } } }

    var body: some View {
        Group {
            if let L = store.L { form(L) } else { PageLoading() }
        }
        .keyboardDone()
        .navigationTitle(isNew ? LS("新建账户") : acctLabel(name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        guard !loaded, let L = store.L else { return }
        loaded = true
        if let n = name {
            account = n
            newName = n
            let a = L.accounts[n]
            openDate = a?.open ?? (L.txns.first { $0.postings.contains { $0.account == n } }?.date ?? Day.today())
            currencies = a?.currencies.joined(separator: ",") ?? ""
            booking = a?.booking?.uppercased() ?? ""
            display = store.displayName(n) ?? ""
            if let v = a?.meta[creditLimitKey] { creditLimitText = v.stringValue ?? v.display }
            statementDay = a?.meta[statementDayKey].flatMap { Int(($0.stringValue ?? $0.display)) } ?? 0
            dueDay = a?.meta[dueDayKey].flatMap { Int(($0.stringValue ?? $0.display)) } ?? 0
            if let v = a?.meta[allowNegativeKey] { allowNegative = ["true", "yes", "1"].contains((v.stringValue ?? v.display).lowercased()) }
            initialFields = fields
        } else {
            account = root + ":"
            currencies = L.base
        }
    }

    // MARK: form

    private func form(_ L: Ledger) -> some View {
        Form {
            basics(L)
            if !isNew, let n = name {
                closeSection(L, n)
                renameSection(L, n)
            }
        }
        .confirmationDialog(LS("关闭账户 %@？", name ?? ""), isPresented: $confirmClose, titleVisibility: .visible) {
            Button(role: .destructive) { close(L) } label: { Text(LS("关闭账户")) }
        } message: {
            Text(LS("将写入一条 close 指令，此后该账户不能再有交易。"))
        }
        .confirmationDialog(renameTitle(L), isPresented: $confirmRename, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await rename(L) } } label: { Text(LS("确认")) }
        } message: {
            Text(LS("账本中所有出现该账户（及其子账户）的地方都会被替换，作为一次修改提交。"))
        }
    }

    private func basics(_ L: Ledger) -> some View {
        let valid = isAccountName(account.trimmed) && Self.roots.contains(where: { account.trimmed.hasPrefix($0 + ":") })
        let exists = isNew && L.accounts[account.trimmed].map { !$0.implicit } == true
        return Section {
            if isNew {
                Picker(LS("类型"), selection: $root) {
                    ForEach(AccountManagerView.roots, id: \.self) { Text(groupName($0)).tag($0) }
                }
                .onChange(of: root) { _, r in
                    let rest = account.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    account = r + ":" + rest
                }
                TextField("Expenses:Food:Coffee", text: $account)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .focused($field, equals: .account).submitLabel(.next).onSubmit { field = .display }
                if !account.trimmed.isEmpty && !valid {
                    Label(LS("账户名需以五大类开头，各级以冒号分隔，每级首字母大写，如 Assets:Bank:CMB"), systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(Color.warn)
                } else if exists {
                    ValidationRow(message: LS("该账户已存在"), warning: true)
                }
                parentChips(L)
            } else {
                LabeledContent(LS("账户"), value: name ?? "").font(.body.monospaced())
            }
            DatePicker(LS("开立日期"), selection: dateBinding($openDate), displayedComponents: .date)
            LabeledContent(LS("显示名称")) {
                TextField(LS("可选，如「招商银行储蓄卡」"), text: $display).multilineTextAlignment(.trailing)
                    .focused($field, equals: .display).submitLabel(.next).onSubmit { field = .currencies }
            }
            LabeledContent(LS("限定币种")) {
                TextField(LS("可选，如 CNY,USD"), text: $currencies)
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .focused($field, equals: .currencies).submitLabel(.done)
            }
            Picker(LS("批次方法"), selection: $booking) {
                ForEach(Self.bookings, id: \.self) { b in Text(b.isEmpty ? LS("默认") : b).tag(b) }
            }
            if acctName.hasPrefix("Liabilities:") {
                LabeledContent(LS("信用额度")) {
                    TextField(LS("可选，超出时提交前提醒"), text: $creditLimitText)
                        .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                }
                Picker(LS("账单日"), selection: $statementDay) {
                    Text(LS("未设置")).tag(0)
                    ForEach(1...31, id: \.self) { Text(LS("每月 %@ 日", $0)).tag($0) }
                }
                Picker(LS("还款日"), selection: $dueDay) {
                    Text(LS("未设置")).tag(0)
                    ForEach(1...31, id: \.self) { Text(LS("每月 %@ 日", $0)).tag($0) }
                }
            }
            if acctName.hasPrefix("Assets:") {
                // the same statement_day: on this day the balance is checked against the bank
                Picker(LS("核对日"), selection: $statementDay) {
                    Text(LS("不核对")).tag(0)
                    ForEach(1...31, id: \.self) { Text(LS("每月 %@ 日", $0)).tag($0) }
                }
                Toggle(LS("允许负余额"), isOn: $allowNegative)
            }
            MonoText(text: openText(L))
            Button {
                saveOpen(L)
            } label: {
                Label(isNew ? LS("开立账户") : LS("保存修改"), systemImage: "checkmark").labelStyle(ControlLabelStyle()).frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .primaryButton()
            .disabled(isNew ? (!valid || exists) : fields == initialFields)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text(isNew ? LS("新账户") : LS("开户信息"))
        } footer: {
            Text((isNew ? LS("写入开户指令最多的文件。显示名称保存为 name 元数据，App 会显示在账户名旁边。") : LS("修改会直接替换原来的 open 指令，保留其他元数据。"))
                 + " " + LS("设置了账单日或核对日的账户，每月这一天提醒对照银行核对余额，一致后写入当天的余额断言；不设置则不核对。股票、基金等按份额记账的账户不适合设置。"))
        }
    }

    /// quick picks: existing parents under the chosen root
    private func parentChips(_ L: Ledger) -> some View {
        var parents = Set<String>()
        for a in L.accounts.keys where a.hasPrefix(root + ":") {
            let p = a.components(separatedBy: ":")
            if p.count > 2 { parents.insert(p.prefix(2).joined(separator: ":")) }
        }
        let list = parents.sorted()
        return Group {
            if !list.isEmpty {
                ChipRow {
                    ForEach(list, id: \.self) { p in
                        Chip(label: acctLabel(p), selected: account.hasPrefix(p + ":")) { account = p + ":" }
                    }
                }
            }
        }
    }

    // MARK: open directive

    private func openText(_ L: Ledger) -> String {
        let n = isNew ? account.trimmed : (name ?? "")
        let ccy = currencies.uppercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        let limit = creditLimitText.replacingOccurrences(of: ",", with: "").trimmed
        return openDirectiveText(date: openDate, account: n, currencies: ccy, booking: booking, name: display.trimmed,
                                 creditLimit: Double(limit), allowNegative: allowNegative, statementDay: statementDay,
                                 dueDay: dueDay, keep: openEntry(L)?.src)
    }

    private func saveOpen(_ L: Ledger) {
        let text = openText(L)
        if let e = openEntry(L) {
            var op = entryOp(e, text: text)
            op.date = openDate
            op.label = LS("修改账户：%@", name ?? "")
            op.summary = op.label
            Task { await store.commit([op], word: LS("已修改账户"), closing: { dismiss() }) }
        } else {
            guard let ops = store.makeOps(text, single: false) else { return }
            Task { await store.commit(ops, word: LS("已开立账户"), closing: { dismiss() }) }
        }
    }

    // MARK: close / reopen

    private func balances(_ L: Ledger, _ n: String) -> [(String, Double)] {
        var out: [String: Double] = [:]
        for (a, cs) in L.final where a == n || a.hasPrefix(n + ":") { for (c, v) in cs { out[c, default: 0] += v } }
        return out.filter { abs($0.value) > 0.005 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    @ViewBuilder
    private func closeSection(_ L: Ledger, _ n: String) -> some View {
        if let ce = closeEntry(L) {
            Section {
                LabeledContent(LS("关闭日期"), value: ce.date)
                Button {
                    var op = entryOp(ce, text: nil)
                    op.label = LS("重新开启账户：%@", n)
                    op.summary = op.label
                    Task { await store.commit([op], word: LS("已重新开启"), closing: { dismiss() }) }
                } label: { Label(LS("重新开启账户"), systemImage: "lock.open").labelStyle(ControlLabelStyle()) }
            } header: {
                Text(LS("已关闭"))
            } footer: {
                Text(LS("重新开启会删除这条 close 指令。"))
            }
        } else {
            let bal = balances(L, n)
            Section {
                DatePicker(LS("关闭日期"), selection: dateBinding($closeDate), displayedComponents: .date)
                if !bal.isEmpty {
                    Label(LS("当前余额 %@，建议先转出或通过余额核对确认为零", bal.map { money($0.1, $0.0) }.joined(separator: LS("、"))), systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(Color.warn).sensitive()
                }
                Button(role: .destructive) { confirmClose = true } label: { Label(LS("关闭账户"), systemImage: "lock").labelStyle(ControlLabelStyle()) }
            } header: {
                Text(LS("关闭账户"))
            } footer: {
                Text(LS("关闭后历史记录保留；账户默认不在账户页显示。"))
            }
        }
    }

    private func close(_ L: Ledger) {
        guard let n = name, let ops = store.makeOps("\(closeDate) close \(n)", single: false) else { return }
        Task {
            // a closed card's details are not kept: its number, expiry and code go from this phone too
            if await store.commit(ops, word: LS("已关闭账户"), closing: { dismiss() }) { store.setCardInfo(CardInfo(), for: n) }
        }
    }

    // MARK: rename / merge

    private func renameTitle(_ L: Ledger) -> String {
        let to = newName.trimmed
        return L.accounts[to].map { !$0.implicit } == true ? LS("把 %@ 合并到 %@？", name ?? "", to) : LS("把 %@ 重命名为 %@？", name ?? "", to)
    }

    @ViewBuilder
    private func renameSection(_ L: Ledger, _ n: String) -> some View {
        let to = newName.trimmed
        let valid = isAccountName(to) && to != n && AccountManagerView.roots.contains(where: { to.hasPrefix($0 + ":") }) && !to.hasPrefix(n + ":")
        let merge = valid && L.accounts[to].map { !$0.implicit } == true
        Section {
            TextField(n, text: $newName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced())
            .task(id: to) {
                impact = nil
                guard valid else { return }
                impact = await count(n)
            }
            if let i = impact, valid {
                Text(LS("将修改 %@ 个文件中的 %@ 处", i.files, i.places)).font(.footnote).foregroundStyle(.secondary)
            }
            if merge {
                Label(LS("%@ 已存在：将把本账户的全部记录并入该账户，并移除本账户的开户 / 关户指令。原有余额断言会一并转移，可能需要重新核对。", to), systemImage: "arrow.triangle.merge").labelStyle(ControlLabelStyle())
                    .font(.footnote).foregroundStyle(Color.warn)
            }
            Button { confirmRename = true } label: { Label(merge ? LS("合并账户") : LS("重命名账户"), systemImage: merge ? "arrow.triangle.merge" : "pencil").labelStyle(ControlLabelStyle()) }
                .disabled(!valid)
        } header: {
            Text(LS("重命名 / 合并"))
        } footer: {
            Text(LS("子账户会一起改名，例如 %@:Sub 变为 %@:Sub。", n, valid ? to : "…"))
        }
    }

    private func ledgerFiles() -> [String] {
        (store.tree?.files.keys.map { $0 } ?? []).filter { isLedgerFile($0) && !$0.hasSuffix(".bql") }.sorted()
    }

    private func count(_ n: String) async -> (files: Int, places: Int) {
        var files = 0, places = 0
        for p in ledgerFiles() {
            guard let t = try? await store.fileText(p) else { continue }
            let k = countAccount(t, n)
            if k > 0 { files += 1; places += k }
        }
        return (files, places)
    }

    private func rename(_ L: Ledger) async {
        guard let from = name else { return }
        let to = newName.trimmed
        let merge = L.accounts[to].map { !$0.implicit } == true
        let label = merge ? LS("合并账户：%@ → %@", from, to) : LS("重命名账户：%@ → %@", from, to)
        var ops: [Op] = []
        if merge {
            for e in [openEntry(L), closeEntry(L)].compactMap({ $0 }) {
                var op = Op(kind: .remove, path: e.file)
                op.old = e.src
                op.date = e.date
                op.label = label
                ops.append(op)
            }
        }
        for p in ledgerFiles() {
            guard let t = try? await store.fileText(p), countAccount(t, from) > 0 else { continue }
            var op = Op(kind: .rename, path: p)
            op.old = from
            op.text = to
            op.label = label
            op.summary = label
            ops.append(op)
        }
        guard !ops.isEmpty else { store.showFailure(LS("账本中没有出现该账户")); return }
        // file rules and the accounts left out of 净资产 / 资产负债表 follow the account
        if let c = store.repoConfig?.renamingAccount(from, to: to) {
            guard var op = await store.fileWriteOp(LedgerXConfig.path, text: c.json()) else { return }
            op.silent = true
            ops.append(op)
        }
        if await store.commit(ops, word: merge ? LS("已合并账户") : LS("已重命名账户"), closing: { dismiss() }) {
            store.renameInGrid(from, to: to)
            store.popToken += 1
        }
    }

    private static var roots: [String] { AccountManagerView.roots }
}
