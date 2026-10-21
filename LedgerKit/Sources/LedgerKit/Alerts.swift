import Foundation

// MARK: - things that look unusual: the same charge twice, a large expense, a category far above its
// usual month, a subscription charged at a new price or after it was stopped

public struct AnomalySettings: Equatable {
    /// a single expense at least this much (base currency) is large; 0 turns it off
    public var large: Double = 2000
    /// how far back to look for duplicates and large expenses
    public var days: Int = 30
    /// a category this many times its usual month, and at least `categoryMin` above it
    public var categoryFactor: Double = 1.5
    public var categoryMin: Double = 300
    public init(large: Double = 2000) { self.large = large }
}

public struct Anomaly: Identifiable, Equatable {
    public enum Kind: String { case duplicate, large, category, subscription }
    public let kind: Kind
    /// stable across reloads, to dismiss it for good
    public let id: String
    public let title: String
    public let detail: String
    public let date: String
    public let entries: [Entry]
    /// the category, or the subscription's name
    public var subject: String? = nil
    public static func == (a: Anomaly, b: Anomaly) -> Bool { a.id == b.id }
}

/// what a transaction looks like apart from where it is in the file: same day, payee, narration and postings
func entrySignature(_ t: Entry) -> String {
    let ps = t.postings.map { "\($0.account) \(numText($0.units ?? 0)) \($0.currency ?? "")" }.sorted().joined(separator: ";")
    return [t.date, t.payee, t.narration, ps].joined(separator: "|")
}

public func anomalies(_ L: Ledger, today: String = Day.today(), settings s: AnomalySettings = AnomalySettings(), subs: [Subscription]? = nil) -> [Anomaly] {
    var out: [Anomaly] = []
    let since = Day.shift(today, -s.days)
    let recent = L.txns.filter { $0.date >= since && $0.date <= today }

    // 1. the same charge recorded (or made) twice
    var groups: [String: [Entry]] = [:], order: [String] = []
    for t in recent where !isTransferTag(t) {
        let k = entrySignature(t)
        if groups[k] == nil { order.append(k) }
        groups[k, default: []].append(t)
    }
    for k in order {
        let g = groups[k]!
        guard g.count > 1 else { continue }
        let c = classify(g[0], L)
        out.append(Anomaly(kind: .duplicate, id: "dup|" + k,
                           title: tr("可能重复：\(g[0].payee.isEmpty ? g[0].narration : g[0].payee)", "Possible duplicate: \(g[0].payee.isEmpty ? g[0].narration : g[0].payee)"),
                           detail: tr("\(g[0].date) 有 \(g.count) 笔完全相同的记录，每笔 \(money(abs(c.amount), c.currency ?? L.base))",
                                      "\(g.count) identical entries on \(g[0].date), \(money(abs(c.amount), c.currency ?? L.base)) each"),
                           date: g[0].date, entries: g))
    }

    // 2. large expenses (your own part: reimbursable advances and others' AA parts aren't expenses)
    if s.large > 0 {
        for t in recent {
            let c = classify(t, L)
            guard c.kind == .expense, -c.amount >= s.large else { continue }
            out.append(Anomaly(kind: .large, id: "large|" + entrySignature(t),
                               title: tr("大额支出：\(t.payee.isEmpty ? t.narration : t.payee)", "Large expense: \(t.payee.isEmpty ? t.narration : t.payee)"),
                               detail: tr("\(t.date) \(money(-c.amount))", "\(money(-c.amount)) on \(t.date)"),
                               date: t.date, entries: [t]))
        }
    }

    // 3. a category this month far above its usual month (the six before; at least three of them with spending)
    let month = Day.ym(today)
    let prev = (1...6).map { Day.addMonth(month, -$0) }
    var byMonth: [String: [String: Double]] = [:]
    let from = prev.last! + "-01"
    for t in L.txns where t.date >= from && t.date <= today {
        let m = Day.ym(t.date)
        for p in t.postings where p.account.hasPrefix("Expenses:") {
            byMonth[m, default: [:]][catOf(p.account), default: 0] += toCNY(L, p.units ?? 0, p.currency ?? L.base, t.date) ?? 0
        }
    }
    for (cat, now) in (byMonth[month] ?? [:]).sorted(by: { $0.key < $1.key }) {
        let hist = prev.map { byMonth[$0]?[cat] ?? 0 }
        guard hist.filter({ $0 > 0.005 }).count >= 3 else { continue }
        let avg = hist.reduce(0, +) / Double(hist.count)
        guard now > avg * s.categoryFactor, now - avg >= s.categoryMin else { continue }
        out.append(Anomaly(kind: .category, id: "cat|\(month)|\(cat)",
                           title: tr("\(catLabel(cat))支出偏高", "\(catLabel(cat)) spending is high"),
                           detail: tr("本月已 \(money(now))，近 6 个月平均每月 \(money(avg))", "\(money(now)) this month so far; \(money(avg)) a month on average over the last six"),
                           date: today, entries: [], subject: cat))
    }

    // 4. subscriptions: charged at a new price, or after being stopped
    for sub in subs ?? subscriptions(L) {
        for a in subscriptionAlerts(sub, today: today) where a.kind == .priceChanged || a.kind == .chargedWhileInactive {
            guard let d = a.date, d >= since else { continue }
            out.append(Anomaly(kind: .subscription, id: "sub|\(sub.name)|\(a.kind.rawValue)|\(d)",
                               title: a.kind == .priceChanged ? tr("订阅调价：\(sub.name)", "Price change: \(sub.name)") : tr("已停的订阅仍在扣费：\(sub.name)", "Stopped subscription charged: \(sub.name)"),
                               detail: a.message, date: d, entries: sub.charges.last.map { [$0.txn] } ?? [], subject: sub.name))
        }
    }
    return out.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
}
