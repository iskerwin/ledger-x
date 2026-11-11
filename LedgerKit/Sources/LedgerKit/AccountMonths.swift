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
