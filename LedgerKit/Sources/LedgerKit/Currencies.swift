import Foundation

// 币种与换算 (as Fava's conversion menu and currency legend): which currencies to look at, and how to value them.
// One setting for the whole app: reports, the overview and the accounts follow it.

/// which currencies are shown and how they are valued
public struct CurrencyView: Equatable, Codable {
    /// how amounts are valued; nil = converted to the operating currency (the default)
    public var modeRaw: String?
    /// switched off by hand (held currencies are on unless switched off)
    public var off: Set<String> = []
    /// switched on by hand (currencies not held are off unless switched on)
    public var on: Set<String> = []

    public init() {}

    public func mode(_ L: Ledger) -> ReportMode { modeRaw.map(ReportMode.init(raw:)) ?? .convert(L.base) }

    /// the currencies switched on: the held ones and those turned on, less those turned off
    public func selected(_ L: Ledger) -> Set<String> {
        heldCurrencies(L).union(on).subtracting(off)
    }

    /// nil when every currency there is counts (nothing filtered out)
    public func only(_ L: Ledger) -> Set<String>? {
        let s = selected(L)
        return Set(ledgerCurrencies(L)).isSubset(of: s) ? nil : s
    }

    public mutating func toggle(_ c: String, _ L: Ledger) {
        let held = heldCurrencies(L).contains(c)
        if selected(L).contains(c) {
            on.remove(c)
            if held { off.insert(c) }
        } else {
            off.remove(c)
            if !held { on.insert(c) }
        }
    }

    /// only `c` (or back to the default when it already was the only one)
    public mutating func solo(_ c: String, _ L: Ledger) {
        if selected(L) == [c] { off = []; on = []; return }
        let all = Set(ledgerCurrencies(L))
        off = all.subtracting([c])
        on = [c]
    }

    /// the default: converted to the operating currency, every held currency
    public var isDefault: Bool { modeRaw == nil && off.isEmpty && on.isEmpty }

    /// "HKD · 原币" for the reminder line; nil when it is the default
    public func label(_ L: Ledger) -> String? {
        let m = mode(L)
        let held = heldCurrencies(L)
        let sel = selected(L)
        let ccys = sel == held ? nil : ledgerCurrencies(L).filter { sel.contains($0) }.joined(separator: " ")
        let modeName: String? = m == .convert(L.base) ? nil : m.name
        if ccys == nil && modeName == nil { return nil }
        return [ccys.map { $0.isEmpty ? tr("未选币种", "No currency") : $0 }, modeName].compactMap { $0 }.joined(separator: " · ")
    }
}

extension ReportMode {
    public var name: String {
        switch self {
        case .units: return tr("原币", "Units")
        case .cost: return tr("按成本", "At cost")
        case .market: return tr("按市值", "At market value")
        case .convert(let c): return tr("折算为 \(c)", "Converted to \(c)")
        }
    }
}

/// every currency and commodity used in the postings: the operating currency first, then what is held
/// (largest first), then the rest by name
public func ledgerCurrencies(_ L: Ledger) -> [String] {
    L.memoized("ledgerCurrencies") { orderedCurrencies(L) }
}

func orderedCurrencies(_ L: Ledger) -> [String] {
    var seen = Set<String>()
    for t in L.txns { for p in t.postings { if let c = p.currency { seen.insert(c) } } }
    let held = heldBalances(L)
    let value: (String) -> Double = { c in abs(toCNY(L, held[c] ?? 0, c) ?? 0) }
    return seen.sorted { a, b in
        if a == L.base || b == L.base { return a == L.base && b != L.base }
        let ha = held[a] != nil, hb = held[b] != nil
        if ha != hb { return ha }
        if ha { let va = value(a), vb = value(b); if abs(va - vb) > 0.005 { return va > vb } }
        return a < b
    }
}

/// what is held of each currency across assets and liabilities now (left out when it comes to nothing)
func heldBalances(_ L: Ledger) -> [String: Double] {
    var sum: [String: Double] = [:]
    for (acct, cs) in L.final where acct.hasPrefix("Assets:") || acct.hasPrefix("Liabilities:") {
        for (c, n) in cs { sum[c, default: 0] += n }
    }
    return sum.filter { abs($0.value) > 0.000_5 }
}

/// currencies with a balance in assets or liabilities now (the ones switched on by default)
public func heldCurrencies(_ L: Ledger) -> Set<String> { L.memoized("heldCurrencies") { Set(heldBalances(L).keys) } }

// MARK: - valuing

/// one posting's amount, at cost when the mode says so (the cost of what is held at cost), else its units
func postingAmount(_ p: Posting, _ mode: ReportMode) -> (Double, String)? {
    guard let u = p.units, let c = p.currency else { return nil }
    if mode == .cost, let n = p.cost?.number, let cc = p.cost?.currency { return (u * n, cc) }
    return (u, c)
}

/// an inventory of units (or costs) valued as the mode says at `date`: at market value or converted;
/// units and costs as they are. What has no rate stays in its own currency.
public func valueInventory(_ inv: Inventory, _ mode: ReportMode, _ L: Ledger, at date: String) -> Inventory {
    switch mode {
    case .units, .cost: return inv
    case .market:
        let quote = costCurrencies(L)
        var x = Inventory()
        for (c, n) in inv.nonZero {
            if let q = quote[c], let v = convert(L, n, c, q, date) { x.add(v, q) } else { x.add(n, c) }
        }
        return x
    case .convert(let target):
        var x = Inventory()
        for (c, n) in inv.nonZero {
            if let v = convert(L, n, c, target, date) { x.add(v, target) } else { x.add(n, c) }
        }
        return x
    }
}

/// the summary figure of an inventory: one amount when it is in one currency, else nil
extension Inventory {
    public func single(base: String) -> CurrencyAmount? {
        let xs = byCurrency(base: base)
        if xs.isEmpty { return CurrencyAmount(base, 0) }
        return xs.count == 1 ? xs[0] : nil
    }
}

// MARK: - net worth over time, by currency

public struct WorthSlice: Identifiable {
    public var id: String { month }
    public let month: String
    /// assets and liabilities of each source currency (what was held), valued as the mode says at the month end
    public let bySource: [String: Inventory]
    /// all of it together
    public var total: Inventory { bySource.values.reduce(Inventory()) { $0 + $1 } }
}

/// month ends from the first entry to `today`: what assets and liabilities (less `exclude`) came to, per source
/// currency in `only` (every currency when nil), valued by `mode`
public func worthSeries(_ L: Ledger, today: String = Day.today(), exclude: [String] = [], mode: ReportMode,
                        only: Set<String>? = nil) -> [WorthSlice] {
    guard let first = L.txns.first(where: { !$0.synthetic })?.date else { return [] }
    var out: [WorthSlice] = []
    var held: [String: Inventory] = [:]     // source → units (or costs)
    var m = Day.ym(first)
    let end = Day.ym(today)
    var i = 0
    while m <= end {
        let last = Day.monthEnd(m)
        while i < L.txns.count && L.txns[i].date <= last {
            for p in L.txns[i].postings {
                guard p.account.hasPrefix("Assets:") || p.account.hasPrefix("Liabilities:"), !isExcluded(p.account, exclude),
                      let c = p.currency, only?.contains(c) ?? true, let a = postingAmount(p, mode) else { continue }
                held[c, default: Inventory()].add(a.0, a.1)
            }
            i += 1
        }
        let at = last > today ? today : last
        var by: [String: Inventory] = [:]
        for (c, inv) in held where !inv.isEmpty { by[c] = valueInventory(inv, mode, L, at: at) }
        out.append(WorthSlice(month: m, bySource: by))
        m = Day.addMonth(m, 1)
    }
    return out
}

// MARK: - income and expenses by month, by currency

public struct MonthFlow {
    /// income shown positive, expenses as they are
    public var income = Inventory()
    public var expenses = Inventory()
}

/// each month's income and expenses in `only` (every currency when nil), valued by `mode` at each entry's date
public func monthlyFlows(_ L: Ledger, months: [String], mode: ReportMode, only: Set<String>? = nil) -> [String: MonthFlow] {
    guard let lo = months.min(), let hi = months.max() else { return [:] }
    var raw: [String: (inc: [String: Inventory], exp: [String: Inventory])] = [:]
    for t in L.txns {
        let m = Day.ym(t.date)
        if m < lo { continue }
        if m > hi { break }
        for p in t.postings {
            let inc = p.account.hasPrefix("Income:"), exp = p.account.hasPrefix("Expenses:")
            guard inc || exp, let c = p.currency, only?.contains(c) ?? true, let a = postingAmount(p, mode) else { continue }
            var one = Inventory(); one.add(inc ? -a.0 : a.0, a.1)
            let v = valueInventory(one, mode, L, at: t.date)
            var r = raw[m] ?? ([:], [:])
            if inc { r.inc[t.date, default: Inventory()] = r.inc[t.date, default: Inventory()] + v }
            else { r.exp[t.date, default: Inventory()] = r.exp[t.date, default: Inventory()] + v }
            raw[m] = r
        }
    }
    var out: [String: MonthFlow] = [:]
    for (m, r) in raw {
        out[m] = MonthFlow(income: r.inc.values.reduce(Inventory()) { $0 + $1 }, expenses: r.exp.values.reduce(Inventory()) { $0 + $1 })
    }
    return out
}

// MARK: - the overview in one currency

/// income, expenses and categories by month, the way `Derived` keeps them, but for the chosen currencies,
/// valued by the mode at each entry's date and taken in one display currency
public struct ViewFlows {
    public var currency: String
    public var monthExp: [String: Double] = [:]
    public var monthInc: [String: Double] = [:]
    /// month → expense account → amount
    public var monthCat: [String: [String: Double]] = [:]
    /// transaction id → what it spent (its expense lines), for ranking payees
    public var txnExp: [Int: Double] = [:]
}

public func viewFlows(_ L: Ledger, mode: ReportMode, only: Set<String>?, currency: String) -> ViewFlows {
    let key = "flows|" + mode.raw + "|" + (only.map { $0.sorted().joined(separator: ",") } ?? "*") + "|" + currency
    return L.memoized(key) {
        var f = ViewFlows(currency: currency)
        for t in L.txns {
            let m = Day.ym(t.date)
            for p in t.postings {
                let inc = p.account.hasPrefix("Income:"), exp = p.account.hasPrefix("Expenses:")
                guard inc || exp, let c = p.currency, only?.contains(c) ?? true, let a = postingAmount(p, mode) else { continue }
                var one = Inventory(); one.add(a.0, a.1)
                guard let v = valueInventory(one, mode, L, at: t.date).amounts[currency], abs(v) > 1e-9 else { continue }
                if exp {
                    f.monthExp[m, default: 0] += v
                    f.monthCat[m, default: [:]][p.account, default: 0] += v
                    if !t.synthetic { f.txnExp[t.id, default: 0] += v }
                } else {
                    f.monthInc[m, default: 0] -= v
                }
            }
        }
        return f
    }
}

/// the currencies amounts end up in for this view (income, expenses and holdings), the operating currency first
public func viewCurrencies(_ L: Ledger, mode: ReportMode, only: Set<String>?) -> [String] {
    if let c = mode.converted { return [c] }
    let key = "viewCurrencies|" + mode.raw + "|" + (only.map { $0.sorted().joined(separator: ",") } ?? "*")
    return L.memoized(key) {
        var size = Inventory()
        for t in L.txns {
            for p in t.postings {
                guard let c = p.currency, only?.contains(c) ?? true, let a = postingAmount(p, mode) else { continue }
                if mode == .market, let q = costCurrencies(L)[c] { size.add(abs(a.0), q) } else { size.add(abs(a.0), a.1) }
            }
        }
        let out = size.byCurrency(base: L.base).map { $0.currency }
        return out.isEmpty ? [L.base] : out
    }
}

/// net worth now for this view (assets and liabilities less `exclude`), by currency
public func netWorthValued(_ L: Ledger, exclude: [String] = [], mode: ReportMode, only: Set<String>?) -> Inventory {
    var inv = Inventory()
    if mode == .cost {
        for (a, x) in valuedBalances(L, mode: .cost, only: only)
            where (a.hasPrefix("Assets:") || a.hasPrefix("Liabilities:")) && !isExcluded(a, exclude) { inv = inv + x }
        return inv
    }
    for (a, cs) in L.final where (a.hasPrefix("Assets:") || a.hasPrefix("Liabilities:")) && !isExcluded(a, exclude) {
        for (c, n) in cs where only?.contains(c) ?? true { inv.add(n, c) }
    }
    return valueInventory(inv, mode, L, at: Day.today())
}
