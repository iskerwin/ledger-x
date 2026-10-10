import Foundation

// Subscriptions, kept in the ledger as custom directives (Fava shows them, bean-check ignores them).
// Every change is a new dated line, so the history stays in the ledger; the latest line wins:
//
//   2024-01-15 custom "subscription" "iCloud+" "monthly" 21.00 CNY     ; start
//     account: "Expenses:Subscription"
//     funding: "Liabilities:CreditCard:CMB"
//     payee: "Apple"
//     link: "sub-icloud"            ; the link every charge carries (^sub-icloud)
//     next: 2024-06-15              ; optional: the next charge after a free / extended period
//     trial_end: 2024-02-15         ; optional: free trial ends
//   2025-03-01 custom "subscription" "iCloud+" "paused"               ; or "cancelled"
//   2025-06-10 custom "subscription" "iCloud+" "monthly" 25.00 CNY     ; resumed at a new price
//
// A plan line repeats only what changed; metadata carries over from the earlier lines.
// The charges are the transactions with the subscription's link (or `subscription:` metadata).
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

/// one charge: a transaction linked to the subscription
public struct SubCharge: Identifiable {
    public var id: Int { txn.id }
    public let date: String
    public let amount: Double
    public let currency: String
    public let funding: String
    public let txn: Entry
}

/// a line in the subscription's history
public struct SubEvent: Identifiable {
    public enum Kind: String { case start, change, pause, resume, cancel }
    public var id: String { date + "|" + kind.rawValue + "|\(entry?.line ?? 0)" }
    public let date: String
    public let kind: Kind
    public var amount: Double?
    public var currency: String?
    public var period: SubPeriod?
    public weak var entry: Entry?
}

public struct Subscription: Identifiable {
    public var id: String { name }
    public var name: String
    public var amount: Double
    public var currency: String
    public var period: SubPeriod
    /// first charge (the first line)
    public var start: String
    /// when the current run of the plan began (start, or the latest resume)
    public var since: String
    public var account: String
    public var funding: String
    public var payee: String
    /// next charge after an extension; the cycle continues from here
    public var next: String?
    public var status: SubStatus
    /// when the current status began
    public var statusDate: String
    public var link: String
    public var trialEnd: String?
    /// the latest line, and all of them oldest first
    public weak var entry: Entry?
    public var entries: [Entry] = []
    public var events: [SubEvent] = []
    public var charges: [SubCharge] = []

    public init(name: String, amount: Double, currency: String, period: SubPeriod, start: String, account: String, funding: String,
                payee: String = "", next: String? = nil, status: SubStatus = .active, link: String? = nil, trialEnd: String? = nil) {
        self.name = name; self.amount = amount; self.currency = currency; self.period = period; self.start = start
        self.since = start; self.statusDate = start
        self.account = account; self.funding = funding; self.payee = payee; self.next = next; self.status = status
        self.link = link ?? subscriptionLink(name); self.trialEnd = trialEnd
    }

    public var lastCharge: SubCharge? { charges.last }

    /// the account the next charge is expected from: the latest charge's, else the one on the plan
    /// (cards change; the transactions are what counts)
    public var paymentAccount: String {
        if let f = charges.last?.funding, !f.isEmpty { return f }
        return funding
    }

    /// a gap of at least this many days means a period was skipped (a late renewal isn't one)
    public var skipDays: Double { periodDays * 2 - max(5, periodDays * 0.2) }

    /// where the charge cycle is counted from: the start of the current run, the latest charge, or an extension
    public var anchor: String {
        var a = since
        if let c = charges.last?.date, c >= a { a = c }
        if let n = next, Day.date(n) != nil, n > a { a = n }
        return a
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
    public var periodDays: Double { period.months * 30.436875 }

    /// paid in total, and within a year ("2026")
    public var totalPaid: Double { charges.filter { $0.currency == currency }.reduce(0) { $0 + $1.amount } }
    public func paid(in year: String) -> Double { charges.filter { $0.date.hasPrefix(year) && $0.currency == currency }.reduce(0) { $0 + $1.amount } }
}

/// a link name for a subscription: "sub-" + its ASCII letters and digits, or a short hash for other names
public func subscriptionLink(_ name: String) -> String {
    let ascii = name.lowercased().unicodeScalars.map { s -> Character in
        (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
    }
    var slug = String(ascii).split(separator: "-").joined(separator: "-")
    if slug.count < 2 {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        slug = (slug.isEmpty ? "" : slug + "-") + String(h, radix: 36)
    }
    return "sub-" + slug.prefix(40)
}

/// the charges' amount: what went to the subscription's account (or the first expense)
func chargeOf(_ t: Entry, account: String) -> (Double, String, String)? {
    let p = t.postings.first { $0.account == account && $0.units != nil } ?? t.postings.first { $0.account.hasPrefix("Expenses:") && $0.units != nil }
    guard let p = p, let u = p.units, let c = p.currency else { return nil }
    let funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
    return (abs(u), c, funding)
}

/// every subscription in the ledger, its history and its charges
public func subscriptions(_ L: Ledger) -> [Subscription] {
    var lines: [String: [Entry]] = [:]
    for e in L.entries where e.type == .custom && e.name == "subscription" {
        guard case .string(let n)? = e.values.first else { continue }
        lines[n, default: []].append(e)
    }
    var out: [Subscription] = []
    for (name, es0) in lines {
        let es = es0.sorted { $0.date != $1.date ? $0.date < $1.date : $0.line < $1.line }
        var s: Subscription?
        var meta: [String: String] = [:]
        for e in es {
            var word: String?, period: SubPeriod?, amount: (Double, String)?
            for v in e.values.dropFirst() {
                switch v {
                case .string(let x):
                    if let p = SubPeriod.parse(x) { period = p } else { word = x.lowercased() }
                case .amount(let n, let c): amount = (n, c)
                default: break
                }
            }
            for (k, v) in e.meta.items { meta[k] = v.stringValue ?? v.display }
            if let p = period, let m = amount {
                // a plan line: start, change, or resume
                let state = SubStatus(rawValue: (e.meta["status"].map { $0.stringValue ?? $0.display } ?? "").lowercased()) ?? .active
                let next = e.meta["next"].flatMap { v in Day.date(v.stringValue ?? v.display) }.map { Day.string($0) }
                if var x = s {
                    let resumed = x.status != .active && state == .active
                    x.events.append(SubEvent(date: e.date, kind: resumed ? .resume : .change, amount: m.0, currency: m.1, period: p, entry: e))
                    x.amount = m.0; x.currency = m.1; x.period = p
                    if resumed { x.since = e.date }
                    if x.status != state { x.statusDate = e.date }
                    x.status = state
                    x.next = next
                    s = x
                } else {
                    var x = Subscription(name: name, amount: m.0, currency: m.1, period: p, start: e.date, account: "", funding: "",
                                         next: next, status: state)
                    x.events.append(SubEvent(date: e.date, kind: .start, amount: m.0, currency: m.1, period: p, entry: e))
                    s = x
                }
            } else if let w = word, var x = s {
                // a state line
                let st: SubStatus = w == "paused" || w == "pause" ? .paused : w == "cancelled" || w == "canceled" || w == "cancel" ? .cancelled : .active
                let kind: SubEvent.Kind = st == .paused ? .pause : st == .cancelled ? .cancel : .resume
                x.events.append(SubEvent(date: e.date, kind: kind, entry: e))
                if st == .active && x.status != .active { x.since = e.date }
                if x.status != st { x.statusDate = e.date }
                x.status = st
                if st != .active { x.next = nil }
                s = x
            }
            if var x = s {
                x.account = meta["account"] ?? x.account
                x.funding = meta["funding"] ?? x.funding
                x.payee = meta["payee"] ?? x.payee
                if let l = meta["link"], !l.isEmpty { x.link = l }
                x.trialEnd = meta["trial_end"].flatMap { Day.date($0) }.map { Day.string($0) }
                x.entry = e
                x.entries.append(e)
                s = x
            }
        }
        if let x = s { out.append(x) }
    }
    // charges: transactions carrying the link, or recorded with `subscription:` metadata
    var byLink: [String: Int] = [:], byName: [String: Int] = [:]
    for (i, x) in out.enumerated() { byLink[x.link] = i; byName[x.name] = i }
    for t in L.txns where !t.synthetic {
        var i = t.links.lazy.compactMap { byLink[$0] }.first
        if i == nil, let m = t.meta["subscription"] { i = byName[m.stringValue ?? m.display] }
        guard let k = i, let c = chargeOf(t, account: out[k].account) else { continue }
        out[k].charges.append(SubCharge(date: t.date, amount: c.0, currency: c.1, funding: c.2, txn: t))
    }
    for k in out.indices { out[k].charges.sort { $0.date < $1.date } }
    return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// a plan line (start, change or resume) dated `date`
public func subscriptionText(_ s: Subscription, date: String? = nil, full: Bool = true) -> String {
    let q = quoted
    let d = date ?? s.start
    let left = "\(d) custom \"subscription\" \(q(s.name)) \(q(s.period.text))"
    let ns = toFixed(s.amount, 2)
    var lines = [left + String(repeating: " ", count: max(1, NUM_END + 12 - left.utf16.count - ns.utf16.count)) + ns + " " + s.currency]
    if full {
        if !s.account.isEmpty { lines.append("  account: " + q(s.account)) }
        if !s.funding.isEmpty { lines.append("  funding: " + q(s.funding)) }
        if !s.payee.isEmpty { lines.append("  payee: " + q(s.payee)) }
        if !s.link.isEmpty { lines.append("  link: " + q(s.link)) }
        if let t = s.trialEnd { lines.append("  trial_end: " + t) }
    }
    if let n = s.next, n > d { lines.append("  next: " + n) }
    if s.status != .active { lines.append("  status: " + q(s.status.rawValue)) }
    return lines.joined(separator: "\n")
}

/// a state line: paused / cancelled
public func subscriptionStateText(_ name: String, _ status: SubStatus, date: String) -> String {
    "\(date) custom \"subscription\" \(quoted(name)) \(quoted(status.rawValue))"
}

/// a charge that has come due and is not in the ledger yet
public struct SubDue: Identifiable {
    public var id: String { sub.name + "|" + date }
    public let sub: Subscription
    public let date: String
}

/// was the charge due on `date` recorded? A linked charge, or a matching amount to the subscription's
/// expense account within a few days of the date
public func subscriptionPaid(_ s: Subscription, due date: String, _ L: Ledger) -> Bool {
    // from a few days early, but never back into the previous period (daily / weekly charges)
    let from = max(Day.shift(date, -5), Day.shift(s.period.add(date, -1), 1))
    let to = Day.shift(s.period.add(date, 1), -1)
    if s.charges.contains(where: { $0.date >= from && $0.date <= to }) { return true }
    for t in L.txns where t.date >= from && t.date <= to && !t.synthetic {
        if let m = t.meta["subscription"] {
            if (m.stringValue ?? m.display) == s.name { return true }
            continue    // a charge recorded for another subscription
        }
        if t.links.contains(where: { $0.hasPrefix("sub-") }) { continue }
        if !s.account.isEmpty, t.postings.contains(where: { p in
            p.account == s.account && p.currency == s.currency && abs((p.units ?? 0) - s.amount) <= max(0.01, s.amount * 0.2)
        }) { return true }
    }
    return false
}

/// charges due by `today` (looking back one period) that have no payment yet
public func subscriptionsDue(_ L: Ledger, today: String = Day.today(), subs: [Subscription]? = nil) -> [SubDue] {
    var out: [SubDue] = []
    for s in subs ?? subscriptions(L) where s.status == .active {
        guard let d = s.due(onOrBefore: today), d >= s.since else { continue }
        if let t = s.trialEnd, d <= t { continue }
        if !subscriptionPaid(s, due: d, L) { out.append(SubDue(sub: s, date: d)) }
    }
    return out.sorted { $0.date < $1.date }
}

// MARK: - history

public struct SubTimelineItem: Identifiable {
    public enum Kind: String { case event, run, gap }
    public var id: String { kind.rawValue + "|" + from + "|" + title }
    public let kind: Kind
    public let from: String
    public var to: String?
    public let title: String
    public var detail: String = ""
    public var eventKind: SubEvent.Kind?
}

/// plan changes and charges as one history, newest first: runs of charges at one price, gaps without charges
public func subscriptionTimeline(_ s: Subscription) -> [SubTimelineItem] {
    var items: [SubTimelineItem] = []
    for e in s.events {
        let price = e.amount.map { money($0, e.currency ?? s.currency) + " / " + (e.period ?? s.period).name } ?? ""
        let title: String
        switch e.kind {
        case .start: title = tr("开始订阅", "Started")
        case .change: title = tr("变更", "Changed")
        case .pause: title = tr("暂停", "Paused")
        case .resume: title = tr("恢复", "Resumed")
        case .cancel: title = tr("取消", "Cancelled")
        }
        items.append(SubTimelineItem(kind: .event, from: e.date, title: title, detail: price, eventKind: e.kind))
    }
    let cs = s.charges.filter { $0.currency == s.currency }
    // renewing a few days late is not a gap; only a whole skipped period is
    let longGap = s.skipDays
    var i = 0
    while i < cs.count {
        var j = i
        while j + 1 < cs.count {
            let a = cs[j], b = cs[j + 1]
            let gap = Double(daysBetween(a.date, b.date))
            if gap > longGap || abs(b.amount - cs[i].amount) > max(0.01, cs[i].amount * 0.01) { break }
            j += 1
        }
        let n = j - i + 1
        var late = 0
        if j > i { for k in i..<j where Double(daysBetween(cs[k].date, cs[k + 1].date)) > s.periodDays + 3 { late += 1 } }
        let first = i == 0 && n == 1 && cs.count > 1 && abs(cs[1].amount - cs[0].amount) > max(0.01, cs[0].amount * 0.01)
        let title = first ? tr("首期 \(money(cs[i].amount, s.currency))", "First charge \(money(cs[i].amount, s.currency))")
            : tr("\(money(cs[i].amount, s.currency)) × \(n) 期", "\(money(cs[i].amount, s.currency)) × \(n)")
        var detail = tr("合计 \(money(cs[i].amount * Double(n), s.currency))", "Total \(money(cs[i].amount * Double(n), s.currency))")
        if late > 0 { detail += tr(" · \(late) 次延后续费", " · \(late) renewed late") }
        items.append(SubTimelineItem(kind: .run, from: cs[i].date, to: n > 1 ? cs[j].date : nil, title: title, detail: detail))
        if j + 1 < cs.count {
            let gap = Double(daysBetween(cs[j].date, cs[j + 1].date))
            if gap > longGap {
                let missed = max(1, Int((gap / s.periodDays).rounded()) - 1)
                items.append(SubTimelineItem(kind: .gap, from: Day.shift(cs[j].date, 1), to: Day.shift(cs[j + 1].date, -1),
                                             title: tr("约 \(missed) 期未续费", "About \(missed) not renewed")))
            }
        }
        i = j + 1
    }
    let order: [SubTimelineItem.Kind: Int] = [.gap: 0, .run: 1, .event: 2]
    return items.sorted { $0.from != $1.from ? $0.from > $1.from : (order[$0.kind] ?? 0) < (order[$1.kind] ?? 0) }
}

// MARK: - things worth a look

public struct SubAlert: Identifiable {
    public enum Kind: String { case priceChanged, chargedWhileInactive, silent, trialEnding }
    public var id: String { kind.rawValue }
    public let kind: Kind
    public let message: String
    /// the value to switch to (price or account) for the price / funding alerts
    public var amount: Double?
    public var account: String?
    public var date: String?
}

public func subscriptionAlerts(_ s: Subscription, today: String = Day.today()) -> [SubAlert] {
    var out: [SubAlert] = []
    let last = s.charges.last
    if s.status == .active, let c = last, c.date >= s.since, c.currency == s.currency, abs(c.amount - s.amount) > max(0.01, s.amount * 0.01) {
        out.append(SubAlert(kind: .priceChanged,
                            message: tr("最近一次扣费 \(money(c.amount, c.currency))，订阅金额为 \(money(s.amount, s.currency))",
                                        "Last charge was \(money(c.amount, c.currency)); the plan says \(money(s.amount, s.currency))"),
                            amount: c.amount, date: c.date))
    }
    if s.status != .active, let c = s.charges.last(where: { $0.date > s.statusDate }) {
        out.append(SubAlert(kind: .chargedWhileInactive,
                            message: tr("\(s.status.name)后仍有扣费：\(c.date) \(money(c.amount, c.currency))，请确认是否已退订",
                                        "Charged after it was \(s.status.name.lowercased()): \(c.date) \(money(c.amount, c.currency)). Check the cancellation"),
                            date: c.date))
    }
    // only after a whole period has been skipped, and only as a question: it may just be a renewal
    // that wasn't recorded (or was paid late), so nothing changes unless you say so
    if s.status == .active, s.trialEnd.map({ $0 < today }) ?? true {
        let ref = max(last?.date ?? s.since, s.since, s.next ?? "")
        let days = daysBetween(ref, today)
        if Double(days) > s.periodDays + s.skipDays {
            out.append(SubAlert(kind: .silent,
                                message: tr("已有 \(days) 天没有续费记录（上次 \(ref)）。可能忘记记账或续费，也可能已停止",
                                            "No renewal for \(days) days (last \(ref)). It may be unrecorded, renewed late, or stopped"),
                                date: ref))
        }
    }
    if s.status == .active, let t = s.trialEnd, t >= today, daysBetween(today, t) <= 7 {
        out.append(SubAlert(kind: .trialEnding,
                            message: tr("免费试用 \(t) 结束，之后开始扣费", "Free trial ends \(t); charges start after"), date: t))
    }
    return out
}

// MARK: - finding subscriptions in the history

/// regular payments to one payee that look like a subscription and aren't tracked yet
public struct SubCandidate: Identifiable {
    public var id: String { payee + "|" + account }
    public let payee: String
    public let account: String
    public let funding: String
    /// the latest amount
    public let amount: Double
    public let currency: String
    public let period: SubPeriod
    public let first: String
    public let last: String
    public let count: Int
    /// the matching transactions, oldest first
    public let txns: [Entry]
}

/// Same payee and expense account, a regular gap (allowing pauses of a few periods), mostly the same amount
/// (a different first price is fine). Monthly-ish needs 3 charges, yearly 2.
public func subscriptionCandidates(_ L: Ledger, today: String = Day.today(), subs: [Subscription]? = nil) -> [SubCandidate] {
    let since = Day.shift(today, -760)
    let known = subs ?? subscriptions(L)
    let linked = Set(known.flatMap { $0.charges.map { $0.txn.id } })
    var groups: [String: [(t: Entry, amount: Double, currency: String, account: String, funding: String, payee: String)]] = [:]
    for t in L.txns where t.date >= since && t.date <= today && !t.synthetic && !linked.contains(t.id) {
        if t.links.contains(where: { $0.hasPrefix("sub-") }) { continue }
        guard let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency else { continue }
        let payee = !t.payee.isEmpty ? t.payee : t.narration
        guard !payee.isEmpty else { continue }
        let funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
        groups[payee + "|" + exp.account, default: []].append((t, u, c, exp.account, funding, payee))
    }
    var out: [SubCandidate] = []
    for (_, xs0) in groups where xs0.count >= 2 {
        let xs = xs0.sorted { $0.t.date < $1.t.date }
        let last = xs[xs.count - 1]
        // the latest price; the first charge may differ (trial / intro price)
        let same = xs.filter { abs($0.amount - last.amount) <= max(0.01, last.amount * 0.05) && $0.currency == last.currency }
        guard Double(same.count) >= Double(xs.count - 1) * 0.7 else { continue }
        var gaps: [Double] = []
        for i in 1..<xs.count { gaps.append(Double(daysBetween(xs[i - 1].t.date, xs[i].t.date))) }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let period: SubPeriod
        switch median {
        case 6...8: period = .weekly
        case 27...34: period = .monthly
        case 85...97: period = .quarterly
        case 175...190: period = .halfYearly
        case 350...380: period = .yearly
        default: continue
        }
        let needed = period == .yearly || period == .halfYearly ? 2 : 3
        guard xs.count >= needed else { continue }
        // regular, apart from pauses (gaps of whole periods)
        let regular = gaps.filter { g in
            let k = (g / median).rounded()
            return k >= 1 && abs(g - k * median) <= max(4, median * 0.15)
        }
        guard Double(regular.count) >= Double(gaps.count) * 0.8 else { continue }
        // still running: the last charge is within two periods
        guard Double(daysBetween(last.t.date, today)) <= median * 2 + 5 else { continue }
        if known.contains(where: { $0.account == last.account && ($0.payee == last.payee || $0.name == last.payee) }) { continue }
        out.append(SubCandidate(payee: last.payee, account: last.account, funding: last.funding, amount: last.amount,
                                currency: last.currency, period: period, first: xs[0].t.date, last: last.t.date,
                                count: xs.count, txns: xs.map { $0.t }))
    }
    return out.sorted { $0.amount / $0.period.months > $1.amount / $1.period.months }
}

/// the subscription a new transaction belongs to: same expense account and payee (or name), a similar amount
public func matchSubscription(payee: String, account: String, amount: Double, currency: String, _ subs: [Subscription]) -> Subscription? {
    subs.first { s in
        s.status != .cancelled && s.account == account && !account.isEmpty
            && (s.payee == payee || s.name == payee || (!s.payee.isEmpty && payee.contains(s.payee)))
            && s.currency == currency && abs(amount - s.amount) <= max(0.01, s.amount * 0.3)
    }
}
