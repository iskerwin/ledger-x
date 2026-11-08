import Foundation

/// one payee across the ledger
public struct PayeeSummary: Identifiable {
    public let name: String
    public var n = 0
    public var last = ""
    /// your spending with them (base currency)
    public var spent = 0.0
    /// income from them (base currency)
    public var received = 0.0
    public var id: String { name }
}

/// every payee on a transaction header, most used first
public func payeeSummaries(_ L: Ledger) -> [PayeeSummary] {
    var by: [String: PayeeSummary] = [:]
    for t in L.txns where !t.synthetic && !t.payee.isEmpty {
        var s = by[t.payee] ?? PayeeSummary(name: t.payee)
        s.n += 1
        if t.date > s.last { s.last = t.date }
        let c = classify(t, L)
        switch c.kind {
        case .expense, .refund: s.spent -= c.amount
        case .income: s.received += c.amount
        default: break
        }
        by[t.payee] = s
    }
    return by.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }
}
