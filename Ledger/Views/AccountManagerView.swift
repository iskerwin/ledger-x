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

/// 管理账户: every account in the ledger, grouped by root
struct AccountManagerView: View {
    @EnvironmentObject var store: Store
    @State private var q = ""
    @AppStorage("ledger.manager.closed") private var showClosed = true

    static let roots = ["Assets", "Liabilities", "Income", "Expenses", "Equity"]

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { ProgressView() }
        }
        .navigationTitle(LS("管理账户"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $q, prompt: LS("搜索账户"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AccountEditDest(name: nil)) { Image(systemName: "plus") }
                    .accessibilityLabel(LS("新建账户"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showClosed) { Image(systemName: "archivebox") }.toggleStyle(.button)
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
            ForEach(Self.roots, id: \.self) { root in
                let rows = all.filter { $0.name == root || $0.name.hasPrefix(root + ":") }.sorted { $0.name < $1.name }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.name) { a in
                            NavigationLink(value: AccountEditDest(name: a.name)) { row(a, today) }
                        }
                    } header: {
                        Text(groupName(root) + " · \(rows.count)")
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    private func row(_ a: Account, _ today: String) -> some View {
        let closed = a.close.map { $0 <= today } ?? false
        let k = AccountKind.of(a.name)
        return HStack(spacing: 12) {
            IconBadge(symbol: k.symbol, color: closed ? .gray : k.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(acctLabel(a.name)).foregroundStyle(closed ? Color.secondary : Color.primary).lineLimit(1)
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
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let name: String?

    @State private var account = ""
    @State private var root = "Expenses"
    @State private var openDate = Day.today()
    @State private var currencies = ""
    @State private var booking = ""
    @State private var display = ""
    @State private var closeDate = Day.today()
    @State private var newName = ""
    @State private var impact: (files: Int, places: Int)?
    @State private var confirmClose = false
    @State private var confirmRename = false
    @State private var loaded = false
    @State private var initialFields = ""

    private var fields: String { [openDate, currencies, booking, display].joined(separator: "|") }

    private static let bookings = ["", "STRICT", "FIFO", "LIFO", "HIFO", "AVERAGE", "NONE"]

    private var isNew: Bool { name == nil }
    private func openEntry(_ L: Ledger) -> Entry? { name.flatMap { n in L.entries.last { $0.type == .open && $0.account == n } } }
    private func closeEntry(_ L: Ledger) -> Entry? { name.flatMap { n in L.entries.last { $0.type == .close && $0.account == n } } }

    var body: some View {
        Group {
            if let L = store.L { form(L) } else { ProgressView() }
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
            Button(LS("关闭账户"), role: .destructive) { close(L) }
        } message: {
            Text(LS("将写入一条 close 指令，此后该账户不能再有交易。"))
        }
        .confirmationDialog(renameTitle(L), isPresented: $confirmRename, titleVisibility: .visible) {
            Button(LS("确认"), role: .destructive) { Task { await rename(L) } }
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
                if !account.trimmed.isEmpty && !valid {
                    Label(LS("账户名需以五大类开头，各级以冒号分隔，每级首字母大写，如 Assets:Bank:CMB"), systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.warn)
                } else if exists {
                    Label(LS("该账户已存在"), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.warn)
                }
                parentChips(L)
            } else {
                LabeledContent(LS("账户"), value: name ?? "").font(.body.monospaced())
            }
            DatePicker(LS("开立日期"), selection: dateBinding($openDate), displayedComponents: .date)
            LabeledContent(LS("显示名称")) {
                TextField(LS("可选，如「招商银行储蓄卡」"), text: $display).multilineTextAlignment(.trailing)
            }
            LabeledContent(LS("限定币种")) {
                TextField(LS("可选，如 CNY,USD"), text: $currencies)
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Picker(LS("批次方法"), selection: $booking) {
                ForEach(Self.bookings, id: \.self) { b in Text(b.isEmpty ? LS("默认") : b).tag(b) }
            }
            MonoText(text: openText(L))
            Button {
                saveOpen(L)
            } label: {
                Text(isNew ? LS("开立账户") : LS("保存修改")).frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isNew ? (!valid || exists) : fields == initialFields)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text(isNew ? LS("新账户") : LS("开户信息"))
        } footer: {
            Text(isNew ? LS("写入开户指令最多的文件。显示名称保存为 name 元数据，App 会显示在账户名旁边。") : LS("修改会直接替换原来的 open 指令，保留其他元数据。"))
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
        var head = "\(openDate) open \(n)"
        if !ccy.isEmpty { head += String(repeating: " ", count: max(1, 56 - head.count)) + ccy.joined(separator: ",") }
        if !booking.isEmpty { head += " \"\(booking)\"" }
        var lines = [head]
        // keep the other metadata of the original directive
        if let e = openEntry(L) {
            for l in e.src.components(separatedBy: "\n").dropFirst() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("name:") || t.isEmpty { continue }
                lines.append(l)
            }
        }
        if !display.trimmed.isEmpty {
            lines.insert("  name: \"\(display.trimmed.replacingOccurrences(of: "\"", with: "'"))\"", at: 1)
        }
        return lines.joined(separator: "\n")
    }

    private func saveOpen(_ L: Ledger) {
        let text = openText(L)
        if let e = openEntry(L) {
            var op = Op(kind: .replace, path: e.file)
            op.old = e.src
            op.text = text
            op.date = openDate
            op.label = LS("修改账户：%@", name ?? "")
            op.summary = op.label
            Task { await store.commit([op], word: LS("已修改账户")) }
        } else {
            guard let ops = store.makeOps(text, single: false) else { return }
            Task { await store.commit(ops, word: LS("已开立账户")) }
        }
        dismiss()
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
                Button(LS("重新开启账户")) {
                    var op = Op(kind: .remove, path: ce.file)
                    op.old = ce.src
                    op.date = ce.date
                    op.label = LS("重新开启账户：%@", n)
                    op.summary = op.label
                    Task { await store.commit([op], word: LS("已重新开启")) }
                    dismiss()
                }
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
                    Label(LS("当前余额 %@，建议先转出或通过余额核对确认为零", bal.map { money($0.1, $0.0) }.joined(separator: LS("、"))), systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.warn).sensitive()
                }
                Button(LS("关闭账户"), role: .destructive) { confirmClose = true }
            } header: {
                Text(LS("关闭账户"))
            } footer: {
                Text(LS("关闭后历史记录保留；账户默认不在账户页显示。"))
            }
        }
    }

    private func close(_ L: Ledger) {
        guard let n = name, let ops = store.makeOps("\(closeDate) close \(n)", single: false) else { return }
        Task { await store.commit(ops, word: LS("已关闭账户")) }
        dismiss()
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
            if let i = impact, valid {
                Text(LS("将修改 %@ 个文件中的 %@ 处", i.files, i.places)).font(.footnote).foregroundStyle(.secondary)
            }
            if merge {
                Label(LS("%@ 已存在：将把本账户的全部记录并入该账户，并移除本账户的开户 / 关户指令。原有余额断言会一并转移，可能需要重新核对。", to), systemImage: "arrow.triangle.merge")
                    .font(.footnote).foregroundStyle(Color.warn)
            }
            Button(merge ? LS("合并账户") : LS("重命名账户")) { confirmRename = true }
                .disabled(!valid)
        } header: {
            Text(LS("重命名 / 合并"))
        } footer: {
            Text(LS("子账户会一起改名，例如 %@:Sub 变为 %@:Sub。", n, valid ? to : "…"))
        }
        .task(id: to) {
            impact = nil
            guard valid else { return }
            impact = await count(n)
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
        guard !ops.isEmpty else { store.show(LS("账本中没有出现该账户")); return }
        dismiss()
        await store.commit(ops, word: merge ? LS("已合并账户") : LS("已重命名账户"))
        store.popToken += 1
    }

    private static var roots: [String] { AccountManagerView.roots }
}
