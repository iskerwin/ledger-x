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
    /// a colour of one's own for a group's icon (an IconTint name). Optional, so a style saved before reads back whole.
    var colors: [String: String]?
}

/// the colours a group's icon can take: system colours, each with its own shade in dark mode
enum IconTint {
    /// (computed: the titles follow the app's language when it is switched)
    static var all: [(name: String, title: String, color: Color)] { [
        ("red", LS("红"), .red), ("orange", LS("橙"), .orange), ("yellow", LS("黄"), .yellow), ("green", LS("绿"), .green),
        ("mint", LS("薄荷"), .mint), ("teal", LS("青绿"), .teal), ("cyan", LS("青"), .cyan), ("blue", LS("蓝"), .blue),
        ("indigo", LS("靛蓝"), .indigo), ("purple", LS("紫"), .purple), ("pink", LS("粉"), .pink), ("brown", LS("棕"), .brown),
    ] }
    static func color(_ name: String?) -> Color? { name.flatMap { n in all.first { $0.name == n }?.color } }
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
        if d.replacing == nil && !drafts.hasChanges && !draftHasContent(d) && d.edited == nil
            && d.refundOf == nil && d.date != Day.today() {
            d.date = Day.today()
            if !d.eventsTouched { d.events = autoEvents(on: d.date) }
            drafts.install(DraftSession(draft: d, baseline: d))
        }
        addFull = full ?? needsFullForm(d)
        // already open (再记一笔, a shortcut): only the page may change
        if adding { addToken += 1; return }
        Haptics.selection()
        addToken += 1
        adding = true
    }

    /// what only the full form can edit
    // MARK: - 可视化编辑

    /// why 编辑 did or didn't open the form
    enum EditStart: Equatable {
        /// the 记一笔 form is open on this entry
        case opened
        /// the form would drop something it can't show; edit the source instead
        case needsSource
        /// this copy's text isn't in the file (read failed, or identical copies moved and can't be told apart)
        case missing
    }

    /// the entry's text as it is in its file now (pending edits applied), and its 1-based first line.
    /// Nil when the file can't be read, or when identical copies can no longer be told apart.
    func locatedSource(_ t: Entry) async -> (text: String, line: Int)? {
        let ledgerID = cfg.id
        guard let file = try? await fileText(t.file), cfg.id == ledgerID,
              let e = EntryLocator(t).resolve(in: parseFile(file, file: t.file).entries) else { return nil }
        return (e.src, e.line)
    }

    /// the entry's text as it is in its file now; nil when `locatedSource` can't pick this copy
    func entryText(_ t: Entry) async -> String? {
        await locatedSource(t)?.text
    }

    /// delete one entry (with the links paired with it), after the change review; true when committed.
    /// `anchorLine` is the 1-based first line, so an identical copy elsewhere is left alone.
    @discardableResult
    func deleteEntry(path: String, old: String, date: String, summary: String, pop: Bool = true, anchorLine: Int? = nil) async -> Bool {
        let ledgerID = cfg.id
        var rm = Op(kind: .remove, path: path)
        rm.old = old
        rm.anchorLine = anchorLine
        rm.label = LS("删除：%@ %@", date, summary)
        guard let ops = await review([rm] + pairedLinkOps(oldText: old, newText: nil)), cfg.id == ledgerID else { return false }
        if pop { popToken += 1 }
        return await commit(ops, word: LS("已删除"), checked: true)
    }

    @discardableResult
    func deleteEntry(_ t: Entry) async -> Bool {
        guard let located = await locatedSource(t) else {
            showFailure(LS("没有在文件里对上原来的文字，所以没有改动。"))
            return false
        }
        let summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        return await deleteEntry(path: t.file, old: located.text, date: t.date, summary: summary, anchorLine: located.line)
    }

    func beginEdit(_ t: Entry) async -> EditStart {
        guard let L = L, let D = D else { return .missing }
        guard let located = await locatedSource(t) else { return .missing }
        guard var d = editDraft(t, L, D) else { return .needsSource }
        let summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        d.replacing = Replacing(path: t.file, old: located.text, date: t.date, summary: summary,
                                baseline: draftText(d, L, D, explicit: explicitAmounts).trimmed, line: located.line)
        persistActiveDraft()
        let session = draftWorkspace.session(for: d)
        drafts.trackKinds(for: d, reset: true)
        drafts.install(session)
        openAdd(full: needsFullForm(session.draft))
        if session.hasChanges { show(LS("已恢复这笔交易的编辑草稿")) }
        return .opened
    }

    /// the card closed while editing: back to a new entry
    func endEdit() {
        scanInfo = nil
        guard draft.replacing != nil else { return }
        persistActiveDraft()
        restoreCreationDraft()
    }

    /// the entry `old` (at `path`) replaced by `newText`: in place when the date and file stay, else moved to
    /// the end of its new day; links paired with it follow
    /// (`transaction`: the text must be one transaction; false for another directive, a note say)
    func replaceOps(old: String, path: String, date: String, summary: String, newText: String, transaction: Bool = true, anchorLine: Int? = nil) async -> [Op]? {
        let ledgerID = cfg.id
        let originals = parseFile(old, file: path).entries
        guard originals.count == 1, let current = try? await fileText(path), cfg.id == ledgerID,
              EntryLocator(originals[0], startLine: anchorLine.map { $0 - 1 }).text(in: current) != nil else {
            showFailure(LS("原记录已变化，草稿已保留。可复制草稿内容后核对。"))
            return nil
        }
        var rm = Op(kind: .remove, path: path)
        rm.old = old
        rm.anchorLine = anchorLine
        rm.label = LS("修改：%@ %@", date, summary)
        guard var ins = makeOps(newText, extra: OpExtra(silent: true), single: transaction) else { return nil }
        var first = [rm]
        if ins.count == 1, ins[0].kind == .insert, ins[0].path == path, ins[0].date == date {
            var op = Op(kind: .replace, path: path)
            op.old = old
            op.text = ins[0].text
            op.date = date
            op.anchorLine = anchorLine
            op.label = rm.label
            op.summary = ins[0].summary
            op.amountText = ins[0].amountText
            first = [op]
            ins = []
        } else if let i = ins.firstIndex(where: { $0.kind == .insert }) {
            // moved to another day: the page showing it follows it there
            ins[i].moves = old
            ins[i].anchorLine = anchorLine
        }
        let checked = await review(first + ins + pairedLinkOps(oldText: old, newText: newText))
        return cfg.id == ledgerID ? checked : nil
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
        s.colors = s.colors.map { c in Dictionary(c.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }) }
        if s != catStyle { catStyle = s }
        let faces = renamedFaceStyles(faceStyles, from: from, to: to)
        if faces != faceStyles { faceStyles = faces }
        renameCards(from, to: to)
    }

    /// a group's icon everywhere (the grid, 管理账户, the account list, reports): the one picked, else the built-in one —
    /// the account kind's for assets and liabilities, the category guess for income and expenses
    func groupIcon(_ account: String) -> AccountKind {
        let g = catOf(account)
        let base = AccountKind.of(g)
        let category = g.hasPrefix("Expenses") || g.hasPrefix("Income")
        let color = pickedTint(account) ?? (category ? .jade : base.color)
        if let s = catStyle.icons[g], Symbols.valid(s) { return AccountKind(symbol: s, color: color) }
        return AccountKind(symbol: category ? catIcon(g) : base.symbol, color: color)
    }

    /// the colour picked for an account's group, nil when none was (each place then keeps its own)
    func pickedTint(_ account: String) -> Color? { IconTint.color(catStyle.colors?[catOf(account)]) }

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

    @discardableResult
    func setKind(_ k: DraftKind) -> Bool {
        guard let D = D, let L = L else { return false }
        guard k != draft.kind else { return true }
        drafts.trackKinds(for: draft, reset: false)
        let next: Draft
        if [.multi, .raw].contains(k) || [.multi, .raw].contains(draft.kind) || draft.edited != nil {
            let previous = drafts.kindSnapshots[k] ?? (drafts.baseline?.kind == k ? drafts.baseline : nil)
            if let back = returningToSetAside(draft, to: k) {
                next = back
            } else {
                switch convertingEditor(draft, to: k, ledger: L, derived: D, previous: previous) {
                // unfinished 分录 / 文本 waits for the way back instead of locking the user in
                case .failure(.incomplete) where [.multi, .raw].contains(draft.kind):
                    next = settingAside(draft, to: k, previous: previous)
                    show(LS("「%@」里还没填完的内容已保留，切回「%@」可以继续", draft.kind.label, draft.kind.label))
                case .failure(.notRepresentable) where [.multi, .raw].contains(draft.kind):
                    next = settingAside(draft, to: k, previous: previous)
                    show(LS("「%@」显示不了「%@」的内容，已原样保留，切回「%@」可以继续", k.label, draft.kind.label, draft.kind.label))
                case .failure(let error): showFailure(error.message); return false
                case .success(let converted): next = converted
                }
            }
            drafts.kindSnapshots[draft.kind] = draft
        } else {
            let switched = switchingKind(draft, to: k, remembering: drafts.kindSnapshots,
                                         fundingCurrency: D.acctCcy[draft.funding], defaultCurrency: defaultCurrency)
            drafts.kindSnapshots = switched.snapshots
            next = switched.draft
        }
        if let baseline = drafts.baseline {
            drafts.install(DraftSession(draft: draft, baseline: baseline).selectingKind(next))
            persistActiveDraft()
        } else { draft = next }
        return true
    }

    /// 清空 (a new entry) or 还原 (an edit) the full form; nothing to do when it already is that
    /// (read on every keystroke: no new form is built for it)
    var formClears: Bool {
        guard drafts.baseline != nil, draft.kind != .refund else { return false }
        if draft.replacing != nil { return drafts.hasChanges }
        return draftHasContent(draft) || draft.setAside != nil || !draft.account.isEmpty || !draft.to.isEmpty
            || draft.rows.contains { !$0.account.isEmpty && $0.account != draft.funding }
    }

    /// 清空 / 还原 the full form, taken back from the toast's 撤销 (the other kinds' remembered content too)
    func clearForm() {
        guard let baseline = drafts.baseline, formClears else { return }
        let before = draft, snapshots = drafts.kindSnapshots
        let editing = draft.replacing != nil
        drafts.install(DraftSession(draft: clearedDraft(draft, fresh: newDraftFor(draft.kind), baseline: baseline), baseline: baseline))
        drafts.kindSnapshots = [:]
        persistActiveDraft()
        show(editing ? LS("已还原为原记录") : LS("已清空"), action: LS("撤销")) { [weak self] in
            guard let self, self.drafts.baseline == baseline else { return }
            self.drafts.install(DraftSession(draft: before, baseline: baseline))
            self.drafts.kindSnapshots = snapshots
            self.persistActiveDraft()
        }
    }

    /// The back button must convert the latest split/text contents before showing the quick editor.
    func prepareQuickEditor() -> Bool {
        guard [.multi, .raw].contains(draft.kind), let L = L, let D = D else { return true }
        let simple: [DraftKind] = [.expense, .income, .transfer]
        // a whole entry the quick page can show goes back as its kind; anything else (unbalanced, more lines than it
        // shows) back to the kind the form was opened as, set aside for the way back (see setKind). A failed check
        // still parses, so its transaction is not taken for a whole one
        let checked = validateText(draftText(draft, L, D), L, single: true)
        let shown = checked.ok ? checked.txn.flatMap { editDraft($0, L, D)?.kind }.flatMap { simple.contains($0) ? $0 : nil } : nil
        let opened = drafts.baseline.map(\.kind).flatMap { simple.contains($0) ? $0 : nil }
        return setKind(shown ?? opened ?? .expense)
    }

    func applyDraftSource(_ text: String) {
        guard let L = L, let D = D else { return }
        var current = draft
        if current.kind == .raw { current.raw = text; current.edited = nil; draft = current; return }
        current.edited = text
        if case .success(var converted) = convertingEditor(current, to: current.kind, ledger: L, derived: D) {
            converted.edited = text
            draft = converted
        } else { draft = current }
    }

    /// whether a category suits the kind of entry (income needs Income:, an expense Expenses:)
    static func fits(_ k: DraftKind, _ account: String) -> Bool { draftKindFits(k, account) }

    /// a known payee fills in the category and paying account of its last entry
    func applyPayee(_ name: String, onlyBlanks: Bool = false) {
        guard let D = D else { return }
        var d = draft
        d.payee = name
        d.edited = nil
        if let p = D.payee(name) {
            let t = p.last
            if d.kind == .multi {
                if !d.rows.contains(where: { !$0.account.isEmpty || !$0.amount.trimmed.isEmpty }) { d.rows = rowsFromTxn(t, withAmounts: false) }
            } else {
                let cat = t.postings.first { $0.account.hasPrefix(d.kind == .income ? "Income:" : "Expenses:") }
                    ?? (d.kind == .expense ? t.postings.first { advanceCategory($0) != nil } : nil)
                let fund = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }
                if let cat = cat {
                    let category = cat.account.hasPrefix("Expenses:") || cat.account.hasPrefix("Income:") ? cat.account : advanceCategory(cat)
                    d = applyingSuggestedAccounts(d, category: onlyBlanks && !d.account.isEmpty ? nil : category, funding: nil)
                    if d.selection?.category != true, !onlyBlanks, let c = cat.currency, cat.account == d.account { d.currency = c }
                } else if !Store.fits(d.kind, d.account) { d.account = "" }
                if let fund = fund, !fund.account.hasPrefix("Assets:Receivable") {
                    d = applyingSuggestedAccounts(d, category: nil, funding: onlyBlanks && !d.funding.isEmpty ? nil : fund.account)
                }
            }
        }
        draft = d
    }

    /// Check and save the form (not 文本, which asks about replacing balance assertions first). True once it is
    /// queued; the form is then ready for the next entry, keeping the kind, paying account and date.
    @discardableResult
    /// save the form (a screenshot's card is remembered with the entry, see saveForm)
    func saveDraft(onQueued: (() -> Void)? = nil) async -> Bool {
        let timing = SaveTiming()
        guard !drafts.isSaving else { return false }
        drafts.isSaving = true
        defer { drafts.isSaving = false }
        guard await saveForm(onQueued: onQueued) else { return false }
        timing.record("draft-save-finished")
        scanInfo = nil
        return true
    }

    func saveForm(onQueued: (() -> Void)? = nil) async -> Bool {
        let timing = SaveTiming()
        guard let L = L, let D = D else { return false }
        let d = draft
        if d.edited == nil, let issue = draftIssue(d, L, D) {
            showFailure(issue.message); return false
        }
        let text = draftText(d, L, D, explicit: explicitAmounts).trimmed
        let v = validateText(text, L, single: draftIsSingle(d, L))
        timing.record("text-validation-finished")
        guard v.ok else {
            Haptics.error()
            // an empty text means the form isn't complete yet: say what is missing
            let why = text.isEmpty ? draftMissing(d, L, D) : v.msg
            showFailure(why.flatMap { $0.isEmpty ? nil : $0 } ?? (text.isEmpty ? LS("还没填完整") : LS("内容校验未通过")))
            return false
        }
        /// Runs only after the queue has the change. Clears this draft before the sheet goes away,
        /// so closing does not write the saved entry back as an unfinished draft.
        let queued: (Draft) -> Void = { next in
            self.finishDraft(with: next)
            onQueued?()
        }
        if let r = d.replacing {
            // editing: nothing changed, nothing written
            if text == r.baseline { finishDraft(with: newDraftFor(.expense)); return true }
            guard let ops = await replaceOps(old: r.old, path: r.path, date: r.date, summary: r.summary, newText: text, anchorLine: r.line) else { return false }
            return markSaved(text, await commit(ops, word: LS("已更新"), checked: true, onQueued: { queued(self.newDraftFor(.expense)) }))
        }
        if d.kind == .multi {
            guard let ops0 = makeOps(text, single: true), let ops = await review(ops0) else { return false }
            var nd = newDraftFor(.multi)
            nd.date = d.date
            nd.rows = d.rows.map { r in var x = r; x.amount = ""; x.id = UUID(); return x }
            return markSaved(text, await commit(ops, checked: true, onQueued: { queued(nd) }))
        }
        guard var ops = makeOps(text, single: draftIsSingle(d, L)) else { return false }
        // the original purchase gets the refund link that is actually in the saved text (it may have been edited)
        if let o = d.refundOf, let link = refundLinkOp(o, savedText: text) { ops.append(link) }
        // a screenshot's card saved with an account it wasn't known by: remembered in ledger-x.json (all devices),
        // in the same commit as the entry
        var word = LS("已入账")
        // (the settings as they are in the file now, with what is queued for it)
        let current = (try? await fileText(LedgerXConfig.path)).flatMap(LedgerXConfig.parse) ?? effectiveConfig
        if let (key, account) = scanCardToRemember(d, cards: current.scanCards ?? [:]) {
            var c = current
            var m = c.scanCards ?? [:]
            m[key] = account
            c.scanCards = m
            guard var op = await fileWriteOp(LedgerXConfig.path, text: c.json()) else { return false }
            op.label = LS("截图记账：%@ 记为 %@", key, acctLabel(account))
            op.silent = true
            ops.append(op)
            word = LS("已入账，并记住了这张卡")
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
        return markSaved(text, await commit(checked, word: word, checked: true, onQueued: { queued(nd) }))
    }

    /// after a save from the form: its row in 明细 lights up for a moment
    private func markSaved(_ text: String, _ ok: Bool) -> Bool {
        guard ok else { return false }
        let saved = normEntryText(text)
        justSaved = saved
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.justSaved == saved { self?.justSaved = nil }
        }
        return true
    }

    // MARK: - 常用交易

    /// put a frequent entry in the form (the amount too when it is always the same)
    func fillTemplate(_ x: Template) {
        var d = newDraftFor(x.kind == .income ? .income : .expense)
        d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        var selection = DraftSelection(); selection.category = !d.account.isEmpty; selection.funding = !d.funding.isEmpty
        d.selection = selection
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
    @Environment(Store.self) var store
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
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    HStack(spacing: AppSpacing.detail) {
                        if x.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.jadeInk) }
                        Text(x.label).font(.subheadline.weight(.medium)).lineLimit(1)
                        if !x.payee.isEmpty && !x.narration.isEmpty { Text(x.narration).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    HStack(spacing: AppSpacing.detail) {
                        Text(x.fixed.map { money($0, x.currency) } ?? LS("金额待填")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                        if x.due { Text(LS("本月未入账")).font(.caption2.weight(.semibold)).foregroundStyle(Color.warn) }
                    }
                }
                .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
            }
            .buttonStyle(.plain)
            if x.fixed != nil {
                Divider().frame(height: 28)
                Button {
                    guard !saving else { return }
                    saving = true
                    Task { await store.saveTemplateNow(x); saving = false }
                } label: {
                    Label(LS("入账"), systemImage: "checkmark").labelStyle(ControlLabelStyle()).font(.subheadline.weight(.semibold)).foregroundStyle(Color.jadeInk).padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("直接入账：%@", x.label))
            }
        }
        .background(x.due ? Color.warn.soft : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.control))
    }
}

