import Foundation

// What the phone's and the Mac's subscription pages write: a plan added, changed or corrected, paused or cancelled,
// a period skipped, charges linked, a line undone, the whole plan deleted. Both apps turn these into their own saves.

/// a subscription being added, changed from a date on (调价或更改, 恢复, 调整到期日) or corrected in place
public struct SubDraft: Identifiable {
    public enum Mode: Sendable { case new, change, correct }
    public let id = UUID()
    public var mode = Mode.new
    /// only the next charge date changes (调整到期日)
    public var dueOnly = false
    public var name = ""
    public var amount = ""
    public var currency = "CNY"
    public var period = SubPeriod.monthly
    public var custom = false
    public var start = Day.today()
    /// effective date of a change
    public var date = Day.today()
    public var account = ""
    public var funding = ""
    public var payee = ""
    public var extended = false
    public var next = Day.today()
    public var trial = false
    public var trialEnd = Day.shift(Day.today(), 30)
    public var status = SubStatus.active
    public var link = ""
    public var manual = false
    public var variable = false
    /// the subscription being changed
    public var original: Subscription?
    /// transactions to link (from a candidate)
    public var txns: [Entry] = []
    public var picked = Set<Int>()

    public init(currency: String) { self.currency = currency }

    public init(_ s: Subscription, mode: Mode) {
        self.mode = mode
        name = s.name; amount = jsNumberString(s.amount); currency = s.currency; period = s.period
        custom = !SubPeriod.presets.contains(s.period)
        start = s.start; account = s.account; funding = s.funding; payee = s.payee
        extended = s.next != nil
        next = s.next ?? s.due(onOrAfter: Day.today())
        trial = s.trialEnd != nil
        trialEnd = s.trialEnd ?? Day.shift(Day.today(), 30)
        status = s.status; link = s.link; original = s
        manual = s.manual; variable = s.variable
        date = Day.today()
    }

    /// 调整到期日: a dated change that only moves the next charge
    public init(dueOf s: Subscription) {
        self.init(s, mode: .change)
        dueOnly = true
        extended = true
        next = s.nextCharge(onOrAfter: Day.today())
    }

    public init(_ c: SubCandidate) {
        name = c.payee; amount = jsNumberString(c.amount); currency = c.currency; period = c.period
        start = c.first; account = c.account; funding = c.funding; payee = c.payee
        txns = c.txns; picked = Set(c.txns.map { $0.id })
    }

    /// from a transaction: its expense leg, funding leg and date
    public init(_ t: Entry, _ L: Ledger) {
        name = t.payee.isEmpty ? t.narration : t.payee
        payee = t.payee
        start = t.date
        if let e = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }) {
            account = e.account
            amount = jsNumberString(abs(e.units ?? 0))
            currency = e.currency ?? L.base
        }
        funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
        txns = [t]; picked = [t.id]
    }

    public var sub: Subscription? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let a = evalAmount(amount), a > 0, !name.isEmpty else { return nil }
        var s = Subscription(name: name, amount: a, currency: currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                             period: period, start: start, account: account, funding: funding,
                             payee: payee.trimmingCharacters(in: .whitespacesAndNewlines),
                             next: extended && next > (mode == .change ? date : start) ? next : nil, status: status,
                             link: link.isEmpty ? nil : link, trialEnd: trial ? trialEnd : nil)
        s.manual = manual
        s.variable = variable
        if mode == .change { s.status = .active }
        return s
    }

    /// the text to write: a whole first line, or only what changed for a dated change
    public var text: String? {
        guard let s = sub else { return nil }
        switch mode {
        case .new: return subscriptionText(s, date: start)
        case .correct: return subscriptionText(s, date: original?.entry?.date ?? start)
        case .change:
            var lines = [subscriptionText(s, date: date, full: false)]
            let q = quoted
            if let o = original {
                if s.account != o.account { lines.insert("  account: " + q(s.account), at: 1) }
                if s.funding != o.funding { lines.insert("  funding: " + q(s.funding), at: 1) }
                if s.payee != o.payee { lines.insert("  payee: " + q(s.payee), at: 1) }
                if s.trialEnd != o.trialEnd, let t = s.trialEnd { lines.insert("  trial_end: " + t, at: 1) }
                if s.manual != o.manual { lines.insert("  renew: " + q(s.manual ? "manual" : "auto"), at: 1) }
                if s.variable != o.variable { lines.insert("  variable: " + (s.variable ? "TRUE" : "FALSE"), at: 1) }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// what this change does, for the commit message and the toast
    public var changeSummary: String {
        guard let s = sub else { return "" }
        guard let o = original else { return LS("新订阅：%@ %@ / %@", s.name, money(s.amount, s.currency), s.period.name) }
        var parts: [String] = []
        if o.status != .active && mode == .change { parts.append(LS("恢复")) }
        if abs(s.amount - o.amount) > 0.005 { parts.append(LS("调价 %@ → %@", money(o.amount, o.currency), money(s.amount, s.currency))) }
        if s.period != o.period { parts.append(o.period.name + " → " + s.period.name) }
        if s.account != o.account { parts.append(LS("科目 → %@", acctLabel(s.account))) }
        if s.funding != o.funding { parts.append(LS("付款账户 → %@", acctLabel(s.funding))) }
        if s.manual != o.manual { parts.append(s.manual ? LS("改为手动续费") : LS("改为自动扣费")) }
        if s.variable != o.variable { parts.append(s.variable ? LS("金额不固定") : LS("金额固定")) }
        if s.name != o.name { parts.append(LS("改名为 %@", s.name)) }
        if s.trialEnd != o.trialEnd { parts.append(LS("试用期")) }
        if s.next != o.next { parts.append(s.next.map { LS("下次扣费日改为 %@", $0) } ?? LS("下次扣费日")) }
        let what = parts.isEmpty ? LS("更新") : parts.joined(separator: LS("，"))
        return mode == .change ? LS("%@：%@（%@ 起）", s.name, what, date) : LS("%@：%@", s.name, what)
    }

    /// another subscription already uses this name
    public func nameTaken(_ subs: [Subscription]) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n != original?.name && subs.contains { $0.name == n }
    }

    /// the ops of saving it, apart from linking charges: `insert` turns new ledger text into insert ops (the app's makeOps
    /// with this label). A correction rewrites its line in place, a new name renaming the other lines too; a second change
    /// on one day replaces that day's line, keeping what it changed that the new one doesn't mention
    public func ops(insert: (_ text: String, _ label: String) -> [Op]?) -> [Op]? {
        guard let s = sub, let text else { return nil }
        let label = changeSummary
        switch mode {
        case .new:
            return insert(text, label)
        case .correct:
            guard let o = original, let e = o.entry else { return nil }
            var op = entryOp(e, text: text)
            op.label = label
            var ops = [op]
            if s.name != o.name {
                for other in o.entries where other !== e {
                    var r = entryOp(other, text: other.src.replacingOccurrences(of: "\"subscription\" " + quoted(o.name), with: "\"subscription\" " + quoted(s.name)))
                    r.silent = true
                    ops.append(r)
                }
            }
            return ops
        case .change:
            if let o = original, let e = o.entry, e.date == date, o.entries.count > 1 {
                var op = Op(kind: .replace, path: e.file)
                op.old = e.src; op.text = subscriptionMergedChange(text, into: e.src); op.date = e.date; op.label = label
                return [op]
            }
            return insert(text, label)
        }
    }
}

/// a second change on one day: the new line, plus the old line's settings it doesn't mention
/// (next charge and status are always the new line's)
public func subscriptionMergedChange(_ text: String, into old: String) -> String {
    func key(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix(" "), let c = t.firstIndex(of: ":") else { return nil }
        return String(t[..<c])
    }
    let lines = text.components(separatedBy: "\n")
    let have = Set(lines.compactMap(key))
    let keep = old.components(separatedBy: "\n").dropFirst().filter { l in
        guard let k = key(l) else { return false }
        return !have.contains(k) && k != "next" && k != "status"
    }
    return ([lines[0]] + keep + lines.dropFirst()).joined(separator: "\n")
}

/// add `^link` to the header of each transaction; a left-over or other subscription's link is replaced. `files` holds the
/// current text of each file they are in; nil when one is no longer there as it was
public func subscriptionLinkOps(_ txns: [Entry], link: String, label: String?, files: [String: String]) -> [Op]? {
    var ops: [Op] = []
    for original in txns where !original.links.contains(link) {
        guard let file = files[original.file],
              let e = EntryLocator(original).resolve(in: parseFile(file, file: original.file).entries) else { return nil }
        var op: Op
        if let oldLink = e.links.first(where: { $0.hasPrefix("sub-") }) {
            op = entryOp(e, text: headerLinkReplace(e.src, link: oldLink, with: link))
        } else {
            let lines = file.components(separatedBy: "\n")
            guard e.startLine < lines.count else { return nil }
            op = Op(kind: .link, path: e.file)
            op.headerLine = e.startLine + 1; op.header = lines[e.startLine]
            op.add = " ^" + link; op.link = link; op.date = e.date
        }
        if ops.isEmpty, let label { op.label = label } else { op.silent = true }
        ops.append(op)
    }
    return ops
}

/// take `^link` off a transaction
public func subscriptionUnlinkOp(_ e: Entry, link: String) -> Op {
    var op = entryOp(e, text: headerLinkReplace(e.src, link: link, with: nil))
    op.label = LS("取消订阅关联：%@ %@", e.date, e.payee)
    return op
}

/// the subscription's link off all its charges
public func subscriptionUnlinkAllOps(_ s: Subscription) -> [Op] {
    s.charges.filter { $0.txn.links.contains(s.link) }.map { c in
        var op = subscriptionUnlinkOp(c.txn, link: s.link)
        op.label = nil; op.silent = true
        return op
    }
}

/// every line of the subscription, and with `unlink` its link off the charges
public func subscriptionDeleteOps(_ s: Subscription, unlink: Bool) -> [Op] {
    let ops: [Op] = s.entries.enumerated().map { i, e in
        var op = Op(kind: .remove, path: e.file)
        op.old = e.src
        op.date = e.date
        if i == 0 { op.label = LS("删除订阅：%@", s.name) } else { op.silent = true }
        return op
    }
    return ops + (unlink ? subscriptionUnlinkAllOps(s) : [])
}

/// the ledger line behind one event of the history, taken out
public func subscriptionUndoOp(_ item: SubTimelineItem, _ s: Subscription) -> Op? {
    guard let e = item.entry else { return nil }
    var op = Op(kind: .remove, path: e.file)
    op.old = e.src
    op.date = e.date
    op.label = LS("撤销订阅记录：%@ %@ %@", s.name, item.from, item.title)
    return op
}

/// mark a charge as a top-up of the period before (`topup: TRUE`), or take the mark off; nil when it already is
public func subscriptionTopupOp(_ c: SubCharge, _ on: Bool, _ s: Subscription) -> Op? {
    let e = c.txn
    let text = setTxnMeta(e.src, key: subTopupMeta, value: on ? "TRUE" : nil)
    guard text != e.src else { return nil }
    var op = entryOp(e, text: text)
    op.label = on ? LS("订阅补差：%@ %@ %@", s.name, e.date, money(c.amount, s.currency))
        : LS("订阅单独一期：%@ %@ %@", s.name, e.date, money(c.amount, s.currency))
    return op
}

/// new transactions that match a subscription get its link (returns the names linked)
public func autoLinkSubscriptions(_ ops: [Op], _ L: Ledger, subs: [Subscription]) -> ([Op], [String]) {
    guard !subs.isEmpty else { return (ops, []) }
    let owned = Set(subs.map(\.link))
    var names: [String] = []
    let out = ops.map { op -> Op in
        guard op.kind == .insert, let text = op.text else { return op }
        let blocks = text.components(separatedBy: "\n\n").map { block -> String in
            let r = checkText(block, L)
            guard r.entries.count == 1, let t = r.entries.first, t.type == .txn, !t.links.contains(where: { owned.contains($0) }),
                  t.meta["subscription"] == nil,
                  let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency
            else { return block }
            let payee = t.payee.isEmpty ? t.narration : t.payee
            // two subscriptions fit equally (same payee, account and price): leave it to you
            guard ambiguousSubscriptions(payee: payee, account: exp.account, amount: u, currency: c, subs).count <= 1,
                  let s = matchSubscription(payee: payee, account: exp.account, amount: u, currency: c, subs)
            else { return block }
            var lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.hasPrefix(t.date) }) else { return block }
            lines[i] = trimTrailingSpaces(lines[i]) + " ^" + s.link
            names.append(s.name)
            return lines.joined(separator: "\n")
        }
        var o = op
        o.text = blocks.joined(separator: "\n\n")
        return o
    }
    return (out, names)
}

public func trimTrailingSpaces(_ s: String) -> String {
    var x = s
    while x.last == " " || x.last == "\t" { x.removeLast() }
    return x
}

// MARK: - straight into a folder (the Mac)

/// one thing the Mac's subscription page writes
public enum SubscriptionChange: Sendable {
    /// added, changed from a date on, corrected, or its next charge moved; a new one links the transactions picked for it
    case save(SubDraft)
    /// paused or cancelled from `date`; a cancelled plan may stay usable `until` a day
    case state(name: String, SubStatus, date: String, until: String?)
    case skip(name: String, due: String)
    case delete(name: String, unlink: Bool)
    /// a charge counted as a top-up of the period before, or as a period of its own
    case topup(Entry, on: Bool)
}

extension SubDraft: @unchecked Sendable {}

/// Worked out on the folder as it is now: the subscription is found again by name, and a change made elsewhere since
/// the page was drawn is refused rather than written over
public func prepareFolderSubscription(_ change: SubscriptionChange, folder: URL) -> Result<FolderSave, FolderSaveError> {
    let changed = FolderSaveError(message: tr("订阅记录已经变了，请重新打开再试", "The subscription has changed: open it again"))
    return prepareFolderOps(folder: folder) { ledger, insert, file in
        let subs = subscriptions(ledger)
        func current(_ name: String) -> Subscription? { subs.first { $0.name == name } }
        switch change {
        case .save(var draft):
            if let o = draft.original {
                guard let now = current(o.name), now.entries.map(\.src) == o.entries.map(\.src) else { return .failure(changed) }
                draft.original = now
            }
            if draft.nameTaken(subs) { return .failure(FolderSaveError(message: LS("已有同名订阅，请换一个名称"))) }
            if draft.mode == .new && draft.link.isEmpty {
                draft.link = uniqueSubscriptionLink(draft.name.trimmingCharacters(in: .whitespacesAndNewlines), taken: Set(subs.map(\.link)))
            }
            guard let s = draft.sub, var ops = draft.ops(insert: { text, _ in insert(text) }) else { return .failure(changed) }
            if draft.mode == .new {
                let txns = draft.txns.filter { draft.picked.contains($0.id) }
                var files: [String: String] = [:]
                for path in Set(txns.map(\.file)) { files[path] = file(path) }
                guard let linked = subscriptionLinkOps(txns, link: s.link, label: nil, files: files) else { return .failure(changed) }
                ops += linked
            }
            return .success(ops)
        case .state(let name, let status, let date, let until):
            guard current(name) != nil, let ops = insert(subscriptionStateText(name, status, date: date, until: until)) else { return .failure(changed) }
            return .success(ops)
        case .skip(let name, let due):
            guard current(name) != nil, let ops = insert(subscriptionSkipText(name, due: due)) else { return .failure(changed) }
            return .success(ops)
        case .delete(let name, let unlink):
            guard let s = current(name) else { return .failure(changed) }
            return .success(subscriptionDeleteOps(s, unlink: unlink))
        case .topup(let entry, let on):
            guard let txn = EntryLocator(entry).resolve(in: ledger.txns),
                  let s = subs.first(where: { $0.charges.contains { $0.txn === txn } }),
                  let charge = s.charges.first(where: { $0.txn === txn }) else { return .failure(changed) }
            return subscriptionTopupOp(charge, on, s).map { .success([$0]) } ?? .failure(changed)
        }
    }
}

/// the subscription a transaction is a charge of, and that charge
public func subscriptionCharge(_ entry: Entry, _ subs: [Subscription]) -> (Subscription, SubCharge)? {
    for s in subs { if let c = s.charges.first(where: { $0.txn === entry }) { return (s, c) } }
    return nil
}

/// what a charge can be turned into: true, a top-up of the period before (there is an earlier charge, and it isn't a refund);
/// false, a period of its own again; nil, neither
public func subscriptionTopupChoice(_ c: SubCharge, in s: Subscription) -> Bool? {
    if c.topup { return false }
    guard !c.refund, s.charges.contains(where: { !$0.refund && !$0.topup && ($0.date < c.date || ($0.date == c.date && $0.id < c.id)) }) else { return nil }
    return true
}
