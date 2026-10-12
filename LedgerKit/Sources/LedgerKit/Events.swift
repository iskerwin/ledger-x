import Foundation

// MARK: - events: a trip, a project, a move — every transaction of it carries the same #tag
//
//   2026-08-03 custom "event" "zhengzhou-2026" "郑州出差"               ; ongoing
//   2026-08-03 custom "event" "zhengzhou-2026" "郑州出差" 2026-08-31    ; ended on the 31st
//
// One directive per event: the tag, a title, and the last day once it is over. Tags used on transactions
// without a directive show up as events too (from their first to their last transaction).

/// tags the app itself uses for other things
public let systemTags: Set<String> = ["reimbursed", "reimbursement", "refund", "transfer", "fx"]

public struct LedgerEvent: Identifiable, Equatable {
    public let tag: String
    public let title: String
    public let start: String
    /// the last day; nil while it goes on
    public let end: String?
    /// the custom directive, when there is one
    public let entry: Entry?
    public var id: String { tag }
    public func covers(_ date: String) -> Bool { date >= start && (end.map { date <= $0 } ?? true) }
    public func ongoing(_ today: String = Day.today()) -> Bool { covers(today) }
    public static func == (a: LedgerEvent, b: LedgerEvent) -> Bool { a.tag == b.tag && a.title == b.title && a.start == b.start && a.end == b.end }
}

/// a tag Beancount accepts
public func isValidTag(_ t: String) -> Bool { t.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-_/.]*$"#, options: .regularExpression) != nil }

/// a tag for a new event: "郑州出差" in 2026 → "zhengzhouchuchai-2026"
public func eventTag(_ title: String, year: String, taken: Set<String> = []) -> String {
    let slug = linkSlug(title, max: 20)
    return uniqueLink(slug.isEmpty ? "event-\(year)" : "\(slug)-\(year)", taken: taken)
}

/// every event: the declared ones and the tags in use, ongoing first, then the latest first
public func ledgerEvents(_ L: Ledger, today: String = Day.today()) -> [LedgerEvent] {
    var out: [String: LedgerEvent] = [:]
    for e in L.entries where e.type == .custom && e.name == "event" {
        guard case .string(let tag)? = e.values.first, !tag.isEmpty else { continue }
        var title = tag, end: String? = nil
        for v in e.values.dropFirst() {
            switch v {
            case .string(let s): title = s
            case .date(let d): end = d
            default: break
            }
        }
        // the latest directive for a tag wins (an edit that was appended rather than replaced)
        if let o = out[tag], let oe = o.entry, oe.date > e.date { continue }
        out[tag] = LedgerEvent(tag: tag, title: title, start: e.date, end: end, entry: e)
    }
    var first: [String: String] = [:], last: [String: String] = [:]
    for t in L.txns {
        for g in t.tags where !systemTags.contains(g) && out[g] == nil {
            if first[g] == nil || t.date < first[g]! { first[g] = t.date }
            if last[g] == nil || t.date > last[g]! { last[g] = t.date }
        }
    }
    for (g, f) in first { out[g] = LedgerEvent(tag: g, title: g, start: f, end: last[g], entry: nil) }
    return out.values.sorted { a, b in
        let ao = a.ongoing(today), bo = b.ongoing(today)
        if ao != bo { return ao }
        return a.start != b.start ? a.start > b.start : a.tag < b.tag
    }
}

/// the declared events covering `date` (new entries on that day get their tags)
public func activeEvents(_ L: Ledger, on date: String) -> [LedgerEvent] {
    ledgerEvents(L, today: date).filter { $0.entry != nil && $0.covers(date) }
}

public struct EventSummary {
    /// its transactions, newest first
    public let txns: [Entry]
    /// spent on expenses (refunds taken off), in the base currency
    public let spent: Double
    /// paid for the company (reimbursement advances)
    public let advanced: Double
    /// of those, not paid back yet (no reimbursement link, or one still open)
    public let unpaid: Double
    /// expenses by category group, largest first
    public let byCategory: [(account: String, amount: Double)]
    public let first: String?
    public let last: String?
    public var total: Double { spent + advanced }
}

public func eventSummary(_ L: Ledger, _ tag: String, reimbursement: String = "Assets:Receivable:Reimbursement", openLinks: Set<String> = []) -> EventSummary {
    let ts = L.txns.filter { $0.tags.contains(tag) }
    var spent = 0.0, adv = 0.0, unpaid = 0.0
    var cats: [String: Double] = [:]
    for t in ts {
        // covered by petty cash counts as paid back
        let claim = t.links.first { $0.hasPrefix("reimburse") || isFloatLink($0) }
        for p in t.postings {
            let v = toCNY(L, p.units ?? 0, p.currency ?? L.base, t.date) ?? 0
            if p.account.hasPrefix("Expenses:") {
                spent += v
                cats[catOf(p.account), default: 0] += v
            } else if p.account == reimbursement && v > 0 {
                adv += v
                if claim == nil || (!isFloatLink(claim!) && openLinks.contains(claim!)) { unpaid += v }
            }
        }
    }
    let byCat = cats.filter { abs($0.value) > 0.005 }.sorted { $0.value > $1.value }.map { (account: $0.key, amount: roundTo($0.value, 2)) }
    return EventSummary(txns: ts.reversed(), spent: roundTo(spent, 2), advanced: roundTo(adv, 2), unpaid: roundTo(unpaid, 2),
                        byCategory: byCat, first: ts.first?.date, last: ts.last?.date)
}

/// transactions in the event's days that don't carry its tag yet (transfers left out), oldest first
public func eventCandidates(_ L: Ledger, _ ev: LedgerEvent, today: String = Day.today()) -> [Entry] {
    let end = ev.end ?? today
    return L.txns.filter { t in
        t.date >= ev.start && t.date <= end && !t.tags.contains(ev.tag) && !t.tags.contains("transfer")
            && t.postings.contains { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Assets:Receivable") || $0.account.hasPrefix("Income:") }
    }
}

/// the directive for an event
public func eventLine(tag: String, title: String, start: String, end: String?) -> String {
    var s = "\(start) custom \"event\" \(quoted(tag)) \(quoted(title))"
    if let e = end { s += " \(e)" }
    return s
}
