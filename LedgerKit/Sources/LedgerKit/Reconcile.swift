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

struct ReconcileTotals {
    var start = 0.0, now = 0.0, sinceTotal = 0.0
    var count = 0
}

/// The accounts that can be due, and their statement day. `add` folds one posting in (the same additions
/// `reconcileDue` used to make in its own walk); `result` is that function's list.
struct ReconcileScan {
    let today: String
    let days: [String: String]
    private let accounts: [(name: String, account: Account)]
    private var totals: [String: [String: ReconcileTotals]] = [:]

    init(_ L: Ledger, today: String) {
        self.today = today
        accounts = L.accounts.sorted(by: { $0.key < $1.key }).filter { name, account in
            (name.hasPrefix("Assets:") || name.hasPrefix("Liabilities:")) && (account.close == nil || account.close! > today)
        }
        var days: [String: String] = [:]
        for (name, account) in accounts {
            guard let day = metaInt(account.meta[statementDayKey]), day >= 1, day <= 31 else { continue }
            let date = statementOn(orBefore: today, day: day)
            if let opened = account.open, opened >= date { continue }
            days[name] = date
        }
        self.days = days
    }

    mutating func add(posting: Posting, date: String, counted: inout Set<String>) {
        guard date <= today, let day = days[posting.account], let currency = posting.currency else { return }
        var value = totals[posting.account]?[currency] ?? ReconcileTotals()
        let units = posting.units ?? 0
        value.now += units
        if date < day { value.start += units }
        else {
            value.sinceTotal += units
            if counted.insert(posting.account + "|" + currency).inserted { value.count += 1 }
        }
        totals[posting.account, default: [:]][currency] = value
    }

    func result(_ L: Ledger) -> [ReconcileDue] {
        let assertions = Dictionary(grouping: L.balances, by: { $0.account ?? "" })
        func rounded(_ amount: Double) -> Double { (amount * 100).rounded() / 100 }
        var out: [ReconcileDue] = []
        for (name, account) in accounts {
            guard let day = days[name] else { continue }
            var currencies = account.currencies
            if currencies.isEmpty { currencies = (L.final[name] ?? [:]).keys.sorted() }
            if currencies.isEmpty { currencies = [L.base] }
            for currency in currencies {
                let mine = (assertions[name] ?? []).filter { $0.currency == currency }
                if mine.contains(where: { $0.date >= day }) { continue }
                let value = totals[name]?[currency] ?? ReconcileTotals()
                let start = rounded(value.start), now = rounded(value.now)
                if abs(start) < 0.005 && abs(now) < 0.005 && mine.isEmpty && currencies.count > 1 { continue }
                out.append(ReconcileDue(account: name, currency: currency, day: day, ledger: start, now: now,
                                        since: value.count, sinceTotal: rounded(value.sinceTotal),
                                        lastChecked: mine.map { $0.date }.max()))
            }
        }
        return out
    }
}

/// every account due for a check today
public func reconcileDue(_ L: Ledger, today: String = Day.today()) -> [ReconcileDue] {
    var scan = ReconcileScan(L, today: today)
    for transaction in L.txns where transaction.date <= today {
        var counted = Set<String>()
        for posting in transaction.postings { scan.add(posting: posting, date: transaction.date, counted: &counted) }
    }
    return scan.result(L)
}

/// the next statement / check day (today or later) of every account that has one
public func nextCheckDays(_ L: Ledger, today: String = Day.today()) -> [(account: String, day: String)] {
    L.accounts.sorted(by: { $0.key < $1.key }).compactMap { name, acc in
        guard name.hasPrefix("Assets:") || name.hasPrefix("Liabilities:"), acc.close == nil || acc.close! > today,
              let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { return nil }
        return (name, statementOn(orAfter: today, day: sd))
    }
}

/// An invalid nonempty input must never be treated as an untouched field.
public func reconciliationAgrees(input: String, expected: Double, confirmed: Bool) -> Bool {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return confirmed }
    guard let amount = evalAmount(text.replacingOccurrences(of: ",", with: "")), amount.isFinite else { return false }
    return abs(amount - expected) < 0.005
}
