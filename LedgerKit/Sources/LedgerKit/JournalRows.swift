import Foundation

/// how an amount reads in a list: what went out, what came in, or money only moving
public enum AmountTone: Sendable, Equatable { case loss, gain, neutral }

/// an amount as a journal row shows it, kept as a figure so that hiding amounts still applies when it's drawn
public struct ShownAmount: Sendable, Equatable {
    public let amount: Double
    public let currency: String
    public let tone: AmountTone

    /// "+¥12.00" for what came in, "-¥12.00" for what went out; money only moving has no sign
    public var text: String { tone == .neutral ? money(amount, currency) : signedMoney(amount, currency) }
}

/// an entry on a line of the journal, with what it shows and sorts by worked out once for the ledger
public struct JournalRow: Identifiable {
    public let entry: Entry
    /// where it is written: file and line
    public let id: String
    public let date: String
    /// who, else the narration
    public let payee: String
    /// the narration under the payee, when there are both
    public let note: String
    public let category: String
    /// where the money went, and who the personal receivable lines are with
    public let accounts: String
    /// what it sorts by: what was spent or earned, in the operating currency, or what a transfer moved
    public let amount: Double
    public let kind: TxKind
    /// as in the phone's journal: what moved in the account being looked through, else a transfer's amount, else what
    /// was spent or earned in each currency as booked. A transfer that paid a fee shows both what it moved and the fee
    public let amounts: [ShownAmount]
    /// what the accounts were charged in another currency, for checking against the bank
    public let charged: [ShownAmount]
    /// 待确认, pad, or a tag of its own
    public let marked: Bool
    /// a balance assertion, a note or a document; nil for a transaction
    public let directive: EntryType?
    /// a balance assertion that didn't hold: what the account held is under the amount
    public let failed: Bool

    public init(_ t: Entry, _ L: Ledger, account: String? = nil) {
        entry = t
        directive = nil
        failed = false
        id = "\(t.file):\(t.line)"
        date = t.date
        payee = t.payee.isEmpty ? (t.narration.isEmpty ? "（无收付款方）" : t.narration) : t.payee
        note = t.payee.isEmpty ? "" : t.narration
        category = shownCategory(t).map(acctDisplay) ?? "转账"
        accounts = t.route + Self.withWhom(t)
        let shown = classify(t, L)
        amount = shown.amount
        kind = shown.kind
        let own = sums(t.postings.filter(isCategory), negate: true)
        if let account {
            amounts = sums(t.postings.filter { $0.account == account || $0.account.hasPrefix(account + ":") }, negate: false).map(signed)
            charged = []
        } else if shown.kind == .transfer {
            amounts = [ShownAmount(amount: shown.amount, currency: shown.currency ?? L.base, tone: .neutral)]
            charged = []
        } else {
            let moved = transferWithFee(t).map { [ShownAmount(amount: $0.amount, currency: $0.currency, tone: .neutral)] } ?? []
            amounts = moved + own.map(signed)
            charged = sums(t.postings.filter { !isCategory($0) && !$0.account.hasPrefix("Equity:") }, negate: false)
                .filter { paid in !own.contains { $0.0 == paid.0 } }
                .map { ShownAmount(amount: $0.1, currency: $0.0, tone: .neutral) }
        }
        marked = t.flag == "!" || t.synthetic || t.tags.contains { $0 != "transfer" && $0 != "fx" }
    }

    /// a balance assertion (what it says the account holds, and what it held when it didn't), a note or a document
    init(directive d: Entry, _ L: Ledger, result: BalanceResult?) {
        entry = d
        id = "\(d.file):\(d.line)"
        date = d.date
        directive = d.type
        let account = d.account ?? ""
        payee = accountTitle(L, account)
        accounts = acctDisplay(account)
        amount = d.number
        kind = .transfer
        marked = false
        failed = result.map { !$0.ok } ?? false
        switch d.type {
        case .balance:
            category = "余额断言"
            note = ""
            amounts = [ShownAmount(amount: d.number, currency: d.currency ?? L.base, tone: failed ? .loss : .neutral)]
            charged = failed ? result.map { [ShownAmount(amount: $0.got, currency: d.currency ?? L.base, tone: .neutral)] } ?? [] : []
        case .document:
            category = "文档"
            note = (d.path ?? "").components(separatedBy: "/").last ?? ""
            amounts = []
            charged = []
        default:
            category = "备注"
            note = d.comment ?? ""
            amounts = []
            charged = []
        }
    }

    /// " · 五姨、王五": who the personal receivable lines are with
    private static func withWhom(_ t: Entry) -> String {
        var names: [String] = []
        for p in t.postings where isPersonal(p.account) {
            if let name = postingPerson(p), !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "" : " · " + names.joined(separator: "、")
    }
}

/// every transaction on a line, the latest written first, worked out once for the ledger (it doesn't change once
/// loaded). With an account, only those that moved money in it or its sub-accounts, showing what moved there
public func journalRows(_ L: Ledger, account: String? = nil) -> [JournalRow] {
    L.memoized("journalRows|\(account ?? "")") {
        let entries = L.txns.reversed().filter { t in
            account.map { a in t.postings.contains { $0.account == a || $0.account.hasPrefix(a + ":") } } ?? true
        }
        return entries.map { JournalRow($0, L, account: account) }
    }
}

/// the balance assertions, notes and documents on a line each, the latest written first; with an account, those on it
/// and the accounts under it
public func journalDirectives(_ L: Ledger, account: String? = nil) -> [JournalRow] {
    L.memoized("journalDirectives|\(account ?? "")") {
        var results: [ObjectIdentifier: BalanceResult] = [:]
        for result in L.balanceResults { results[ObjectIdentifier(result.entry)] = result }
        let all = (L.balances + L.notes + L.documents).filter { d in
            account.map { a in d.account == a || (d.account ?? "").hasPrefix(a + ":") } ?? true
        }
        return all.sorted { ($0.date, $0.seq) > ($1.date, $1.seq) }
            .map { JournalRow(directive: $0, L, result: results[ObjectIdentifier($0)]) }
    }
}

extension Entry {
    /// a transaction written in a file, and only it, can be changed from a list of entries: what the ledger works out (a
    /// pad's entry) has no text of its own, and the other directives are changed in their file
    public var editable: Bool { type == .txn && !synthetic }

    /// where it went: its category, or for what has none the accounts the money went through
    public var route: String {
        let categories = postings.filter(isCategory)
        return moneyRoute(self).filter { account in !categories.contains { $0.account == account } }.map(acctDisplay).joined(separator: " → ")
    }
}

private func isCategory(_ p: Posting) -> Bool { p.account.hasPrefix("Expenses:") || p.account.hasPrefix("Income:") }

private func signed(_ amount: (String, Double)) -> ShownAmount {
    ShownAmount(amount: amount.1, currency: amount.0, tone: amount.1 < 0 ? .loss : .gain)
}

/// per currency, in the order they first appear (amounts too small to show left out)
private func sums(_ postings: [Posting], negate: Bool) -> [(String, Double)] {
    var order: [String] = [], totals: [String: Double] = [:]
    for p in postings {
        guard let units = p.units, let currency = p.currency else { continue }
        if totals[currency] == nil { order.append(currency) }
        totals[currency, default: 0] += negate ? -units : units
    }
    return order.compactMap { abs(totals[$0]!) > 0.004 ? ($0, totals[$0]!) : nil }
}
