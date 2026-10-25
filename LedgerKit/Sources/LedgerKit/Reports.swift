import Foundation

// Fava-style statements: income statement, balance sheet, trial balance.

public final class AccountNode: Identifiable {
    public let name: String            // full account name ("Expenses:Food")
    public var children: [AccountNode] = []
    /// own postings plus all descendants, by currency
    public var balance = Inventory()
    /// balance converted to the operating currency
    public var total = 0.0
    /// the balance as the report shows it (see `ReportMode`): units, at cost, at market value or converted
    public var shown = Inventory()
    public var id: String { name }
    public var label: String { leaf(name) }
    public var depth: Int { name.components(separatedBy: ":").count - 1 }
    init(_ name: String) { self.name = name }
}

/// postings summed per account for dates in [from, to] (either end open)
/// `only`: just these currencies (every one when nil)
public func periodBalances(_ L: Ledger, from: String? = nil, to: String? = nil, only: Set<String>? = nil) -> [String: Inventory] {
    var out: [String: Inventory] = [:]
    for t in L.txns {
        if let f = from, t.date < f { continue }
        if let e = to, t.date > e { break }
        for p in t.postings {
            guard let u = p.units, let c = p.currency, only?.contains(c) ?? true else { continue }
            out[p.account, default: Inventory()].add(u, c)
        }
    }
    return out
}

/// build the account tree under `root` ("Assets", "Income", …); totals converted at `date`
/// `shown`: the same balances valued for display (`valuedBalances`); the units themselves when nil
public func accountTree(_ balances: [String: Inventory], root: String, _ L: Ledger, at date: String? = nil,
                        shown: [String: Inventory]? = nil) -> AccountNode {
    let top = AccountNode(root)
    var index: [String: AccountNode] = [root: top]
    for (acct, inv) in balances where acct == root || acct.hasPrefix(root + ":") {
        if inv.isEmpty { continue }
        let parts = acct.components(separatedBy: ":")
        var path = parts[0]
        var node = top
        for p in parts.dropFirst() {
            path += ":" + p
            if let n = index[path] { node = n } else {
                let n = AccountNode(path)
                node.children.append(n)
                index[path] = n
                node = n
            }
        }
        // add to this node and every ancestor
        var cur = acct
        while true {
            if let n = index[cur] {
                for (c, x) in inv.nonZero { n.balance.add(x, c) }
                for (c, x) in (shown?[acct] ?? inv).nonZero { n.shown.add(x, c) }
            }
            guard let r = cur.range(of: ":", options: .backwards) else { break }
            cur = String(cur[..<r.lowerBound])
        }
    }
    func finish(_ n: AccountNode) {
        n.total = n.balance.nonZero.reduce(0.0) { $0 + (toCNY(L, $1.1, $1.0, date) ?? 0) }
        n.children.forEach(finish)
        n.children.sort { abs($0.total) != abs($1.total) ? abs($0.total) > abs($1.total) : $0.name < $1.name }
        n.children.removeAll { $0.balance.isEmpty && $0.children.isEmpty }
    }
    finish(top)
    return top
}

// MARK: - by currency (Fava's default): amounts as booked, each currency balancing on its own

public struct CurrencyAmount: Identifiable, Equatable {
    public let currency: String
    public let amount: Double
    public var id: String { currency }
    public init(_ currency: String, _ amount: Double) { self.currency = currency; self.amount = amount }
}

extension Inventory {
    /// the operating currency first, then the others by name; amounts that round to nothing left out
    public func byCurrency(base: String, digits: Double = 0.005) -> [CurrencyAmount] {
        amounts.filter { abs($0.value) >= digits }
            .sorted { a, b in a.key == base ? b.key != base : b.key == base ? false : a.key < b.key }
            .map { CurrencyAmount($0.key, $0.value) }
    }

    public static func + (a: Inventory, b: Inventory) -> Inventory {
        var x = a
        for c in b.order { x.add(b.amounts[c] ?? 0, c) }
        return x
    }

    public static prefix func - (a: Inventory) -> Inventory {
        var x = Inventory()
        for c in a.order { x.add(-(a.amounts[c] ?? 0), c) }
        return x
    }
}

/// How the statements value each balance, as Fava's conversion menu:
/// - units: as booked, each currency on its own (shares as a number of shares)
/// - cost: what is held at cost at that cost, in the cost currency (10 AAPL {80 USD} → 800 USD); the rest as units
/// - market: what is held at cost at its price on the date, in the cost currency; the rest as units
/// - convert: everything in one currency at the date's rates (what has no rate stays as it is)
public enum ReportMode: Hashable {
    case units, cost, market
    case convert(String)

    public init(raw: String) {
        switch raw {
        case "cost": self = .cost
        case "market": self = .market
        default:
            if raw.hasPrefix("to:"), raw.count > 3 { self = .convert(String(raw.dropFirst(3))) } else { self = .units }
        }
    }

    public var raw: String {
        switch self {
        case .units: return "units"
        case .cost: return "cost"
        case .market: return "market"
        case .convert(let c): return "to:" + c
        }
    }

    public var converted: String? { if case .convert(let c) = self { return c }; return nil }
}

/// the commodities held at cost and the currency of that cost (AAPL → USD), from the latest such posting
func costCurrencies(_ L: Ledger) -> [String: String] {
    L.memoized("costCurrencies") { findCostCurrencies(L) }
}

func findCostCurrencies(_ L: Ledger) -> [String: String] {
    var out: [String: String] = [:]
    for t in L.txns {
        for p in t.postings { if let c = p.currency, let cc = p.cost?.currency, cc != c { out[c] = cc } }
    }
    return out
}

/// `periodBalances` valued for the report (see `ReportMode`), at `to` (the latest prices when nil)
public func valuedBalances(_ L: Ledger, from: String? = nil, to: String? = nil, mode: ReportMode, only: Set<String>? = nil) -> [String: Inventory] {
    var raw: [String: Inventory]
    if mode == .cost {
        raw = [:]
        for t in L.txns {
            if let f = from, t.date < f { continue }
            if let e = to, t.date > e { break }
            for p in t.postings {
                guard let c = p.currency, only?.contains(c) ?? true, let a = postingAmount(p, mode) else { continue }
                raw[p.account, default: Inventory()].add(a.0, a.1)
            }
        }
        return raw
    }
    raw = periodBalances(L, from: from, to: to, only: only)
    if mode == .units { return raw }
    let at = to ?? Day.today()
    return raw.mapValues { valueInventory($0, mode, L, at: at) }
}

/// Equity:Conversions as Fava shows it: what makes every currency balance by itself. A transaction balances at
/// its price (100 USD @ 7.1 CNY), so its units don't net to zero per currency; this is the negated sum of every
/// account's balance. Valued at market or converted, it also holds the change in prices and rates since booking.
public func conversions(of balances: [String: Inventory]) -> Inventory {
    var sum = Inventory()
    for inv in balances.values { for (c, n) in inv.nonZero { sum.add(n, c) } }
    var out = Inventory()
    for c in sum.order.sorted() { let v = roundTo(sum.amounts[c] ?? 0, 6); if abs(v) >= 0.000_001 { out.add(-v, c) } }
    return out
}

public func conversions(_ L: Ledger, to date: String?) -> Inventory { conversions(of: periodBalances(L, to: date)) }

public struct IncomeStatement {
    public let income: AccountNode
    public let expenses: AccountNode
    /// positive = profit (income is negative in Beancount)
    public var net: Double { -(income.total + expenses.total) }
}

public func incomeStatement(_ L: Ledger, from: String?, to: String?, mode: ReportMode = .units, only: Set<String>? = nil) -> IncomeStatement {
    let b = periodBalances(L, from: from, to: to, only: only)
    let v = mode == .units ? nil : valuedBalances(L, from: from, to: to, mode: mode, only: only)
    return IncomeStatement(income: accountTree(b, root: "Income", L, at: to, shown: v),
                           expenses: accountTree(b, root: "Expenses", L, at: to, shown: v))
}

public struct BalanceSheet {
    public let assets: AccountNode
    public let liabilities: AccountNode
    public let equity: AccountNode
    /// income and expenses not yet closed into equity (Fava shows this as Equity:Earnings)
    public let earnings: Double
    /// the same, by currency (raw signs: a profit is negative)
    public var earningsByCurrency = Inventory()
    /// Equity:Conversions, by currency (see `conversions`)
    public var conversions = Inventory()
    /// what the equity section comes to, by currency, as shown (credit negative): equity + earnings + conversions
    public var equityByCurrency: Inventory { equity.shown + earningsByCurrency + conversions }
    public var netWorth: Double { assets.total + liabilities.total }
    /// net worth as shown (by the report's mode), by currency
    public var netWorthShown: Inventory { assets.shown + liabilities.shown }
}

/// `account` is one of `list` or under one of them
public func isExcluded(_ account: String, _ list: [String]) -> Bool {
    list.contains { account == $0 || account.hasPrefix($0 + ":") }
}

/// `exclude`: asset and liability accounts left out (and so out of the totals; the sheet no longer balances by them)
/// `mode`: how the accounts are shown (their `shown`); totals in the operating currency stay as they are.
/// The conversions come from every account, left out or not.
public func balanceSheet(_ L: Ledger, at date: String?, exclude: [String] = [], mode: ReportMode = .units,
                         only: Set<String>? = nil) -> BalanceSheet {
    var b = periodBalances(L, to: date, only: only)
    let all = mode == .units ? b : valuedBalances(L, to: date, mode: mode, only: only)
    var v = all
    if !exclude.isEmpty {
        b = b.filter { !isExcluded($0.key, exclude) }
        v = v.filter { !isExcluded($0.key, exclude) }
    }
    let inc = accountTree(b, root: "Income", L, at: date, shown: v), exp = accountTree(b, root: "Expenses", L, at: date, shown: v)
    var s = BalanceSheet(assets: accountTree(b, root: "Assets", L, at: date, shown: v),
                         liabilities: accountTree(b, root: "Liabilities", L, at: date, shown: v),
                         equity: accountTree(b, root: "Equity", L, at: date, shown: v),
                         earnings: inc.total + exp.total)
    s.earningsByCurrency = inc.shown + exp.shown
    s.conversions = conversions(of: all)
    return s
}

public struct NetWorthPoint: Identifiable {
    public var id: String { month }
    public let month: String
    public let assets: Double
    public let liabilities: Double
    public var netWorth: Double { assets + liabilities }
    public init(month: String, assets: Double, liabilities: Double) {
        self.month = month; self.assets = assets; self.liabilities = liabilities
    }
}

/// assets and liabilities now, in the operating currency, without the accounts in `exclude`
public func netWorthNow(_ L: Ledger, exclude: [String] = []) -> (assets: Double, liabilities: Double) {
    var a = 0.0, l = 0.0
    for (acct, cs) in L.final where !isExcluded(acct, exclude) {
        let isA = acct.hasPrefix("Assets:"), isL = acct.hasPrefix("Liabilities:")
        guard isA || isL else { continue }
        for (c, n) in cs { let v = toCNY(L, n, c) ?? 0; if isA { a += v } else { l += v } }
    }
    return (a, l)
}

public func netWorthSeries(_ L: Ledger, today: String = Day.today(), exclude: [String] = []) -> [NetWorthPoint] {
    // one ledger is one version: the accounts page asks again on every redraw
    let key = "nw|\(today)|\(exclude.sorted().joined(separator: "\u{1}"))"
    return L.memoized(key) { netWorthSeriesWalk(L, today: today, exclude: exclude) }
}

func netWorthSeriesWalk(_ L: Ledger, today: String, exclude: [String]) -> [NetWorthPoint] {
    guard let first = L.txns.first(where: { !$0.synthetic })?.date else { return [] }
    var out: [NetWorthPoint] = []
    var bal: [String: [String: Double]] = ["Assets": [:], "Liabilities": [:]]
    var m = Day.ym(first)
    let end = Day.ym(today)
    var i = 0
    while m <= end {
        let last = Day.monthEnd(m)
        while i < L.txns.count && L.txns[i].date <= last {
            for p in L.txns[i].postings {
                guard let u = p.units, let c = p.currency else { continue }
                let root = p.account.components(separatedBy: ":")[0]
                if (root == "Assets" || root == "Liabilities") && !isExcluded(p.account, exclude) { bal[root]![c, default: 0] += u }
            }
            i += 1
        }
        let at = last > today ? today : last
        func sum(_ k: String) -> Double { bal[k]!.reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key, at) ?? 0) } }
        out.append(NetWorthPoint(month: m, assets: sum("Assets"), liabilities: sum("Liabilities")))
        m = Day.addMonth(m, 1)
    }
    return out
}

/// 净资产 now against the end of last month (the accounts left out of it left out), in the operating currency;
/// nil while the ledger has no month before this one
public func netWorthSinceLastMonth(_ L: Ledger, today: String = Day.today(), exclude: [String] = []) -> Double? {
    let s = netWorthSeries(L, today: today, exclude: exclude)
    guard s.count >= 2 else { return nil }
    return s[s.count - 1].netWorth - s[s.count - 2].netWorth
}

/// A year's income and spending by the month, and its spending against the same days of the year before
public struct YearPace: Equatable {
    /// a month's spending, and what was left of the income, on average over the months gone (this one counted)
    public let monthlySpent: Double
    public let monthlySaved: Double
    /// spending against the same days of the year before, as a fraction (0.12 for 12% more); nil when the ledger
    /// does not go back to that year's January or nothing was spent then
    public let spentChange: Double?
}

/// Income and expense categories for `year` (the first two account segments), in the operating currency.
/// A posting with units but no currency is read as CNY — the accounts page has always done that.
public func ytdCategories(_ L: Ledger, year: String) -> [(account: String, amount: Double)] {
    var m: [String: Double] = [:]
    for t in L.txns where t.date.hasPrefix(year) {
        for p in t.postings where p.units != nil && (p.account.hasPrefix("Income:") || p.account.hasPrefix("Expenses:")) {
            m[catOf(p.account), default: 0] += toCNY(L, p.units!, p.currency ?? "CNY", t.date) ?? 0
        }
    }
    return m.sorted { abs($0.value) > abs($1.value) }.map { ($0.key, $0.value) }
}

/// `year` up to `today` (a past year whole), in the operating currency
public func yearPace(_ L: Ledger, year: String, today: String = Day.today()) -> YearPace {
    let thisYear = String(today.prefix(4))
    let end = year < thisYear ? year + "-12-31" : today
    let months = year < thisYear ? 12 : year == thisYear ? Int(today.dropFirst(5).prefix(2)) ?? 12 : 0
    func flows(_ from: String, _ to: String) -> (income: Double, spent: Double) {
        var income = 0.0, spent = 0.0
        for t in L.txns where t.date >= from && t.date <= to {
            for p in t.postings {
                guard let u = p.units else { continue }
                let v = toCNY(L, u, p.currency ?? L.base, t.date) ?? 0
                if p.account.hasPrefix("Income:") { income -= v } else if p.account.hasPrefix("Expenses:") { spent += v }
            }
        }
        return (income, spent)
    }
    let now = flows(year + "-01-01", end)
    let prev = String((Int(year) ?? 0) - 1)
    // the same days: to the same date of the year before (29 February to the 28th)
    var prevEnd = prev + end.dropFirst(4)
    if prevEnd.hasSuffix("-02-29") { prevEnd = prev + "-02-28" }
    let first = L.txns.first { !$0.synthetic }?.date ?? "9999"
    let before = first < prev + "-02-01" ? flows(prev + "-01-01", prevEnd).spent : 0
    return YearPace(monthlySpent: months > 0 ? now.spent / Double(months) : 0,
                    monthlySaved: months > 0 ? (now.income - now.spent) / Double(months) : 0,
                    spentChange: before > 0.005 ? (now.spent - before) / before : nil)
}

/// `n` of one currency in another at `date`'s rates (through the operating currency); nil without a rate
public func convertAmount(_ L: Ledger, _ n: Double, from: String, to: String, date: String) -> Double? {
    convert(L, n, from, to, date)
}
