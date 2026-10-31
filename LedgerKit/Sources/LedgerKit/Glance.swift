import Foundation

/// What an account's card face shows besides its balance: when its balance was last checked, its end-of-day balance
/// over the last 30 days, and what came in and went out this month. In one currency, the account's own.
public struct AccountGlance: Equatable {
    public let currency: String
    /// the date of the latest `balance` on this account, nil when it was never checked
    public let lastCheck: String?
    /// the balance at the end of each of the last `days` days, oldest first, today last
    public let trend: [Double]
    public let inflow: Double
    public let outflow: Double
}

/// The glance of `account` in `currency` on `today`. Postings to its sub-accounts count too, as on its register.
public func accountGlance(_ L: Ledger, _ account: String, currency: String, today: String = Day.today(), days: Int = 30) -> AccountGlance {
    L.memoized("glance|\(account)|\(currency)|\(today)|\(days)") { glance(L, account, currency, today, days) }
}

private func glance(_ L: Ledger, _ account: String, _ currency: String, _ today: String, _ days: Int) -> AccountGlance {
    let pre = account + ":"
    let mine = { (a: String) in a == account || a.hasPrefix(pre) }
    let lastCheck = L.balances.filter { $0.account.map(mine) ?? false }.map(\.date).max()

    let first = Day.shift(today, -(days - 1))
    let ym = Day.ym(today)
    var running = 0.0
    var trend: [Double] = []
    var day = first
    var inflow = 0.0, outflow = 0.0
    func fill(upTo date: String) {
        while trend.count < days && day < date { trend.append(running); day = Day.shift(day, 1) }
    }
    for t in L.txns where t.date <= today {
        fill(upTo: t.date)
        for p in t.postings where mine(p.account) && p.currency == currency && p.cost == nil {
            guard let u = p.units else { continue }
            running += u
            if Day.ym(t.date) == ym { if u > 0 { inflow += u } else { outflow -= u } }
        }
    }
    fill(upTo: Day.shift(today, 1))
    return AccountGlance(currency: currency, lastCheck: lastCheck, trend: trend, inflow: inflow, outflow: outflow)
}
