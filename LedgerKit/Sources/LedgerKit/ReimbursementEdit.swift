import Foundation

// What the phone's and the Mac's reimbursement pages write: advances put on a reimbursement or petty cash, their
// 支出类型 and 凭证类型, a link taken off, and the money paid back. Both apps turn these into their own saves.

/// put advances on a reimbursement or petty cash: `#reimbursed ^link` on each header. `files` holds the current text of
/// each file they are in; nil when one is no longer there as it was. With a label the first op carries it, without one
/// they are all silent (the save's own entry names the change)
public func advanceLinkOps(_ entries: [Entry], link: String, label: String?, files: [String: String]) -> [Op]? {
    var ops: [Op] = []
    var done = Set<ObjectIdentifier>()
    for e in entries {
        guard done.insert(ObjectIdentifier(e)).inserted else { continue }
        guard let file = files[e.file], let current = EntryLocator(e).resolve(in: parseFile(file, file: e.file).entries) else { return nil }
        let lines = file.components(separatedBy: "\n")
        guard current.startLine < lines.count else { return nil }
        var op = Op(kind: .link, path: e.file)
        op.headerLine = current.startLine + 1
        op.header = lines[current.startLine]
        op.add = (e.tags.contains("reimbursed") ? "" : " #reimbursed") + " ^" + link
        op.link = link
        if let label, ops.isEmpty { op.label = label } else { op.silent = true }
        ops.append(op)
    }
    return ops
}

/// 支出类型 (`category:`) or 凭证类型 (`voucher:`) on an advance's receivable line; nil value clears it. Nil when nothing changes
public func advanceMetaOp(_ t: Entry, receivable: String, key: String, value: String?) -> Op? {
    guard let text = setPostingMeta(t.src, account: receivable, key: key, value: value), text != t.src else { return nil }
    var op = entryOp(t, text: text)
    let what = key == categoryMeta ? LS("支出类型") : LS("凭证类型")
    op.label = LS("%@：%@ %@ → %@", what, t.date, t.payee, value.map { key == categoryMeta ? acctLabel($0) : $0 } ?? LS("清除"))
    return op
}

/// add or remove `^link` on a transaction; nil when nothing changes
public func linkEditOp(_ e: Entry, link: String, remove: Bool) -> Op? {
    let text = headerLinkEdit(e.src, link: link, remove: remove)
    guard text != e.src else { return nil }
    return entryOp(e, text: text)
}

/// 报销回款: the money a reimbursement brought back. What was advanced (`owed`) comes off the receivable; more than that is
/// 报销差额 income, less is a loss, or with `keepOpen` stays on the link to be paid later
public struct ReimbursementPayment: Sendable {
    public var date: String
    public var payee: String
    /// the account it came into
    public var account: String
    public var link: String
    /// what the advances add up to
    public var owed: Double
    /// what came back
    public var got: Double
    public var currency: String
    public var receivable: String
    public var keepOpen: Bool

    public init(date: String, payee: String, account: String, link: String, owed: Double, got: Double, currency: String,
                receivable: String, keepOpen: Bool) {
        self.date = date; self.payee = payee; self.account = account; self.link = link; self.owed = owed; self.got = got
        self.currency = currency; self.receivable = receivable; self.keepOpen = keepOpen
    }

    /// where a difference either way goes when it isn't kept open (报销差额)
    public static let difference = "Income:ReimbExcess"

    /// the transaction to write; empty until there is something owed, something paid back and an account
    public var text: String {
        guard got > 0, owed > 0, !account.isEmpty else { return "" }
        let diff = roundTo(got - owed, 2)
        var tx = TxDraft(date: date)
        tx.payee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = link.range(of: #"\d{8}$"#, options: .regularExpression).map { String(link[$0]) } ?? date.replacingOccurrences(of: "-", with: "")
        tx.narration = LS("报销入账-") + digits
        tx.tags = ["reimbursement"]
        tx.links = [link]
        let pending = diff < -0.004 && keepOpen
        tx.postings = [TxPosting(account: receivable, amount: -(pending ? got : owed), currency: currency)]
        if diff > 0.004 { tx.postings.append(TxPosting(account: Self.difference, amount: -diff, currency: currency)) }
        if diff < -0.004 && !keepOpen { tx.postings.append(TxPosting(account: Self.difference, amount: -diff, currency: currency)) }
        tx.postings.append(TxPosting(account: account, amount: got, currency: currency))
        return formatTxn(tx)
    }
}
