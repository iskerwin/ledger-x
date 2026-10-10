import Foundation

// Cash-flow forecast for the "spendable" asset accounts: today's balance, then known and regular
// money movements day by day — recurring income (salary), recurring payments, subscriptions,
// credit-card bills on their due dates, and average day-to-day spending.

public struct ForecastEvent: Identifiable {
    public enum Kind: String { case income, recurring, subscription, card }
    public var id: String { kind.rawValue + "|" + title + "|" + date + "|" + (account ?? "") + "|\(amount)" }
    public let date: String
    public let title: String
    /// in the base currency; positive = money coming in
    public let amount: Double
    public let kind: Kind
    public var account: String?
}

public struct ForecastPoint: Identifiable {
    public var id: String { date }
    public let date: String
    public let value: Double
}

public struct Forecast {
    public let today: String
    public let currency: String
    /// accounts counted as spendable money
    public let accounts: [String]
    public let start: Double
    public let points: [ForecastPoint]
    public let events: [ForecastEvent]
    /// average everyday spending per day (not covered by the events)
    public let dailySpend: Double
    /// cards with no statement_day: their bills are not in the forecast
    public let cardsWithoutCycle: [String]
    public var end: Double { points.last?.value ?? start }
    public var lowest: ForecastPoint { points.min { $0.value < $1.value } ?? ForecastPoint(date: today, value: start) }
    /// the first day the balance goes below `floor`
    public func firstBelow(_ floor: Double) -> ForecastPoint? { points.first { $0.value < floor - 0.005 } }
}

/// a regular payment or income found in the history
public struct RecurringSeries: Identifiable {
    public var id: String { payee + "|" + account }
    public let payee: String
    /// the Income: or Expenses: account
    public let account: String
    /// where the money went to / came from
    public let funding: String
    public let amount: Double
    public let currency: String
    public let period: SubPeriod
    public let last: String
    public let count: Int
    public var income: Bool { account.hasPrefix("Income:") }
}

/// regular income and expenses over the last ~13 months: at least 3 times, similar amounts, even gaps
public func recurringSeries(_ L: Ledger, today: String = Day.today()) -> [RecurringSeries] {
    let since = Day.shift(today, -400)
    typealias Item = (date: String, amount: Double, currency: String, account: String, funding: String, payee: String)
    var groups: [String: [Item]] = [:]
    for t in L.txns where t.date >= since && t.date <= today && !t.synthetic {
        let payee = !t.payee.isEmpty ? t.payee : t.narration
        guard !payee.isEmpty else { continue }
        let funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
        if let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency {
            groups[payee + "|" + exp.account, default: []].append((t.date, u, c, exp.account, funding, payee))
        } else if let inc = t.postings.first(where: { $0.account.hasPrefix("Income:") }), let u = inc.units, u < 0, let c = inc.currency {
            groups[payee + "|" + inc.account, default: []].append((t.date, -u, c, inc.account, funding, payee))
        }
    }
    var out: [RecurringSeries] = []
    for (_, xs0) in groups where xs0.count >= 3 {
        let xs = xs0.sorted { $0.date < $1.date }
        let last = xs[xs.count - 1]
        let income = last.account.hasPrefix("Income:")
        // salaries vary more than bills
        let tol = income ? 0.3 : 0.05
        let same = xs.filter { abs($0.amount - last.amount) <= last.amount * tol && $0.currency == last.currency }
        guard same.count >= 3, Double(same.count) >= Double(xs.count) * 0.7 else { continue }
        var gaps: [Double] = []
        for i in 1..<same.count {
            if let a = Day.date(same[i - 1].date), let b = Day.date(same[i].date) { gaps.append(b.timeIntervalSince(a) / 86400) }
        }
        let avg = gaps.reduce(0, +) / Double(max(1, gaps.count))
        guard gaps.allSatisfy({ abs($0 - avg) <= max(4, avg * 0.15) }) else { continue }
        let period: SubPeriod
        switch avg {
        case 5...9: period = .weekly
        case 12...16: period = SubPeriod(2, .week)
        case 26...35: period = .monthly
        case 85...97: period = .quarterly
        case 175...190: period = .halfYearly
        case 350...380: period = .yearly
        default: continue
        }
        guard let ld = Day.date(last.date), let td = Day.date(today), td.timeIntervalSince(ld) / 86400 <= avg * 1.5 else { continue }
        let recent = same.suffix(3)
        let amount = roundTo(recent.reduce(0) { $0 + $1.amount } / Double(recent.count), 2)
        out.append(RecurringSeries(payee: last.payee, account: last.account, funding: last.funding, amount: amount,
                                   currency: last.currency, period: period, last: last.date, count: same.count))
    }
    return out.sorted { $0.amount / $0.period.months > $1.amount / $1.period.months }
}

/// Assets accounts that pay for everyday life: in the base currency (or convertible), used for income,
/// spending or card repayments in the last half year, and not receivables or investments
public func spendableAccounts(_ L: Ledger, today: String = Day.today()) -> [String] {
    let since = Day.shift(today, -180)
    let skip = ["Receivable", "Invest", "Stock", "Fund", "Broker", "Securities", "Pension", "Retire", "Prepaid", "Deposit:Fixed"]
    var used = Set<String>()
    for t in L.txns where t.date >= since && t.date <= today && !t.synthetic {
        let flows = t.postings.contains { $0.account.hasPrefix("Income:") || $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Liabilities:") }
        guard flows else { continue }
        for p in t.postings where p.account.hasPrefix("Assets:") && p.cost == nil { used.insert(p.account) }
    }
    return used.filter { a in
        L.accounts[a]?.close == nil && !skip.contains { a.contains($0) }
    }.sorted()
}

public func forecast(_ L: Ledger, today: String = Day.today(), days: Int = 90, includeDaily: Bool = true) -> Forecast {
    let base = L.base
    let end = Day.shift(today, days)
    let liquid = spendableAccounts(L, today: today)
    let liquidSet = Set(liquid)
    func cny(_ n: Double, _ c: String) -> Double { c == base ? n : (toCNY(L, n, c, today) ?? 0) }

    // starting balance
    let now = balancesAt(L, today)
    var start = 0.0
    for a in liquid { for (c, n) in now[a] ?? [:] { start += cny(n, c) } }

    var events: [ForecastEvent] = []
    let subs = subscriptions(L).filter { $0.status == .active }

    // recurring income and payments (paid from spendable accounts; card spending is in the card bills)
    let series = recurringSeries(L, today: today)
    var covered = Set<String>()      // payee|account handled as events, left out of the daily average
    for s in series where liquidSet.contains(s.funding) {
        if !s.income, subs.contains(where: { $0.account == s.account && ($0.payee == s.payee || $0.name == s.payee) }) { continue }
        covered.insert(s.payee + "|" + s.account)
        var k = 1
        while true {
            let d = s.period.add(s.last, k)
            if d > end || k > 400 { break }
            if d > today {
                events.append(ForecastEvent(date: d, title: s.payee, amount: (s.income ? 1 : -1) * cny(s.amount, s.currency),
                                            kind: s.income ? .income : .recurring, account: s.funding))
            }
            k += 1
        }
    }

    // subscriptions paid from spendable accounts
    for s in subs where liquidSet.contains(s.paymentAccount) {
        covered.insert(s.payee + "|" + s.account)
        covered.insert(s.name + "|" + s.account)
        var d = s.due(onOrAfter: Day.shift(today, 1)), k = 0
        while d <= end && k < 400 {
            if let t = s.trialEnd, d <= t { d = s.due(onOrAfter: Day.shift(d, 1)); k += 1; continue }
            events.append(ForecastEvent(date: d, title: s.name, amount: -cny(s.amount, s.currency), kind: .subscription, account: s.paymentAccount))
            d = s.due(onOrAfter: Day.shift(d, 1)); k += 1
        }
    }

    // credit-card bills: the current one, then estimates from recent spending
    let cycles = cardCycles(L, today: today)
    let cycleCards = Set(cycles.map { $0.account })
    for c in cycles {
        let from = usualRepaymentAccount(c.account, L)
        let title = accountTitle(L, c.account)
        if !c.settled && c.due >= today {
            events.append(ForecastEvent(date: max(c.due, Day.shift(today, 1)), title: title, amount: -cny(c.remaining, c.currency), kind: .card, account: from))
        }
        // spending per day on this card over the last 90 days
        var spent = 0.0
        let since = Day.shift(today, -90)
        for t in L.txns where t.date > since && t.date <= today {
            for p in t.postings where p.account == c.account && p.currency == c.currency { if let u = p.units, u < 0 { spent -= u } }
        }
        let perDay = spent / 90
        var st = c.nextStatement, prevSt = c.statement, k = 0
        while k < 6 {
            let (due, _) = dueDate(statement: st, statementDay: c.statementDay, dueDay: c.dueDay)
            if due > end { break }
            let daysIn = Double(daysBetween(prevSt, st))
            // the next bill already has the spending since the last statement
            let amount = k == 0 ? c.unbilled + perDay * Double(daysBetween(today, st)) : perDay * daysIn
            if amount > 0.005 { events.append(ForecastEvent(date: due, title: title, amount: -cny(roundTo(amount, 2), c.currency), kind: .card, account: from)) }
            prevSt = st
            st = statementOn(orAfter: Day.shift(st, 1), day: c.statementDay)
            k += 1
        }
    }
    let noCycle = L.accounts.keys.filter { a in
        a.hasPrefix("Liabilities:") && !cycleCards.contains(a) && L.accounts[a]?.close == nil
            && (a.contains("Credit") || a.lowercased().contains("card") || a.contains("信用卡"))
    }.sorted()

    // everyday spending from spendable accounts over the last 90 days, without the recurring items above
    var daily = 0.0
    if includeDaily {
        let since = Day.shift(today, -90)
        var spent = 0.0
        for t in L.txns where t.date > since && t.date <= today && !t.synthetic {
            guard t.postings.contains(where: { $0.account.hasPrefix("Expenses:") }) else { continue }
            let payee = !t.payee.isEmpty ? t.payee : t.narration
            if let e = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), covered.contains(payee + "|" + e.account) { continue }
            if let m = t.meta["subscription"], !(m.stringValue ?? m.display).isEmpty { continue }
            for p in t.postings where liquidSet.contains(p.account) {
                if let u = p.units, u < 0, let c = p.currency { spent -= cny(u, c) }
            }
        }
        daily = roundTo(spent / 90, 2)
    }

    // day by day
    events.sort { $0.date != $1.date ? $0.date < $1.date : $0.amount > $1.amount }
    var seenIDs = Set<String>()
    events = events.filter { seenIDs.insert($0.id).inserted }
    var byDay: [String: Double] = [:]
    for e in events { byDay[e.date, default: 0] += e.amount }
    var points = [ForecastPoint(date: today, value: roundTo(start, 2))]
    var v = start
    for i in 1...max(1, days) {
        let d = Day.shift(today, i)
        v += (byDay[d] ?? 0) - daily
        points.append(ForecastPoint(date: d, value: roundTo(v, 2)))
    }
    return Forecast(today: today, currency: base, accounts: liquid, start: roundTo(start, 2), points: points,
                    events: events, dailySpend: daily, cardsWithoutCycle: noCycle)
}

func daysBetween(_ a: String, _ b: String) -> Int {
    guard let x = Day.date(a), let y = Day.date(b) else { return 0 }
    return Int((y.timeIntervalSince(x) / 86400).rounded())
}
