import Foundation

/// a month an account moved in: what moved, and what it held at the month's end
public struct AccountMonth: Identifiable {
    public let month: String
    public let change: Inventory
    public let end: Inventory
    public var id: String { month }
}

/// each month `account` and those under it moved in, the latest first, as Fava's account changes and balances; worked
/// out once for the ledger
public func accountMonths(_ L: Ledger, account: String) -> [AccountMonth] {
    L.memoized("accountMonths|" + account) {
        var out: [AccountMonth] = []
        var month: String?, change = Inventory(), held = Inventory()
        for t in L.txns {
            let lines = t.postings.filter { isExcluded($0.account, [account]) }
            guard !lines.isEmpty else { continue }
            let m = Day.ym(t.date)
            if let open = month, open != m {
                out.append(AccountMonth(month: open, change: change, end: held))
                change = Inventory()
            }
            month = m
            for p in lines {
                guard let u = p.units, let c = p.currency else { continue }
                change.add(u, c)
                held.add(u, c)
            }
        }
        if let month { out.append(AccountMonth(month: month, change: change, end: held)) }
        return out.reversed()
    }
}

/// accounts with a figure for each of several months, as Fava's changes and balances tables: what moved in the month,
/// or what was held at its end. The shape takes in every account of every month
public struct MonthColumns {
    /// oldest first
    public let months: [String]
    public let roots: [AccountNode]
    /// month → account → total in the operating currency, each account with what's under it
    let values: [String: [String: Double]]

    public func value(_ account: String, _ month: String) -> Double { values[month]?[account] ?? 0 }
}

/// `months` oldest first; `held`: what the accounts held at each month's end, else what moved in each month
public func monthColumns(_ L: Ledger, months: [String], roots: [String], held: Bool) -> MonthColumns {
    L.memoized("monthColumns|\(held)|\(roots.joined(separator: ","))|\(months.joined(separator: ","))") {
        guard let first = months.first, let last = months.last else { return MonthColumns(months: [], roots: [], values: [:]) }
        func balances(_ from: String, _ to: String) -> [String: Inventory] {
            held ? periodBalances(L, to: Day.monthEnd(to)) : periodBalances(L, from: from + "-01", to: Day.monthEnd(to))
        }
        func flatten(_ node: AccountNode, into out: inout [String: Double]) {
            out[node.name] = node.total
            for child in node.children { flatten(child, into: &out) }
        }
        let whole = balances(first, last)
        let shape = roots.map { accountTree(whole, root: $0, L, at: Day.monthEnd(last)) }
        var values: [String: [String: Double]] = [:]
        for month in months {
            let part = balances(month, month)
            var flat: [String: Double] = [:]
            for root in roots { flatten(accountTree(part, root: root, L, at: Day.monthEnd(month)), into: &flat) }
            values[month] = flat
        }
        return MonthColumns(months: months, roots: shape, values: values)
    }
}
