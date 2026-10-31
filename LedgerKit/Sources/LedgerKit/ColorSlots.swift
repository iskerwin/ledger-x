import Foundation

/// The colour a name points to among `count`: the same name, the same colour, on every device and every run.
public func stableColorSlot(_ id: String, count: Int) -> Int {
    var hash: UInt64 = 14695981039346656037
    for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return Int(hash % UInt64(max(count, 1)))
}

/// Which of `count` colours each name gets, taken in the order given: the one its name points to when that is
/// free, else the next free one; once all are taken, the least used from there. A name added at the end never
/// moves one before it.
public func colorSlots(_ ids: [String], count: Int) -> [String: Int] {
    var out: [String: Int] = [:], used = Array(repeating: 0, count: max(count, 1))
    for id in ids where out[id] == nil {
        let start = stableColorSlot(id, count: used.count)
        let fewest = used.min() ?? 0
        let slot = (0..<used.count).map { (start + $0) % used.count }.first { used[$0] == fewest } ?? start
        out[id] = slot
        used[slot] += 1
    }
    return out
}

/// Each income and expense group's colour (Expenses:Food): in the order the groups were opened, closed ones too,
/// so a category keeps its colour from month to month and a new one never takes an older one's.
public func categoryColorSlots(_ L: Ledger, count: Int) -> [String: Int] {
    L.memoized("categoryColorSlots:\(count)") {
        var first: [String: String] = [:]
        for a in L.accounts.values where a.name.hasPrefix("Expenses:") || a.name.hasPrefix("Income:") {
            let g = catOf(a.name), day = a.open ?? ""
            if first[g].map({ day < $0 }) ?? true { first[g] = day }
        }
        let order = first.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
        return colorSlots(order, count: count)
    }
}
