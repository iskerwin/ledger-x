import Foundation

// Budgets in Fava's format:  2026-01-01 custom "budget" Expenses:Food "monthly" 2000.00 CNY
// Periods: daily, weekly, monthly, quarterly, yearly. A later entry for the same account replaces the earlier one.

public enum BudgetPeriod: String, CaseIterable, Codable {
    case daily, weekly, monthly, quarterly, yearly
    public var name: String {
        switch self {
        case .daily: return tr("每日", "Daily")
        case .weekly: return tr("每周", "Weekly")
        case .monthly: return tr("每月", "Monthly")
        case .quarterly: return tr("每季", "Quarterly")
        case .yearly: return tr("每年", "Yearly")
        }
    }
}

public struct Budget: Identifiable {
    public var id: String { account + "|" + date + "|" + (entry.map { "\($0.file):\($0.line)" } ?? "") }
    public let account: String
    public let period: BudgetPeriod
    public let amount: Double
    public let currency: String
    public let date: String
    public let entry: Entry?
}

/// every budget directive in the ledger, oldest first
public func budgets(_ L: Ledger) -> [Budget] {
    var out: [Budget] = []
    for e in L.entries where e.type == .custom && e.name == "budget" {
        var account: String?
        var period: BudgetPeriod?
        var amount: (Double, String)?
        for v in e.values {
            switch v {
            case .raw(let a) where account == nil: account = a
            case .string(let s): if let p = BudgetPeriod(rawValue: s.lowercased()) { period = p } else if account == nil, isAccountName(s) { account = s }
            case .amount(let n, let c): amount = (n, c)
            default: break
            }
        }
        if let a = account, let p = period, let m = amount {
            out.append(Budget(account: a, period: p, amount: m.0, currency: m.1, date: e.date, entry: e))
        }
    }
    return out.sorted { $0.date < $1.date }
}

/// the budget in force for each account on a date (zero amounts switch a budget off)
public func activeBudgets(_ L: Ledger, at date: String) -> [Budget] {
    activeBudgets(budgets(L), at: date)
}

func activeBudgets(_ list: [Budget], at date: String) -> [Budget] {
    var by: [String: Budget] = [:]
    for b in list where b.date <= date { by[b.account] = b }
    return by.values.filter { $0.amount > 0 }.sorted { $0.account < $1.account }
}

func budgetLimit(_ b: Budget, span: BudgetSpan, days: Double) -> Double {
    switch (b.period, span) {
    case (.daily, _): return b.amount * days
    case (.weekly, _): return b.amount * days / 7
    case (.monthly, .month): return b.amount
    case (.monthly, .year): return b.amount * 12
    case (.quarterly, .month): return b.amount / 3
    case (.quarterly, .year): return b.amount * 4
    case (.yearly, .month): return b.amount / 12
    case (.yearly, .year): return b.amount
    }
}

struct BudgetWindow {
    var span: BudgetSpan
    var from: String
    var to: String
    var elapsed: Double
    var at: String
    var days: Double
}

func budgetWindow(_ key: String, today: String) -> BudgetWindow {
    let span: BudgetSpan = key.count == 4 ? .year : .month
    let from = span == .year ? key + "-01-01" : key + "-01"
    let to = span == .year ? key + "-12-31" : Day.monthEnd(key)
    let days = daysIn(from, to)
    let elapsed = today < from ? 0 : today > to ? 1 : daysIn(from, today) / days
    return BudgetWindow(span: span, from: from, to: to, elapsed: elapsed, at: min(to, max(from, today)), days: days)
}

func budgetRow(_ b: Budget, window: BudgetWindow, spent: Double, biggest: BudgetSpend?) -> BudgetProgress {
    var progress = BudgetProgress(budget: b, limit: roundTo(budgetLimit(b, span: window.span, days: window.days), 2),
                                  spent: roundTo(spent, 2), elapsed: window.elapsed)
    progress.biggest = biggest
    return progress
}

public enum BudgetSpan { case month, year }

public struct BudgetProgress: Identifiable {
    public var id: String { budget.account }
    public let budget: Budget
    /// the budget scaled to the span (a weekly 100 is ~430 a month)
    public let limit: Double
    public let spent: Double
    /// how far through the span we are (1 for past spans)
    public let elapsed: Double
    public var remaining: Double { limit - spent }
    public var ratio: Double { limit > 0 ? spent / limit : 0 }
    public var over: Bool { spent > limit + 0.005 }
    /// spending faster than the calendar
    public var ahead: Bool { !over && elapsed < 1 && ratio > elapsed + 0.1 }
    /// the biggest transaction in the span, to say what an overspend mostly was
    public var biggest: BudgetSpend? = nil
}

/// one transaction's spending under a budget: its payee (or narration), day and amount in the budget's currency
public struct BudgetSpend: Equatable {
    public let what: String
    public let date: String
    public let amount: Double
}

private func daysIn(_ from: String, _ to: String) -> Double {
    guard let a = Day.date(from), let b = Day.date(to) else { return 30 }
    return (b.timeIntervalSince(a) / 86400).rounded() + 1
}

/// budgets for a calendar month ("2026-10") or year ("2026")
public func budgetProgress(_ L: Ledger, key: String, today: String = Day.today()) -> [BudgetProgress] {
    let window = budgetWindow(key, today: today)
    var out: [BudgetProgress] = []
    for b in activeBudgets(L, at: window.at) {
        var spent = 0.0
        var biggest: BudgetSpend?
        let sign = b.account.hasPrefix("Income") || b.account.hasPrefix("Liabilities") ? -1.0 : 1.0
        for t in L.txns where t.date >= window.from && t.date <= window.to {
            var here = 0.0
            for p in t.postings where p.account == b.account || p.account.hasPrefix(b.account + ":") {
                guard let u = p.units, let c = p.currency else { continue }
                // any other currency converted into the budget's on the day (through the base currency, so a USD
                // budget sees CNY and EUR spending too)
                if let v = convert(L, u, c, b.currency, t.date) { here += v * sign }
            }
            spent += here
            if here > (biggest?.amount ?? 0) {
                biggest = BudgetSpend(what: t.payee.isEmpty ? t.narration : t.payee, date: t.date, amount: roundTo(here, 2))
            }
        }
        out.append(budgetRow(b, window: window, spent: spent, biggest: biggest))
    }
    return out.sorted { $0.ratio > $1.ratio }
}

/// Spending under each budget directive, gathered in one walk of the ledger. A later zero budget still switches
/// the earlier one off. Summing the hits in the order they were booked matches `budgetProgress`.
struct BudgetRollup {
    private struct Hit {
        var date: String
        var amount: Double
        var what: String
    }

    private let all: [Budget]
    private let counted: [Budget]
    private var hits: [[Hit]]
    private let at: [String: [Int]]
    private let idIndex: [String: Int]

    init(_ L: Ledger) {
        all = budgets(L)
        counted = all.filter { $0.amount > 0 }
        hits = Array(repeating: [], count: counted.count)
        var at: [String: [Int]] = [:]
        var idIndex: [String: Int] = [:]
        for (i, b) in counted.enumerated() {
            at[b.account, default: []].append(i)
            idIndex[b.id] = i
        }
        self.at = at
        self.idIndex = idIndex
    }

    private func matching(_ account: String) -> [Int] {
        var ids: [Int] = []
        var name = account
        while true {
            if let found = at[name] { ids.append(contentsOf: found) }
            guard let cut = name.lastIndex(of: ":") else { break }
            name = String(name[..<cut])
        }
        return ids
    }

    mutating func add(_ t: Entry, _ L: Ledger) {
        if at.isEmpty { return }
        var here: [Int: Double] = [:]
        for p in t.postings {
            guard let u = p.units, let c = p.currency else { continue }
            let ids = matching(p.account)
            if ids.isEmpty { continue }
            for i in ids {
                let b = counted[i]
                let sign = b.account.hasPrefix("Income") || b.account.hasPrefix("Liabilities") ? -1.0 : 1.0
                if let v = convert(L, u, c, b.currency, t.date) { here[i, default: 0] += v * sign }
            }
        }
        if here.isEmpty { return }
        let what = t.payee.isEmpty ? t.narration : t.payee
        for (i, amount) in here where amount != 0 {
            hits[i].append(Hit(date: t.date, amount: amount, what: what))
        }
    }

    func progress(key: String, today: String) -> [BudgetProgress] {
        let window = budgetWindow(key, today: today)
        var out: [BudgetProgress] = []
        for b in activeBudgets(all, at: window.at) {
            guard let i = idIndex[b.id] else { continue }
            var spent = 0.0
            var biggest: BudgetSpend?
            for hit in hits[i] where hit.date >= window.from && hit.date <= window.to {
                spent += hit.amount
                if hit.amount > (biggest?.amount ?? 0) {
                    biggest = BudgetSpend(what: hit.what, date: hit.date, amount: roundTo(hit.amount, 2))
                }
            }
            out.append(budgetRow(b, window: window, spent: spent, biggest: biggest))
        }
        return out.sorted { $0.ratio > $1.ratio }
    }
}

/// the directive line for a budget
public func budgetLine(_ date: String, _ account: String, _ period: BudgetPeriod, _ amount: Double, _ currency: String) -> String {
    let left = "\(date) custom \"budget\" \(account) \"\(period.rawValue)\""
    let ns = toFixed(amount, 2)
    return left + String(repeating: " ", count: max(1, NUM_END + 12 - left.utf16.count - ns.utf16.count)) + ns + " " + currency
}
