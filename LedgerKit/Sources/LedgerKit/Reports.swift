import Foundation

// Fava-style statements: income statement, balance sheet, trial balance.

public final class AccountNode: Identifiable {
    public let name: String            // full account name ("Expenses:Food")
    public var children: [AccountNode] = []
    /// own postings plus all descendants, by currency
    public var balance = Inventory()
    /// balance converted to the operating currency
    public var total = 0.0
    public var id: String { name }
    public var label: String { leaf(name) }
    public var depth: Int { name.components(separatedBy: ":").count - 1 }
    public var childrenOrNil: [AccountNode]? { children.isEmpty ? nil : children }
    init(_ name: String) { self.name = name }
}

/// postings summed per account for dates in [from, to] (either end open)
public func periodBalances(_ L: Ledger, from: String? = nil, to: String? = nil) -> [String: Inventory] {
    var out: [String: Inventory] = [:]
    for t in L.txns {
        if let f = from, t.date < f { continue }
        if let e = to, t.date > e { break }
        for p in t.postings {
            guard let u = p.units, let c = p.currency else { continue }
            out[p.account, default: Inventory()].add(u, c)
        }
    }
    return out
}

/// build the account tree under `root` ("Assets", "Income", …); totals converted at `date`
public func accountTree(_ balances: [String: Inventory], root: String, _ L: Ledger, at date: String? = nil) -> AccountNode {
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
            if let n = index[cur] { for (c, x) in inv.nonZero { n.balance.add(x, c) } }
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

public struct IncomeStatement {
    public let income: AccountNode
    public let expenses: AccountNode
    /// positive = profit (income is negative in Beancount)
    public var net: Double { -(income.total + expenses.total) }
}

public func incomeStatement(_ L: Ledger, from: String?, to: String?) -> IncomeStatement {
    let b = periodBalances(L, from: from, to: to)
    return IncomeStatement(income: accountTree(b, root: "Income", L, at: to), expenses: accountTree(b, root: "Expenses", L, at: to))
}

public struct BalanceSheet {
    public let assets: AccountNode
    public let liabilities: AccountNode
    public let equity: AccountNode
    /// income and expenses not yet closed into equity (Fava shows this as Equity:Earnings)
    public let earnings: Double
    public var netWorth: Double { assets.total + liabilities.total }
}

public func balanceSheet(_ L: Ledger, at date: String?) -> BalanceSheet {
    let b = periodBalances(L, to: date)
    let inc = accountTree(b, root: "Income", L, at: date), exp = accountTree(b, root: "Expenses", L, at: date)
    return BalanceSheet(assets: accountTree(b, root: "Assets", L, at: date),
                        liabilities: accountTree(b, root: "Liabilities", L, at: date),
                        equity: accountTree(b, root: "Equity", L, at: date),
                        earnings: inc.total + exp.total)
}

public struct NetWorthPoint: Identifiable {
    public var id: String { month }
    public let month: String
    public let assets: Double
    public let liabilities: Double
    public var netWorth: Double { assets + liabilities }
}

public func netWorthSeries(_ L: Ledger, today: String = Day.today()) -> [NetWorthPoint] {
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
                if root == "Assets" || root == "Liabilities" { bal[root]![c, default: 0] += u }
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
