import Foundation

/// An account to check against the bank: it has a statement / check day (`statement_day`), the latest
/// such day has passed, and no balance assertion covers it yet. Accounts without the day are never checked.
public struct ReconcileDue: Identifiable, Equatable {
    public let account: String
    public let currency: String
    /// the statement / check day: the balance at the end of this day is checked
    public let day: String
    /// the ledger's balance at the end of `day`
    public let ledger: Double
    /// the latest earlier assertion of this account and currency
    public let lastChecked: String?
    /// the assertion's date: Beancount checks a balance at the start of its day, so the day after
    public var date: String { Day.shift(day, 1) }
    public var id: String { account + "|" + currency }
}

/// balance of `account` in `currency` at the end of `date` (postings on that day included)
public func balance(_ L: Ledger, account: String, currency: String, endOf date: String) -> Double {
    var t = 0.0
    for x in L.txns where x.date <= date {
        for p in x.postings where p.account == account && p.currency == currency { t += p.units ?? 0 }
    }
    return (t * 100).rounded() / 100
}

/// every account due for a check today
public func reconcileDue(_ L: Ledger, today: String = Day.today()) -> [ReconcileDue] {
    var out: [ReconcileDue] = []
    for (name, acc) in L.accounts.sorted(by: { $0.key < $1.key })
    where (name.hasPrefix("Assets:") || name.hasPrefix("Liabilities:")) && (acc.close == nil || acc.close! > today) {
        guard let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { continue }
        let day = statementOn(orBefore: today, day: sd)
        if let o = acc.open, o > day { continue }
        var ccys = acc.currencies
        if ccys.isEmpty { ccys = (L.final[name] ?? [:]).keys.sorted() }
        if ccys.isEmpty { ccys = [L.base] }
        let assertions = L.balances.filter { $0.account == name }
        for c in ccys {
            let mine = assertions.filter { ($0.currency ?? "") == c }
            // checked on or after the day (by this check, or by hand later on)
            if mine.contains(where: { $0.date > day }) { continue }
            // a currency the account no longer holds and never asserted
            let v = balance(L, account: name, currency: c, endOf: day)
            if abs(v) < 0.005 && mine.isEmpty && ccys.count > 1 { continue }
            out.append(ReconcileDue(account: name, currency: c, day: day, ledger: v,
                                    lastChecked: mine.map { $0.date }.max()))
        }
    }
    return out
}

/// the assertion line that records a check
public func reconcileOp(_ r: ReconcileDue, amount: Double, path: String) -> Op {
    var op = Op(kind: .balance, path: path)
    op.account = r.account; op.date = r.date; op.currency = r.currency
    op.line = balanceLine(r.date, r.account, amount, r.currency)
    op.amountText = plainMoney(amount, r.currency)
    op.label = tr("核对余额：\(r.account) \(r.day)", "Reconcile: \(r.account) \(r.day)")
    op.summary = tr("余额断言 \(r.account)", "balance \(r.account)")
    return op
}

/// the next statement / check day (today or later) of every account that has one
public func nextCheckDays(_ L: Ledger, today: String = Day.today()) -> [(account: String, day: String)] {
    L.accounts.sorted(by: { $0.key < $1.key }).compactMap { name, acc in
        guard name.hasPrefix("Assets:") || name.hasPrefix("Liabilities:"), acc.close == nil || acc.close! > today,
              let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { return nil }
        return (name, statementOn(orAfter: today, day: sd))
    }
}
