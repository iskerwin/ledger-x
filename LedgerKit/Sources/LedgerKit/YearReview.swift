import Foundation

// MARK: - 年度回顾: one year of the ledger on one page
//
// Everything is worked out here from the ledger and only read by the page. Amounts are valued as the report
// mode says (converted to one currency by default, like the overview) at each entry's date, from the same
// figures the overview and the statements use (viewFlows, worthSeries), so the three agree.
// Salary, events, funds and reimbursements are in the operating currency, as their own pages have them.

public struct YearMonthFlow: Identifiable, Equatable {
    public var id: String { month }
    public let month: String
    public let income: Double
    public let expenses: Double
}

public struct YearCategory: Identifiable, Equatable {
    public var id: String { account }
    /// the category group ("Expenses:Food")
    public let account: String
    public let amount: Double
    /// the year before; nil when there was nothing in it
    public let previous: Double?
}

public struct YearPayee: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let amount: Double
    public let count: Int
}

public struct YearEntry: Identifiable {
    public var id: Int { entry.id }
    public let entry: Entry
    /// what it spent (its expense lines)
    public let amount: Double
}

public struct YearEvent: Identifiable {
    public var id: String { event.tag }
    public let event: LedgerEvent
    public let summary: EventSummary
    /// days in the year it lasted (to the end of the year, or today while it goes on)
    public let days: Int
}

/// a fund held with the government (公积金, 养老, 医保): paid in during the year, and what it holds at the end
public struct YearFund: Identifiable, Equatable {
    public var id: String { account }
    public let account: String
    public let paidIn: Double
    public let balance: Double
}

public struct YearReview {
    public let year: String
    /// what the amounts are in (the operating currency unless the view says otherwise)
    public let currency: String
    /// the last day counted: the year's end, or today for the year still going on
    public let through: String

    public var income = 0.0
    public var expenses = 0.0
    public var net: Double { roundTo(income - expenses, 2) }
    /// what was kept of what came in; nil without income
    public var savingsRate: Double? { income > 0.005 ? net / income : nil }
    /// the year before, for the comparison (nil when it has nothing)
    public var previousIncome: Double?
    public var previousExpenses: Double?

    public var months: [YearMonthFlow] = []
    /// net worth at the end of the year before, and at the end of each month of this one
    public var worthStart: Double?
    public var worthByMonth: [(month: String, value: Double)] = []
    public var worthEnd: Double? { worthByMonth.last?.value }
    public var assetsChange = 0.0
    public var liabilitiesChange = 0.0

    public var categories: [YearCategory] = []
    public var biggest: [YearEntry] = []
    public var payees: [YearPayee] = []
    public var events: [YearEvent] = []
    public var salary: SalaryYear?
    public var funds: [YearFund] = []
    /// spent on subscriptions (entries linked ^sub-…, or with subscription:)
    public var subscriptions = 0.0
    /// reimbursements: paid out for the company, paid back, and still owed at the end
    public var advanced = 0.0
    public var reimbursed = 0.0
    public var reimbOwed = 0.0
    /// investment income by account (dividends, interest, realized gains), largest first
    public var investment: [(account: String, amount: Double)] = []

    /// anything to show at all
    public var isEmpty: Bool { income == 0 && expenses == 0 && worthByMonth.isEmpty }
    /// the highest and lowest month of spending (months with none left out)
    public var dearestMonth: YearMonthFlow? { months.filter { $0.expenses > 0 }.max { $0.expenses < $1.expenses } }
    public var cheapestMonth: YearMonthFlow? { months.filter { $0.expenses > 0 }.min { $0.expenses < $1.expenses } }
}

/// the years with entries, latest first
public func reviewYears(_ L: Ledger) -> [String] {
    Set(L.txns.filter { !$0.synthetic }.map { String($0.date.prefix(4)) }).sorted(by: >)
}

/// One year of the ledger. `currency`: what the amounts are shown in (with `.units`, only what is in it counts);
/// `exclude`: accounts left out of net worth (ledger-x.json networth_exclude); `today` ends the current year.
public func yearReview(_ L: Ledger, year: String, mode: ReportMode = .convert("CNY"), currency: String? = nil,
                       only: Set<String>? = nil, exclude: [String] = [], reimbursement: String = "Assets:Receivable:Reimbursement",
                       today: String = Day.today()) -> YearReview {
    let cur = currency ?? mode.converted ?? L.base
    let start = year + "-01-01", yearEnd = year + "-12-31"
    let through = min(yearEnd, today)
    var r = YearReview(year: year, currency: cur, through: through)
    let prevYear = String((Int(year) ?? 0) - 1)
    func inYear(_ d: String) -> Bool { d >= start && d <= through }
    /// one amount in the view's currency at `date`
    func value(_ n: Double, _ c: String, _ date: String) -> Double? {
        var one = Inventory(); one.add(n, c)
        return valueInventory(one, mode, L, at: date).amounts[cur]
    }

    // income and expenses, by month and by category: the overview's own figures
    let f = viewFlows(L, mode: mode, only: only, currency: cur)
    var cats: [String: Double] = [:], prevCats: [String: Double] = [:]
    var prevInc = 0.0, prevExp = 0.0, prevAny = false
    for k in 1...12 {
        let m = year + "-" + (k < 10 ? "0\(k)" : "\(k)")
        if m > Day.ym(through) { break }
        let inc = roundTo(f.monthInc[m] ?? 0, 2), exp = roundTo(f.monthExp[m] ?? 0, 2)
        r.months.append(YearMonthFlow(month: m, income: inc, expenses: exp))
        r.income += inc; r.expenses += exp
        for (a, v) in f.monthCat[m] ?? [:] { cats[catOf(a), default: 0] += v }
        let pm = prevYear + "-" + (k < 10 ? "0\(k)" : "\(k)")
        if f.monthInc[pm] != nil || f.monthExp[pm] != nil { prevAny = true }
        prevInc += f.monthInc[pm] ?? 0; prevExp += f.monthExp[pm] ?? 0
        for (a, v) in f.monthCat[pm] ?? [:] { prevCats[catOf(a), default: 0] += v }
    }
    r.income = roundTo(r.income, 2); r.expenses = roundTo(r.expenses, 2)
    if prevAny { r.previousIncome = roundTo(prevInc, 2); r.previousExpenses = roundTo(prevExp, 2) }
    r.categories = cats.filter { abs($0.value) > 0.005 }.sorted { $0.value > $1.value }.map {
        YearCategory(account: $0.key, amount: roundTo($0.value, 2), previous: prevCats[$0.key].map { roundTo($0, 2) })
    }

    // the entries of the year: the largest expenses, payees, subscriptions
    let ts = L.txns.filter { !$0.synthetic && inYear($0.date) }
    var byPayee: [String: (Double, Int)] = [:]
    var spent: [(Entry, Double)] = []
    for t in ts {
        guard let v = f.txnExp[t.id], v > 0.005 else { continue }
        spent.append((t, v))
        let who = t.payee.trimmingCharacters(in: .whitespaces)
        if !who.isEmpty { let x = byPayee[who] ?? (0, 0); byPayee[who] = (x.0 + v, x.1 + 1) }
        if t.links.contains(where: { $0.hasPrefix("sub-") }) || t.meta["subscription"] != nil { r.subscriptions += v }
    }
    r.subscriptions = roundTo(r.subscriptions, 2)
    r.biggest = spent.sorted { $0.1 > $1.1 }.prefix(5).map { YearEntry(entry: $0.0, amount: roundTo($0.1, 2)) }
    r.payees = byPayee.sorted { $0.value.0 > $1.value.0 }.prefix(10).map { YearPayee(name: $0.key, amount: roundTo($0.value.0, 2), count: $0.value.1) }

    // net worth: the year before's last month end, then each month end of this year
    let slices = worthSeries(L, today: through, exclude: exclude, mode: mode, only: only)
    if let s = slices.last(where: { $0.month < year + "-01" }) { r.worthStart = roundTo(s.total.amounts[cur] ?? 0, 2) }
    r.worthByMonth = slices.filter { $0.month.hasPrefix(year) }.map { (month: $0.month, value: roundTo($0.total.amounts[cur] ?? 0, 2)) }
    if !r.worthByMonth.isEmpty && r.worthStart == nil && slices.first?.month.hasPrefix(year) == true { r.worthStart = 0 }
    // assets and liabilities on their own: the change over the year, each valued at its day
    func side(_ prefix: String, _ date: String) -> Double {
        var inv = Inventory()
        for (a, cs) in balancesAt(L, date) where a.hasPrefix(prefix) && !isExcluded(a, exclude) {
            for (c, n) in cs where only?.contains(c) ?? true { inv.add(n, c) }
        }
        return valueInventory(inv, mode, L, at: date).amounts[cur] ?? 0
    }
    let before = Day.shift(start, -1)
    r.assetsChange = roundTo(side("Assets:", through) - side("Assets:", before), 2)
    r.liabilitiesChange = roundTo(side("Liabilities:", through) - side("Liabilities:", before), 2)

    // events that took place in the year
    for ev in ledgerEvents(L, today: today) where ev.start <= through && (ev.end ?? today) >= start {
        let s = eventSummary(L, ev.tag, reimbursement: reimbursement)
        let from = max(ev.start, start), to = min(ev.end ?? min(today, yearEnd), through)
        r.events.append(YearEvent(event: ev, summary: s, days: max(1, daysBetween(from, to) + 1)))
    }
    r.events.sort { $0.summary.total > $1.summary.total }

    r.salary = salaryYears(L).first { $0.year == year }

    // government funds and reimbursements: what moved in the year, in the operating currency
    var paidIn: [String: Double] = [:]
    for t in ts {
        for p in t.postings {
            guard let u = p.units, let c = p.currency else { continue }
            let v = toCNY(L, u, c, t.date) ?? 0
            if p.account.hasPrefix("Assets:Government:"), v > 0 { paidIn[p.account, default: 0] += v }
            if p.account == reimbursement {
                if v > 0 { r.advanced += v } else { r.reimbursed -= v }
            }
            if p.account.hasPrefix("Income:"), isInvestmentIncome(p.account), let x = value(-u, c, t.date) {
                r.investment.append((p.account, x))
            }
        }
    }
    let endBal = balancesAt(L, through)
    func baseTotal(_ a: String) -> Double { (endBal[a] ?? [:]).reduce(0) { $0 + (toCNY(L, $1.value, $1.key, through) ?? 0) } }
    r.funds = paidIn.keys.sorted().map { YearFund(account: $0, paidIn: roundTo(paidIn[$0]!, 2), balance: roundTo(baseTotal($0), 2)) }
    r.advanced = roundTo(r.advanced, 2); r.reimbursed = roundTo(r.reimbursed, 2)
    r.reimbOwed = roundTo(max(0, baseTotal(reimbursement)), 2)
    var inv: [String: Double] = [:]
    for (a, v) in r.investment { inv[a, default: 0] += v }
    r.investment = inv.filter { abs($0.value) > 0.005 }.sorted { $0.value > $1.value }.map { (account: $0.key, amount: roundTo($0.value, 2)) }
    return r
}

/// `yearReview` kept with this ledger: worked out once per year, view and day (the page draws it many times)
public func yearReviewCached(_ L: Ledger, year: String, mode: ReportMode, currency: String, only: Set<String>?,
                             exclude: [String], reimbursement: String, today: String = Day.today()) -> YearReview {
    let key = ["yearReview", year, mode.raw, currency, only.map { $0.sorted().joined(separator: ",") } ?? "*",
               exclude.joined(separator: ","), reimbursement, today].joined(separator: "|")
    return L.memoized(key) {
        yearReview(L, year: year, mode: mode, currency: currency, only: only, exclude: exclude, reimbursement: reimbursement, today: today)
    }
}

/// income from investments: dividends, interest, gains (by the account's name)
public func isInvestmentIncome(_ a: String) -> Bool {
    let parts = a.components(separatedBy: ":").dropFirst().map { $0.lowercased() }
    return parts.contains { ["invest", "investment", "investments", "dividend", "dividends", "interest", "gain", "gains",
                             "capitalgains", "pnl", "realized"].contains($0) }
}
