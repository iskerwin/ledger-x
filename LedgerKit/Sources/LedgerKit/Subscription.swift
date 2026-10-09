import Foundation

// Subscriptions, kept in the ledger as custom directives (Fava shows them, bean-check ignores them):
//
//   2026-01-15 custom "subscription" "iCloud+" "monthly" 21.00 CNY
//     account: "Expenses:Subscription"
//     funding: "Liabilities:CreditCard:CMB"
//     payee: "Apple"
//     next: 2026-06-15        ; optional: the next charge after a free / extended period
//     status: "paused"        ; optional: active (default), paused, cancelled
//
// The date is the first charge. Charges repeat every period from there; when `next` is set they repeat
// from `next` instead, so a gifted extension shifts the cycle once and the original period carries on.
// Payments recorded from the app carry `subscription: "<name>"` metadata.

public enum PeriodUnit: String, CaseIterable, Codable { case day, week, month, year }

public struct SubPeriod: Equatable, Hashable, Codable {
    public var n: Int
    public var unit: PeriodUnit
    public init(_ n: Int, _ unit: PeriodUnit) { self.n = max(1, n); self.unit = unit }

    public static let weekly = SubPeriod(1, .week)
    public static let monthly = SubPeriod(1, .month)
    public static let quarterly = SubPeriod(3, .month)
    public static let halfYearly = SubPeriod(6, .month)
    public static let yearly = SubPeriod(1, .year)
    public static let presets: [SubPeriod] = [.weekly, .monthly, .quarterly, .halfYearly, .yearly]

    /// "monthly", "quarterly", … or "N days|weeks|months|years"
    public static func parse(_ s: String) -> SubPeriod? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        switch t {
        case "daily": return SubPeriod(1, .day)
        case "weekly": return .weekly
        case "biweekly": return SubPeriod(2, .week)
        case "monthly": return .monthly
        case "quarterly": return .quarterly
        case "half-yearly", "halfyearly", "semiannual", "semiannually": return .halfYearly
        case "yearly", "annual", "annually": return .yearly
        default: break
        }
        let parts = t.split(separator: " ").map(String.init)
        guard parts.count == 2, let n = Int(parts[0]), n > 0 else { return nil }
        let u = parts[1].hasSuffix("s") ? String(parts[1].dropLast()) : parts[1]
        guard let unit = PeriodUnit(rawValue: u) else { return nil }
        return SubPeriod(n, unit)
    }

    /// the text written to the ledger
    public var text: String {
        switch self {
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .quarterly: return "quarterly"
        case .halfYearly: return "half-yearly"
        case .yearly: return "yearly"
        default: return "\(n) \(unit.rawValue)\(n > 1 ? "s" : "")"
        }
    }

    public var name: String {
        switch self {
        case .weekly: return tr("每周", "Weekly")
        case .monthly: return tr("每月", "Monthly")
        case .quarterly: return tr("每季度", "Quarterly")
        case .halfYearly: return tr("每半年", "Every 6 months")
        case .yearly: return tr("每年", "Yearly")
        default:
            let zh: String, en: String
            switch unit {
            case .day: zh = "天"; en = "day"
            case .week: zh = "周"; en = "week"
            case .month: zh = "个月"; en = "month"
            case .year: zh = "年"; en = "year"
            }
            return tr("每 \(n) \(zh)", "Every \(n) \(en)\(n > 1 ? "s" : "")")
        }
    }

    /// average length in months, for the monthly / yearly totals
    public var months: Double {
        switch unit {
        case .day: return Double(n) / 30.436875
        case .week: return Double(n) * 7 / 30.436875
        case .month: return Double(n)
        case .year: return Double(n) * 12
        }
    }

    /// `k` periods after `date`; month ends are clamped (Jan 31 → Feb 28 → Mar 31)
    public func add(_ date: String, _ k: Int) -> String {
        switch unit {
        case .day: return Day.shift(date, n * k)
        case .week: return Day.shift(date, 7 * n * k)
        case .month, .year:
            let months = (unit == .year ? 12 : 1) * n * k
            let p = date.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return date }
            let ym = Day.addMonth(String(format: "%04d-%02d", p[0], p[1]), months)
            let last = Int(Day.monthEnd(ym).suffix(2)) ?? 28
            return ym + String(format: "-%02d", min(p[2], last))
        }
    }
}

public enum SubStatus: String, CaseIterable, Codable {
    case active, paused, cancelled
    public var name: String {
        switch self {
        case .active: return tr("订阅中", "Active")
        case .paused: return tr("已暂停", "Paused")
        case .cancelled: return tr("已取消", "Cancelled")
        }
    }
}

public struct Subscription: Identifiable {
    public var id: String { name }
    public var name: String
    public var amount: Double
    public var currency: String
    public var period: SubPeriod
    /// first charge
    public var start: String
    public var account: String
    public var funding: String
    public var payee: String
    /// next charge after an extension; the cycle continues from here
    public var next: String?
    public var status: SubStatus
    public weak var entry: Entry?

    public init(name: String, amount: Double, currency: String, period: SubPeriod, start: String, account: String, funding: String,
                payee: String = "", next: String? = nil, status: SubStatus = .active) {
        self.name = name; self.amount = amount; self.currency = currency; self.period = period; self.start = start
        self.account = account; self.funding = funding; self.payee = payee; self.next = next; self.status = status
    }

    /// where the charge cycle is counted from
    public var anchor: String {
        guard let n = next, Day.date(n) != nil else { return start }
        return max(n, start)
    }

    /// first charge on or after `date`
    public func due(onOrAfter date: String) -> String {
        if date <= anchor { return anchor }
        var k = estimate(date), n = 0
        while period.add(anchor, k) < date && n < 1000 { k += 1; n += 1 }
        while k > 0 && period.add(anchor, k - 1) >= date && n < 2000 { k -= 1; n += 1 }
        return period.add(anchor, k)
    }

    /// last charge on or before `date` (nil before the first one)
    public func due(onOrBefore date: String) -> String? {
        if date < anchor { return nil }
        var k = estimate(date), n = 0
        while period.add(anchor, k) > date && k > 0 && n < 1000 { k -= 1; n += 1 }
        while period.add(anchor, k + 1) <= date && n < 2000 { k += 1; n += 1 }
        return period.add(anchor, k)
    }

    private func estimate(_ date: String) -> Int {
        guard let a = Day.date(anchor), let b = Day.date(date) else { return 0 }
        let days = b.timeIntervalSince(a) / 86400
        return max(0, Int(days / (period.months * 30.436875)) - 1)
    }

    public var monthly: Double { amount / period.months }
    public var yearly: Double { amount * 12 / period.months }
}

/// every subscription in the ledger; a later directive with the same name replaces an earlier one
public func subscriptions(_ L: Ledger) -> [Subscription] {
    var by: [String: Subscription] = [:]
    for e in L.entries where e.type == .custom && e.name == "subscription" {
        var name: String?, period: SubPeriod?, amount: (Double, String)?
        for v in e.values {
            switch v {
            case .string(let s):
                if period == nil, let p = SubPeriod.parse(s), name != nil { period = p }
                else if name == nil { name = s }
            case .amount(let n, let c): amount = (n, c)
            default: break
            }
        }
        guard let n = name, let p = period, let m = amount else { continue }
        func str(_ k: String) -> String? { e.meta[k].map { $0.stringValue ?? $0.display } }
        // a hand-written next date must be a real date (anything else would stall the cycle maths)
        let next = str("next").flatMap { Day.date($0) }.map { Day.string($0) }
        var s = Subscription(name: n, amount: m.0, currency: m.1, period: p, start: e.date,
                             account: str("account") ?? "", funding: str("funding") ?? "", payee: str("payee") ?? "",
                             next: next, status: SubStatus(rawValue: (str("status") ?? "").lowercased()) ?? .active)
        s.entry = e
        if let old = by[n], let oe = old.entry, oe.date > e.date { continue }
        by[n] = s
    }
    return by.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// the directive text for a subscription
public func subscriptionText(_ s: Subscription) -> String {
    let q = quoted
    let left = "\(s.start) custom \"subscription\" \(q(s.name)) \(q(s.period.text))"
    let ns = toFixed(s.amount, 2)
    var lines = [left + String(repeating: " ", count: max(1, NUM_END + 12 - left.utf16.count - ns.utf16.count)) + ns + " " + s.currency]
    if !s.account.isEmpty { lines.append("  account: " + q(s.account)) }
    if !s.funding.isEmpty { lines.append("  funding: " + q(s.funding)) }
    if !s.payee.isEmpty { lines.append("  payee: " + q(s.payee)) }
    if let n = s.next, n > s.start { lines.append("  next: " + n) }
    if s.status != .active { lines.append("  status: " + q(s.status.rawValue)) }
    return lines.joined(separator: "\n")
}

/// a charge that has come due and is not in the ledger yet
public struct SubDue: Identifiable {
    public var id: String { sub.name + "|" + date }
    public let sub: Subscription
    public let date: String
}

/// was the charge due on `date` recorded? Either tagged with `subscription:` metadata, or a matching
/// amount to the subscription's expense account within a few days of the date
public func subscriptionPaid(_ s: Subscription, due date: String, _ L: Ledger) -> Bool {
    // from a few days early, but never back into the previous period (daily / weekly charges)
    let from = max(Day.shift(date, -5), Day.shift(s.period.add(date, -1), 1))
    let to = Day.shift(s.period.add(date, 1), -1)
    for t in L.txns where t.date >= from && t.date <= to && !t.synthetic {
        if let m = t.meta["subscription"] {
            if (m.stringValue ?? m.display) == s.name { return true }
            continue    // a charge recorded for another subscription
        }
        if !s.account.isEmpty, t.postings.contains(where: { p in
            p.account == s.account && p.currency == s.currency && abs((p.units ?? 0) - s.amount) <= max(0.01, s.amount * 0.2)
        }) { return true }
    }
    return false
}

/// charges due by `today` (looking back one period) that have no payment yet
public func subscriptionsDue(_ L: Ledger, today: String = Day.today()) -> [SubDue] {
    var out: [SubDue] = []
    for s in subscriptions(L) where s.status == .active {
        guard let d = s.due(onOrBefore: today), d >= s.start else { continue }
        if !subscriptionPaid(s, due: d, L) { out.append(SubDue(sub: s, date: d)) }
    }
    return out.sorted { $0.date < $1.date }
}

/// recurring payments in the last year that look like subscriptions but are not tracked yet
public struct SubCandidate: Identifiable {
    public var id: String { payee + "|" + account }
    public let payee: String
    public let account: String
    public let funding: String
    public let amount: Double
    public let currency: String
    public let period: SubPeriod
    public let last: String
    public let count: Int
}

public func subscriptionCandidates(_ L: Ledger, today: String = Day.today()) -> [SubCandidate] {
    let since = Day.shift(today, -400)
    let known = subscriptions(L)
    var groups: [String: [(date: String, amount: Double, currency: String, account: String, funding: String, payee: String)]] = [:]
    for t in L.txns where t.date >= since && !t.synthetic {
        guard let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency else { continue }
        let payee = !t.payee.isEmpty ? t.payee : t.narration
        guard !payee.isEmpty else { continue }
        let funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
        groups[payee + "|" + exp.account, default: []].append((t.date, u, c, exp.account, funding, payee))
    }
    var out: [SubCandidate] = []
    for (_, xs0) in groups where xs0.count >= 3 {
        let xs = xs0.sorted { $0.date < $1.date }
        let last = xs[xs.count - 1]
        // same amount (±5%) most of the time
        let same = xs.filter { abs($0.amount - last.amount) <= last.amount * 0.05 && $0.currency == last.currency }
        guard same.count >= 3, Double(same.count) >= Double(xs.count) * 0.7 else { continue }
        // regular gaps
        var gaps: [Double] = []
        for i in 1..<same.count {
            if let a = Day.date(same[i - 1].date), let b = Day.date(same[i].date) { gaps.append(b.timeIntervalSince(a) / 86400) }
        }
        let avg = gaps.reduce(0, +) / Double(max(1, gaps.count))
        guard gaps.allSatisfy({ abs($0 - avg) <= max(4, avg * 0.15) }) else { continue }
        let period: SubPeriod
        switch avg {
        case 5...9: period = .weekly
        case 26...35: period = .monthly
        case 85...97: period = .quarterly
        case 175...190: period = .halfYearly
        default: continue
        }
        // still running
        guard let ld = Day.date(last.date), let td = Day.date(today), td.timeIntervalSince(ld) / 86400 <= avg * 1.5 else { continue }
        if known.contains(where: { $0.account == last.account && ($0.payee == last.payee || $0.name == last.payee) }) { continue }
        out.append(SubCandidate(payee: last.payee, account: last.account, funding: last.funding, amount: last.amount,
                                currency: last.currency, period: period, last: last.date, count: same.count))
    }
    return out.sorted { $0.amount / $0.period.months > $1.amount / $1.period.months }
}
