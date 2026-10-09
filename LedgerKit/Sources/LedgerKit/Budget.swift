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
    var by: [String: Budget] = [:]
    for b in budgets(L) where b.date <= date { by[b.account] = b }
    return by.values.filter { $0.amount > 0 }.sorted { $0.account < $1.account }
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
}

private func daysIn(_ from: String, _ to: String) -> Double {
    guard let a = Day.date(from), let b = Day.date(to) else { return 30 }
    return (b.timeIntervalSince(a) / 86400).rounded() + 1
}

/// budgets for a calendar month ("2026-10") or year ("2026")
public func budgetProgress(_ L: Ledger, key: String, today: String = Day.today()) -> [BudgetProgress] {
    let span: BudgetSpan = key.count == 4 ? .year : .month
    let from = span == .year ? key + "-01-01" : key + "-01"
    let to = span == .year ? key + "-12-31" : Day.monthEnd(key)
    let days = daysIn(from, to)
    let elapsed = today < from ? 0 : today > to ? 1 : daysIn(from, today) / days
    var out: [BudgetProgress] = []
    for b in activeBudgets(L, at: min(to, max(from, today))) {
        let limit: Double
        switch (b.period, span) {
        case (.daily, _): limit = b.amount * days
        case (.weekly, _): limit = b.amount * days / 7
        case (.monthly, .month): limit = b.amount
        case (.monthly, .year): limit = b.amount * 12
        case (.quarterly, .month): limit = b.amount / 3
        case (.quarterly, .year): limit = b.amount * 4
        case (.yearly, .month): limit = b.amount / 12
        case (.yearly, .year): limit = b.amount
        }
        var spent = 0.0
        let sign = b.account.hasPrefix("Income") || b.account.hasPrefix("Liabilities") ? -1.0 : 1.0
        for t in L.txns where t.date >= from && t.date <= to {
            for p in t.postings where p.account == b.account || p.account.hasPrefix(b.account + ":") {
                guard let u = p.units, let c = p.currency else { continue }
                if c == b.currency { spent += u * sign }
                else if b.currency == L.base, let v = toCNY(L, u, c, t.date) { spent += v * sign }
            }
        }
        out.append(BudgetProgress(budget: b, limit: roundTo(limit, 2), spent: roundTo(spent, 2), elapsed: elapsed))
    }
    return out.sorted { $0.ratio > $1.ratio }
}

/// the directive line for a budget
public func budgetLine(_ date: String, _ account: String, _ period: BudgetPeriod, _ amount: Double, _ currency: String) -> String {
    let left = "\(date) custom \"budget\" \(account) \"\(period.rawValue)\""
    let ns = toFixed(amount, 2)
    return left + String(repeating: " ", count: max(1, NUM_END + 12 - left.utf16.count - ns.utf16.count)) + ns + " " + currency
}
