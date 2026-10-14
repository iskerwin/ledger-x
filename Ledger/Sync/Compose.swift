import SwiftUI
import LedgerKit

/// how the 记一笔 category grid looks: kept on this phone (Prefs "catStyle"), never written to the ledger
struct CatStyle: Codable, Equatable {
    /// icons used to be kept under a lone account (Expenses:Foo:Bar for a group of one): now under its group
    func normalized() -> CatStyle {
        var s = self
        for (k, v) in icons where k.components(separatedBy: ":").count > 2 {
            s.icons[k] = nil
            if s.icons[catOf(k)] == nil { s.icons[catOf(k)] = v }
        }
        return s
    }

    /// SF Symbol per group or account (a group of one is keyed by its account)
    var icons: [String: String] = [:]
    /// a name of one's own for a group
    var titles: [String: String] = [:]
    /// per root ("Expenses:", "Income:"): the groups in the order shown, fixed once the grid is first seen
    var order: [String: [String]] = [:]
    /// groups left out of the grid (still in 完整表单 and the account picker)
    var hidden: [String] = []
}

/// whether iOS has a symbol of this name (a typo or an older iOS draws nothing)
@MainActor enum Symbols {
    private static var known: [String: Bool] = [:]
    static func valid(_ s: String) -> Bool {
        if let k = known[s] { return k }
        let v = UIImage(systemName: s) != nil
        known[s] = v
        return v
    }
}

extension Store {
    // MARK: - the card

    /// Open the 记一笔 card with whatever is in the form. `full` picks the page; by default the full form for what the
    /// quick one can't show (分录, 文本, 退款, AA).
    func openAdd(full: Bool? = nil) {
        var d = draft
        // an untouched form left from another day starts on today
        if d.amount.trimmed.isEmpty && d.payee.trimmed.isEmpty && d.edited == nil && d.raw.trimmed.isEmpty
            && d.refundOf == nil && d.date != Day.today() {
            d.date = Day.today()
            if !d.eventsTouched { d.events = autoEvents(on: d.date) }
            draft = d
        }
        addFull = full ?? needsFullForm(d)
        addToken += 1
        adding = true
    }

    /// what only the full form can edit
    // MARK: - 可视化编辑

    /// open an entry of the ledger in the 记一笔 form; false when the form can't hold all of it (edit its source)
    func beginEdit(_ t: Entry) async -> Bool {
        guard let L = L, let D = D, var d = editDraft(t, L, D) else { return false }
        guard let file = try? await fileText(t.file) else { return false }
        let lines = file.components(separatedBy: "\n")
        guard t.endLine < lines.count else { return false }
        let old = lines[t.startLine...t.endLine].joined(separator: "\n")
        let summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        d.replacing = Replacing(path: t.file, old: old, date: t.date, summary: summary,
                                baseline: draftText(d, L, D, explicit: explicitAmounts).trimmed)
        draft = d
        openAdd(full: needsFullForm(d))
        return true
    }

    /// the card closed while editing: back to a new entry
    func endEdit() {
        scanInfo = nil
        guard draft.replacing != nil else { return }
        draft = newDraftFor(.expense)
    }

    /// the entry `old` (at `path`) replaced by `newText`: in place when the date and file stay, else moved to
    /// the end of its new day; links paired with it follow
    func replaceOps(old: String, path: String, date: String, summary: String, newText: String) async -> [Op]? {
        var rm = Op(kind: .remove, path: path)
        rm.old = old
        rm.label = LS("修改：%@ %@", date, summary)
        guard var ins = makeOps(newText, extra: OpExtra(silent: true), single: true) else { return nil }
        var first = [rm]
        if ins.count == 1, ins[0].kind == .insert, ins[0].path == path, ins[0].date == date {
            var op = Op(kind: .replace, path: path)
            op.old = old
            op.text = ins[0].text
            op.date = date
            op.label = rm.label
            op.summary = ins[0].summary
            op.amountText = ins[0].amountText
            first = [op]
            ins = []
        } else if let i = ins.firstIndex(where: { $0.kind == .insert }) {
            // moved to another day: the page showing it follows it there
            ins[i].moves = old
        }
        return await review(first + ins + pairedLinkOps(oldText: old, newText: newText))
    }

    func needsFullForm(_ d: Draft) -> Bool {
        [.refund, .multi, .raw].contains(d.kind) || d.split
    }

    // MARK: - the category grid

    /// the root of the categories for a kind of entry
    static func categoryRoot(_ k: DraftKind) -> String { k == .income ? "Income:" : "Expenses:" }

    /// the groups under `root` as the grid shows them: in the saved order, hidden ones left out
    func gridGroups(_ root: String, _ D: Derived) -> [CategoryGroup] {
        let hidden = Set(catStyle.hidden)
        return orderedGroups(categoryGroups(D, root: root), saved: catStyle.order[root] ?? []).filter { !hidden.contains($0.id) }
    }

    /// every group under `root` (hidden ones too), in the saved order
    func allGroups(_ root: String, _ D: Derived) -> [CategoryGroup] {
        orderedGroups(categoryGroups(D, root: root), saved: catStyle.order[root] ?? [])
    }

    /// fix the order the first time the grid is seen (the most used first), so cells don't move about later
    func freezeGridOrder(_ root: String, _ D: Derived) {
        let all = allGroups(root, D).map { $0.id }
        let saved = catStyle.order[root] ?? []
        if saved.isEmpty || all.contains(where: { !saved.contains($0) }) {
            var s = catStyle
            s.order[root] = all
            catStyle = s
        }
    }

    /// an account renamed or merged: its icon, name, place and hidden state in the grid go along (its sub-accounts too)
    func renameInGrid(_ from: String, to: String) {
        func move(_ a: String) -> String { a == from ? to : a.hasPrefix(from + ":") ? to + String(a.dropFirst(from.count)) : a }
        var s = catStyle
        s.icons = Dictionary(s.icons.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.titles = Dictionary(s.titles.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.order = s.order.mapValues { l in l.map(move).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        s.hidden = s.hidden.map(move).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if s != catStyle { catStyle = s }
    }

    /// a group's icon everywhere (the grid, 管理账户, the account list, reports): the one picked, else the built-in one —
    /// the account kind's for assets and liabilities, the category guess for income and expenses
    func groupIcon(_ account: String) -> AccountKind {
        let g = catOf(account)
        let base = AccountKind.of(g)
        let category = g.hasPrefix("Expenses") || g.hasPrefix("Income")
        let color: Color = category ? .jade : base.color
        if let s = catStyle.icons[g], Symbols.valid(s) { return AccountKind(symbol: s, color: color) }
        return category ? AccountKind(symbol: catIcon(g), color: color) : base
    }

    /// what a cell's icon is kept under: its group (Expenses:Food, Assets:Bank)
    static func cellKey(_ g: CategoryGroup) -> String { g.id }

    /// a group's or account's symbol: the one picked, else the built-in guess from its English name
    func catIcon(_ key: String) -> String {
        if let s = catStyle.icons[key], Symbols.valid(s) { return s }
        let d = defaultCategoryIcon(key)
        return Symbols.valid(d) ? d : "square.grid.2x2"
    }

    /// the cell's name: one's own, the account's name for a group of one, else the group's (餐饮美食)
    func catTitle(_ g: CategoryGroup, _ L: Ledger) -> String {
        if let t = catStyle.titles[g.id]?.trimmed, !t.isEmpty { return t }
        return defaultCatTitle(g, L)
    }

    /// the name a cell has without one of one's own
    func defaultCatTitle(_ g: CategoryGroup, _ L: Ledger) -> String {
        // a group of one: its account's name: if it has one, else the group's (交通出行 for a lone Transit:Metro)
        if g.single, let a = g.accounts.first, let v = L.accounts[a]?.meta["name"], !(v.stringValue ?? v.display).isEmpty {
            return accountTitle(L, a)
        }
        return acctZH(g.id) ?? leaf(g.single ? g.accounts[0] : g.id)
    }

    // MARK: - the form (shared by the quick card and 完整表单)

    func setKind(_ k: DraftKind) {
        guard let D = D else { return }
        var d = draft
        d.kind = k
        d.edited = nil
        if k == .transfer { d.currency = D.acctCcy[d.funding] ?? d.currency }
        else if k != .multi, let c = defaultCurrency { d.currency = c }
        if k == .multi && !d.rows.contains(where: { !$0.account.isEmpty }) {
            d.rows = [DraftRow(), DraftRow(account: d.funding, currency: D.acctCcy[d.funding] ?? "CNY")]
        }
        // an expense category left over from the previous form would turn income into a negative expense
        if !Store.fits(k, d.account) { d.account = "" }
        if k != .expense {
            d.reimb = false; d.split = false; d.shares = []; d.extraFunds = []; d.discount = ""
            if isFloatLink(d.link.trimmed) { d.link = "" }
        }
        draft = d
    }

    /// whether a category suits the kind of entry (income needs Income:, an expense Expenses:)
    static func fits(_ k: DraftKind, _ account: String) -> Bool {
        switch k {
        case .income: return account.isEmpty || account.hasPrefix("Income:")
        case .expense: return account.isEmpty || account.hasPrefix("Expenses:")
        default: return true
        }
    }

    /// a known payee fills in the category and paying account of its last entry
    func applyPayee(_ name: String) {
        guard let D = D else { return }
        var d = draft
        d.payee = name
        d.edited = nil
        if let p = D.payee(name) {
            let t = p.last
            if d.kind == .multi {
                if !d.rows.contains(where: { !$0.amount.trimmed.isEmpty }) { d.rows = rowsFromTxn(t, withAmounts: false) }
            } else {
                let cat = t.postings.first { $0.account.hasPrefix(d.kind == .income ? "Income:" : "Expenses:") }
                    ?? (d.kind == .expense ? t.postings.first { advanceCategory($0) != nil } : nil)
                let fund = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }
                if let cat = cat {
                    d.account = cat.account.hasPrefix("Expenses:") || cat.account.hasPrefix("Income:") ? cat.account : advanceCategory(cat) ?? d.account
                    if let c = cat.currency, cat.account == d.account { d.currency = c }
                } else if !Store.fits(d.kind, d.account) { d.account = "" }
                if let fund = fund, !fund.account.hasPrefix("Assets:Receivable") { d.funding = fund.account }
            }
        }
        draft = d
    }

    /// Check and save the form (not 文本, which asks about replacing balance assertions first). True once it is
    /// queued; the form is then ready for the next entry, keeping the kind, paying account and date.
    @discardableResult
    /// save the form (a screenshot's card remembers which account it is, see saveScanned)
    func saveDraft() async -> Bool {
        guard scanInfo != nil else { return await saveForm() }
        return await saveScanned()
    }

    func saveForm() async -> Bool {
        guard let L = L, let D = D else { return false }
        let d = draft
        let text = draftText(d, L, D, explicit: explicitAmounts).trimmed
        let v = validateText(text, L, single: draftIsSingle(d, L))
        guard v.ok else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            show(v.msg ?? LS("内容校验未通过"))
            return false
        }
        if let r = d.replacing {
            // editing: nothing changed, nothing written
            if text == r.baseline { draft = newDraftFor(.expense); return true }
            guard let ops = await replaceOps(old: r.old, path: r.path, date: r.date, summary: r.summary, newText: text) else { return false }
            draft = newDraftFor(.expense)
            popToken += 1
            return await commit(ops, word: LS("已更新"), checked: true)
        }
        if d.kind == .multi {
            guard let ops0 = makeOps(text, single: true), let ops = await review(ops0) else { return false }
            var nd = newDraftFor(.multi)
            nd.date = d.date
            nd.rows = d.rows.map { r in var x = r; x.amount = ""; x.id = UUID(); return x }
            draft = nd
            return await commit(ops, checked: true)
        }
        guard var ops = makeOps(text, single: draftIsSingle(d, L)) else { return false }
        // the original purchase gets the refund link that is actually in the saved text (it may have been edited)
        if let o = d.refundOf, let lk = refundLink(in: text, preferred: o.link) {
            var link = Op(kind: .link, path: o.path)
            link.headerLine = o.line; link.header = o.header; link.link = lk; link.add = " ^" + lk; link.silent = true
            ops.append(link)
        }
        guard let checked = await review(ops) else { return false }
        var nd = newDraftFor(d.kind == .refund ? .expense : d.kind)
        nd.funding = d.funding
        nd.date = d.date
        nd.currency = entryCurrency(nd.kind, funding: d.funding)
        // the events follow the kept date, unless they were picked by hand
        if nd.kind != .transfer {
            nd.events = d.eventsTouched ? d.events : autoEvents(on: nd.date)
            nd.eventsTouched = d.eventsTouched
        }
        draft = nd
        return await commit(checked, checked: true)
    }

    // MARK: - 常用交易

    /// put a frequent entry in the form (the amount too when it is always the same)
    func fillTemplate(_ x: Template) {
        var d = newDraftFor(x.kind == .income ? .income : .expense)
        d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        draft = d
    }

    /// a frequent entry with a fixed amount, saved for today in one tap (with 撤销 on the toast)
    func saveTemplateNow(_ x: Template) async {
        guard let L = L, let D = D else { return }
        var d = newDraftFor(x.kind == .income ? .income : .expense)
        d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        d.date = Day.today()
        let text = draftText(d, L, D)
        guard let ops = makeOps(text, single: true), let ins = ops.first(where: { $0.kind == .insert }) else { return }
        let label = LS("已入账：%@ %@", x.label, money(x.fixed ?? 0, x.currency))
        await commit(ops, word: label, undo: { @MainActor [weak self] in
            guard let self = self else { return }
            if self.pending.contains(where: { $0.id == ins.id }) {
                await self.dropPending(ins)
                self.show(LS("已撤销"))
                return
            }
            var rm = Op(kind: .remove, path: ins.path)
            rm.old = ins.text
            rm.label = LS("撤销：%@ %@", ins.date ?? "", ins.summary ?? "")
            await self.commit([rm], word: LS("已撤销"))
        })
    }
}

/// a frequent entry as a chip: tap to fill the form, 入账 to save it at once when its amount is fixed
struct TemplateChip: View {
    @EnvironmentObject var store: Store
    let x: Template
    @Binding var saving: Bool
    /// after the form was filled (focus the amount, say)
    var filled: (Template) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.fillTemplate(x)
                filled(x)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if x.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.jade) }
                        Text(x.label).font(.subheadline.weight(.medium)).lineLimit(1)
                        if !x.payee.isEmpty && !x.narration.isEmpty { Text(x.narration).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    HStack(spacing: 4) {
                        Text(x.fixed.map { money($0, x.currency) } ?? LS("金额待填")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                        if x.due { Text(LS("本月未入账")).font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            if x.fixed != nil {
                Divider().frame(height: 28)
                Button {
                    guard !saving else { return }
                    saving = true
                    Task { await store.saveTemplateNow(x); saving = false }
                } label: {
                    Text(LS("入账")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.jade).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("直接入账：%@", x.label))
            }
        }
        .background(x.due ? Color.orange.opacity(0.12) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}
