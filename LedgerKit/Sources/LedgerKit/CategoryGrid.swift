import Foundation

// MARK: - 记一笔的分类宫格: the open categories under Expenses: or Income:, one cell per group (the second level,
// Expenses:Food), its accounts as the sub-choices

public struct CategoryGroup: Identifiable, Equatable {
    /// the group's account: Expenses:Food (a group of one may be the account itself, Expenses:Travel)
    public let id: String
    /// the open accounts in it, the most used first
    public let accounts: [String]
    /// how much it is used (the weighted count over its accounts)
    public let use: Double
    /// a group of one account: picking the cell picks that account
    public var single: Bool { accounts.count == 1 }
}

/// The open categories under `root` ("Expenses:" or "Income:") as groups, the most used first.
public func categoryGroups(_ D: Derived, root: String) -> [CategoryGroup] {
    var by: [String: [String]] = [:], order: [String] = []
    for a in D.openAccounts where a.hasPrefix(root) {
        let g = catOf(a)
        if by[g] == nil { order.append(g) }
        by[g, default: []].append(a)
    }
    let groups = order.map { g -> CategoryGroup in
        let accts = by[g]!.sorted { a, b in
            let ua = D.acctUse[a] ?? 0, ub = D.acctUse[b] ?? 0
            return ua != ub ? ua > ub : a < b
        }
        return CategoryGroup(id: g, accounts: accts, use: accts.reduce(0) { $0 + (D.acctUse[$1] ?? 0) })
    }
    return groups.sorted { $0.use != $1.use ? $0.use > $1.use : $0.id < $1.id }
}

/// The groups in a saved order: the ones in `saved` first, as saved, then any new ones by use.
public func orderedGroups(_ groups: [CategoryGroup], saved: [String]) -> [CategoryGroup] {
    let at = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let known = groups.filter { at[$0.id] != nil }.sorted { at[$0.id]! < at[$1.id]! }
    return known + groups.filter { at[$0.id] == nil }
}

/// The account each group under `root` was last used with (in the newest transaction that has one), for picking a
/// group with one tap.
public func lastUsedInGroups(_ L: Ledger, root: String) -> [String: String] {
    // once per ledger: the 记一笔 card asks on every tap
    L.memoized("lastUsedInGroups:" + root) { lastUsed(L, root: root) }
}

private func lastUsed(_ L: Ledger, root: String) -> [String: String] {
    var out: [String: String] = [:]
    for t in L.txns.reversed() where !t.synthetic {
        for p in t.postings where p.account.hasPrefix(root) {
            let g = catOf(p.account)
            if out[g] == nil { out[g] = p.account }
        }
        // the advances of a reimbursable expense remember the category they would have been
        for p in t.postings {
            if let c = advanceCategory(p), c.hasPrefix(root), out[catOf(c)] == nil { out[catOf(c)] = c }
        }
    }
    return out
}

/// A default SF Symbol for a category, from the English names in the account: the most specific part that is
/// known decides ("Expenses:Transit:Fuel" is a fuel pump, "Expenses:Transit:Other" a car).
public func defaultCategoryIcon(_ account: String) -> String {
    let parts = account.components(separatedBy: ":").dropFirst()
    let income = account.hasPrefix("Income:")
    for p in parts.reversed() {
        let k = p.lowercased()
        if income, let s = INCOME_ICONS[k] { return s }
        if let s = CATEGORY_ICONS[k] { return s }
    }
    return income ? "yensign.circle" : "square.grid.2x2"
}

/// symbols every iOS 17 has; keys are lowercase English account names
let CATEGORY_ICONS: [String: String] = [
    // food
    "food": "fork.knife", "dining": "fork.knife", "restaurant": "fork.knife", "drinks": "cup.and.saucer", "coffee": "cup.and.saucer",
    "takeaway": "takeoutbag.and.cup.and.straw", "delivery": "takeoutbag.and.cup.and.straw", "groceries": "cart", "grocery": "cart",
    "convenience": "basket", "snacks": "basket", "alcohol": "wineglass",
    // home
    "housing": "house", "home": "house", "rent": "key", "mortgage": "key", "utilities": "bolt", "family": "figure.2.and.child.holdinghands",
    "furniture": "sofa", "repair": "hammer",
    // getting around
    "transit": "car", "transport": "car", "transportation": "car", "taxi": "car", "fuel": "fuelpump", "gas": "fuelpump",
    "tolls": "road.lanes", "toll": "road.lanes", "public": "bus", "bus": "bus", "metro": "tram", "train": "tram",
    "vehicle": "wrench.and.screwdriver", "car": "car", "parking": "parkingsign", "shipping": "shippingbox", "insurance": "shield",
    "travel": "airplane", "flights": "airplane", "hotel": "bed.double",
    // shopping
    "shopping": "bag", "clothing": "tshirt", "clothes": "tshirt", "personal": "hands.sparkles", "household": "basket",
    "electronics": "desktopcomputer", "books": "book",
    // services
    "digital": "app.badge", "subscription": "app.badge", "software": "app.badge", "cloud": "icloud",
    "gifts": "gift", "presents": "gift", "redpacket": "envelope", "charity": "heart",
    "lifestyle": "sparkles", "tobacco": "flame", "entertainment": "gamecontroller", "communication": "antenna.radiowaves.left.and.right",
    "phone": "iphone", "education": "graduationcap", "learning": "graduationcap", "sports": "figure.run", "fitness": "figure.run",
    "pets": "pawprint", "beauty": "comb",
    "government": "building.columns", "tax": "building.columns", "taxes": "building.columns",
    "healthcare": "cross.case", "health": "cross.case", "medical": "stethoscope", "pharmacy": "pills",
    "fee": "creditcard", "fees": "creditcard", "bank": "creditcard", "interest": "percent", "brokerage": "chart.line.uptrend.xyaxis",
    "miscellaneous": "ellipsis.circle", "misc": "ellipsis.circle", "other": "ellipsis.circle",
]

let INCOME_ICONS: [String: String] = [
    "salary": "briefcase", "base": "briefcase", "performance": "chart.bar", "bonus": "star", "allowance": "ticket",
    "deduction": "minus.circle", "severance": "door.left.hand.open",
    "freelance": "person.crop.rectangle", "invest": "chart.line.uptrend.xyaxis", "gain": "chart.line.uptrend.xyaxis",
    "interest": "percent", "dividend": "chart.pie", "stockaward": "rosette",
    "government": "building.columns", "unemployment": "building.columns", "medicalinsurance": "cross.case",
    "rewards": "giftcard", "gifts": "envelope", "sale": "arrow.3.trianglepath", "reimbexcess": "arrow.left.arrow.right",
]
