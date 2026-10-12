import Foundation

/// An account to check against the bank: it has a statement / check day (`statement_day`), that day has
/// come, and no balance assertion covers it yet. Accounts without the day are never checked.
/// The assertion is dated the day itself — Beancount checks it at the start of the day, i.e. the balance
/// the previous day ended with — so it is never in the future, and entries recorded on or after the day
/// can't break it; only changes to earlier days can.
/// The bank app shows the balance as it is now, so that is what gets compared: with the ledger's balance
/// up to today. When they agree, the ledger's balance at the start of the day is what is asserted.
public struct ReconcileDue: Identifiable, Equatable {
    public let account: String
    public let currency: String
    /// the statement / check day, also the assertion's date
    public let day: String
    /// the ledger's balance at the start of `day`: the amount asserted
    public let ledger: Double
    /// the ledger's balance now (entries up to today), to compare with the bank app
    public let now: Double
    /// entries on this account from `day` up to today, and their sum
    public let since: Int
    public let sinceTotal: Double
    /// the latest earlier assertion of this account and currency
    public let lastChecked: String?
    public var date: String { day }
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
        if let o = acc.open, o >= day { continue }
        var ccys = acc.currencies
        if ccys.isEmpty { ccys = (L.final[name] ?? [:]).keys.sorted() }
        if ccys.isEmpty { ccys = [L.base] }
        let assertions = L.balances.filter { $0.account == name }
        for c in ccys {
            let mine = assertions.filter { ($0.currency ?? "") == c }
            // checked on or after the day (by this check, or by hand later on)
            if mine.contains(where: { $0.date >= day }) { continue }
            let start = balance(L, account: name, currency: c, endOf: Day.shift(day, -1))
            let now = balance(L, account: name, currency: c, endOf: today)
            // a currency the account no longer holds and never asserted
            if abs(start) < 0.005 && abs(now) < 0.005 && mine.isEmpty && ccys.count > 1 { continue }
            var n = 0, sum = 0.0
            for x in L.txns where x.date >= day && x.date <= today {
                let ps = x.postings.filter { $0.account == name && $0.currency == c }
                if ps.isEmpty { continue }
                n += 1
                sum += ps.reduce(0) { $0 + ($1.units ?? 0) }
            }
            out.append(ReconcileDue(account: name, currency: c, day: day, ledger: start, now: now,
                                    since: n, sinceTotal: (sum * 100).rounded() / 100,
                                    lastChecked: mine.map { $0.date }.max()))
        }
    }
    return out
}

/// the next statement / check day (today or later) of every account that has one
public func nextCheckDays(_ L: Ledger, today: String = Day.today()) -> [(account: String, day: String)] {
    L.accounts.sorted(by: { $0.key < $1.key }).compactMap { name, acc in
        guard name.hasPrefix("Assets:") || name.hasPrefix("Liabilities:"), acc.close == nil || acc.close! > today,
              let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { return nil }
        return (name, statementOn(orAfter: today, day: sd))
    }
}
