import Foundation

// MARK: - language

public enum KitPrivacy {
    /// true = amounts show as "¥***" (the app sets this from its 隐藏金额 setting)
    public static var masked = false
}

public enum KitLocale {
    /// false = English messages and labels (the app sets this from its language setting)
    public static var chinese = true
}

/// pick the Chinese or English text
public func tr(_ zh: @autoclosure () -> String, _ en: @autoclosure () -> String) -> String { KitLocale.chinese ? zh() : en() }

let MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// MARK: - dates & labels

public enum Day {
    public static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    public static func string(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func today() -> String { string(Date()) }
    public static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }
    public static func shift(_ s: String, _ k: Int) -> String {
        guard let d = date(s), let n = calendar.date(byAdding: .day, value: k, to: d) else { return s }
        return string(n)
    }
    public static func ym(_ d: String) -> String { String(d.prefix(7)) }
    public static func addMonth(_ m: String, _ k: Int) -> String {
        var y = Int(m.prefix(4)) ?? 2000
        var mo = (Int(m.dropFirst(5).prefix(2)) ?? 1) - 1 + k
        y += Int(floor(Double(mo) / 12))
        mo = ((mo % 12) + 12) % 12
        return String(format: "%04d-%02d", y, mo + 1)
    }
    public static func monthLabel(_ m: String) -> String {
        let mo = Int(m.dropFirst(5).prefix(2)) ?? 0
        if !KitLocale.chinese { return "\(MONTHS_EN[max(0, min(11, mo - 1))]) \(m.prefix(4))" }
        return "\(m.prefix(4))年\(mo)月"
    }
    public static func dayLabel(_ d: String) -> String {
        let wd = date(d).map { calendar.component(.weekday, from: $0) - 1 } ?? 0
        let mo = Int(d.dropFirst(5).prefix(2)) ?? 0, day = Int(d.dropFirst(8).prefix(2)) ?? 0
        if !KitLocale.chinese {
            let week = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "\(week[wd]), \(MONTHS_EN[max(0, min(11, mo - 1))]) \(day)"
        }
        let week = Array("日一二三四五六")
        return "\(mo)月\(day)日 周\(week[wd])"
    }
    public static func monthEnd(_ m: String) -> String { shift(addMonth(m, 1) + "-01", -1) }
}

public let ZH: [String: String] = [
    "Food": "餐饮", "Housing": "居住", "Travel": "旅行", "Transit": "交通", "Shopping": "购物", "Subscription": "订阅服务", "Gifts": "人情往来",
    "Lifestyle": "生活服务", "Government": "政府规费", "Healthcare": "医疗保健", "Fee": "手续费", "Charity": "捐赠", "Miscellaneous": "其他支出",
    "Salary": "工资薪金", "Freelance": "劳务报酬", "Invest": "投资收益", "Rewards": "奖励返现", "Sale": "资产处置", "ReimbExcess": "报销溢收",
    "Bank": "银行存款", "EWallet": "第三方支付", "Cash": "现金", "Brokerage": "证券账户", "Crypto": "加密资产", "Receivable": "应收款项", "CreditCard": "信用卡", "Loan": "贷款",
    "Assets": "资产", "Liabilities": "负债", "Income": "收入", "Expenses": "支出", "Equity": "权益",
]

public let SYM: [String: String] = ["CNY": "¥", "HKD": "HK$", "USD": "$", "EUR": "€", "GBP": "£", "SGD": "S$", "MOP": "MOP$"]

/// an amount for display; "¥***" while amounts are hidden
public func money(_ n: Double, _ c: String = "CNY", _ d: Int = 2) -> String {
    KitPrivacy.masked ? (SYM[c] ?? "") + "***" + (SYM[c] != nil ? "" : " " + c) : plainMoney(n, c, d)
}
/// an amount that is never hidden (stored with queued changes, compared, copied)
public func plainMoney(_ n: Double, _ c: String = "CNY", _ d: Int = 2) -> String {
    (n < -1e-9 ? "-" : "") + (SYM[c] ?? "") + fmtNum(abs(n), d) + (SYM[c] != nil ? "" : " " + c)
}
public func signedMoney(_ n: Double, _ c: String = "CNY") -> String { (n > 1e-9 && !KitPrivacy.masked ? "+" : "") + money(n, c) }

public func leaf(_ a: String) -> String { a.components(separatedBy: ":").last ?? a }
public func catOf(_ a: String) -> String { a.components(separatedBy: ":").prefix(2).joined(separator: ":") }
public func catLabel(_ a: String) -> String {
    let p = a.components(separatedBy: ":")
    return p.count > 1 ? (KitLocale.chinese ? (ZH[p[1]] ?? p[1]) : p[1]) : a
}
/// the account without its root, exactly as written in the ledger ("Food:Drinks", "Bank:CGB")
public func acctLabel(_ a: String) -> String {
    let p = a.components(separatedBy: ":")
    return p.count > 1 ? p.dropFirst().joined(separator: ":") : a
}

/// Chinese description of the account's group, if there is one ("餐饮" for Expenses:Food:…)
public func acctZH(_ a: String) -> String? {
    let p = a.components(separatedBy: ":")
    guard p.count > 1, KitLocale.chinese else { return nil }
    return ZH[p[1]]
}

/// the account as written, with the Chinese description after it: "Food:Drinks · 餐饮"
public func acctDisplay(_ a: String) -> String {
    acctLabel(a) + (acctZH(a).map { " · " + $0 } ?? "")
}

// MARK: - classification

public enum TxKind: String { case expense, refund, income, transfer }

public struct Classified {
    public let kind: TxKind
    public let amount: Double
    public let currency: String?
}

public func classify(_ t: Entry, _ L: Ledger) -> Classified {
    classify(postings: t.postings, date: t.date, L)
}

public func classify(postings: [Posting], date: String, _ L: Ledger) -> Classified {
    var exp = 0.0, inc = 0.0, hasExp = false, hasInc = false
    for p in postings {
        guard let u = p.units, let c = p.currency else { continue }
        let v = toCNY(L, u, c, date) ?? 0
        if p.account.hasPrefix("Expenses:") { exp += v; hasExp = true }
        else if p.account.hasPrefix("Income:") { inc -= v; hasInc = true }
    }
    if hasExp { return Classified(kind: exp < 0 ? .refund : .expense, amount: -exp, currency: nil) }
    if hasInc { return Classified(kind: .income, amount: inc, currency: nil) }
    let pos = postings.first { ($0.units ?? 0) > 0 }
    return Classified(kind: .transfer, amount: pos?.units ?? 0, currency: pos?.currency)
}

// MARK: - derived data (what the UI needs on top of the ledger)

public struct PayeeStat {
    public var name: String
    public var n = 0
    public var w = 0.0
    public var last: Entry
    public var narr: [String: Int] = [:]
    public var narrations: [String] { narr.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key } }
}

public struct OpenLink {
    public let link: String
    public let amount: Double
    public let currency: String
    public let n: Int
}

public struct Unclaimed {
    public let t: Entry
    public let amount: Double
    public let currency: String
}

public final class Derived: @unchecked Sendable {
    public var acctUse: [String: Double] = [:]
    public var acctCcy: [String: String] = [:]
    public var short: [String: String] = [:]
    public var payees: [PayeeStat] = []
    public var payeeIndex: [String: Int] = [:]
    public var monthExp: [String: Double] = [:]
    public var monthInc: [String: Double] = [:]
    public var monthCat: [String: [String: Double]] = [:]
    public var openAccounts: [String] = []
    public var currencies: [String] = []
    public var openLinks: [OpenLink] = []
    public var unclaimed: [Unclaimed] = []
    public var unclaimedOld = 0.0
    public var allLinks: [String] = []
    public var byLink: [String: [Entry]] = [:]

    public func payee(_ name: String) -> PayeeStat? { payeeIndex[name].map { payees[$0] } }

    /// the account advances wait in until they are paid back
    public let receivable: String

    public init(_ L: Ledger, today now: String = Day.today(), receivable: String = "Assets:Receivable:Reimbursement") {
        self.receivable = receivable
        let recent = Day.addMonth(Day.ym(now), -6)
        let d60 = Day.shift(now, -60)
        var acctCcyW: [String: [String: Double]] = [:]
        var ccyOrder: [String: [String]] = [:]
        var shortC: [String: [String: Int]] = [:]
        var shortOrder: [String: [String]] = [:]
        var pmap: [String: PayeeStat] = [:]
        for t in L.txns {
            let w: Double = t.date >= d60 ? 20 : t.date >= recent ? 4 : 1
            for p in t.postings {
                guard let u = p.units, let c = p.currency else { continue }
                acctUse[p.account, default: 0] += w
                if acctCcyW[p.account]?[c] == nil { ccyOrder[p.account, default: []].append(c) }
                acctCcyW[p.account, default: [:]][c, default: 0] += w
                let m = Day.ym(t.date)
                if p.account.hasPrefix("Expenses:") {
                    let v = toCNY(L, u, c, t.date) ?? 0
                    monthExp[m, default: 0] += v
                    monthCat[m, default: [:]][p.account, default: 0] += v
                } else if p.account.hasPrefix("Income:") {
                    monthInc[m, default: 0] -= toCNY(L, u, c, t.date) ?? 0
                }
            }
            if !t.payee.isEmpty {
                var s = pmap[t.payee] ?? PayeeStat(name: t.payee, last: t)
                s.n += 1; s.w += w; s.last = t
                if !t.narration.isEmpty { s.narr[t.narration, default: 0] += 1 }
                pmap[t.payee] = s
            }
            if t.tags.contains("transfer"), let r = t.narration.range(of: " -> ") ?? t.narration.range(of: "->") {
                let a = t.narration[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let b = t.narration[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if let from = t.postings.first(where: { ($0.units ?? 0) < 0 }), let to = t.postings.first(where: { ($0.units ?? 0) > 0 }), !a.isEmpty, !b.isEmpty {
                    if shortC[from.account]?[a] == nil { shortOrder[from.account, default: []].append(a) }
                    shortC[from.account, default: [:]][a, default: 0] += 1
                    if shortC[to.account]?[b] == nil { shortOrder[to.account, default: []].append(b) }
                    shortC[to.account, default: [:]][b, default: 0] += 1
                }
            }
        }
        // most weight wins; ties go to the first seen (like a stable sort in JS)
        for (a, order) in ccyOrder {
            let m = acctCcyW[a]!
            var best = order[0]
            for c in order.dropFirst() where m[c]! > m[best]! { best = c }
            acctCcy[a] = best
        }
        for (a, order) in shortOrder {
            let m = shortC[a]!
            var best = order[0]
            for c in order.dropFirst() where m[c]! > m[best]! { best = c }
            short[a] = best
        }
        payees = pmap.values.sorted { $0.w != $1.w ? $0.w > $1.w : $0.name < $1.name }
        for (i, p) in payees.enumerated() { payeeIndex[p.name] = i }
        openAccounts = L.accounts.values.filter { $0.close == nil || $0.close! > now }.map { $0.name }.sorted()
        var cs = ["CNY"]
        for c in L.rates.keys.sorted() where !cs.contains(c) { cs.append(c) }
        currencies = cs.filter { c in
            let ok = c.count >= 3 && c.count <= 4 && c.unicodeScalars.allSatisfy { isAZ($0) }
            let equity = L.commodities[c]?["asset-class"]?.display.contains("equity") ?? false
            return ok && !equity
        }
        // open reimbursement links
        var linkSum: [String: Double] = [:], linkN: [String: Int] = [:], linkC: [String: String] = [:]
        var linkOrder: [String] = []
        for t in L.txns {
            for l in t.links {
                for p in t.postings where p.account.hasPrefix("Assets:Receivable") {
                    if linkSum[l] == nil { linkOrder.append(l) }
                    linkSum[l, default: 0] += p.units ?? 0
                    linkC[l] = p.currency
                    if (p.units ?? 0) > 0 { linkN[l, default: 0] += 1 }
                }
            }
        }
        openLinks = linkOrder.filter { $0.hasPrefix("reimburse") && abs(linkSum[$0]!) > 0.005 }.map {
            OpenLink(link: $0, amount: roundTo(linkSum[$0]!, 2), currency: linkC[$0] ?? "CNY", n: linkN[$0] ?? 0)
        }
        let cutoff = Day.shift(now, -180)
        for t in L.txns {
            if t.links.contains(where: { $0.hasPrefix("reimburse") }) { continue }
            for p in t.postings where p.account == receivable {
                if t.date >= cutoff { unclaimed.append(Unclaimed(t: t, amount: p.units ?? 0, currency: p.currency ?? "CNY")) }
                else { unclaimedOld += p.units ?? 0 }
            }
        }
        var seenL = Set<String>()
        for t in L.txns {
            for l in t.links {
                if seenL.insert(l).inserted { allLinks.append(l) }
                byLink[l, default: []].append(t)
            }
        }
    }

    public func shortName(_ a: String) -> String {
        if let s = short[a] { return s }
        let parts = a.components(separatedBy: ":")
        let lf = parts.last ?? a
        if ["Cash", "Personal", "Business", "Stock", "ETF"].contains(lf) && parts.count > 3 { return parts[2] }
        return lf
    }

    public func rankAccounts(_ prefixes: [String], boost: [String] = []) -> [String] {
        let list = openAccounts.filter { a in prefixes.contains { a.hasPrefix($0) } }
        let bi = Dictionary(boost.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.sorted { a, b in
            let ia = bi[a], ib = bi[b]
            if (ia != nil) != (ib != nil) { return ia != nil }
            if let ia = ia, let ib = ib, ia != ib { return ia < ib }
            let ua = acctUse[a] ?? 0, ub = acctUse[b] ?? 0
            if ua != ub { return ua > ub }
            return a < b
        }
    }
}

// MARK: - frequent transactions (常用)

public struct Template: Identifiable {
    public let id: String
    public let kind: TxKind
    public let payee: String
    public let narration: String
    public let account: String
    public var funding: String
    public let currency: String
    public var amounts: [Double] = []
    public var dates: [String] = []
    public var fixed: Double?
    public var monthly = false
    public var day = 0
    public var due = false
    public var n = 0
    public var pinned = false

    public var label: String { !payee.isEmpty ? payee : !narration.isEmpty ? narration : leaf(account) }
}

public func templates(_ L: Ledger, pinned: [String], hidden: Set<String>, today now: String = Day.today()) -> [Template] {
    let since = Day.shift(now, -120), cur = Day.ym(now)
    var map: [String: Template] = [:]
    var order: [String] = []
    for t in L.txns {
        if t.date < since || t.synthetic || t.postings.count != 2 { continue }
        guard let cat = t.postings.first(where: { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }) else { continue }
        guard let fund = t.postings.first(where: { $0 !== cat && ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) }) else { continue }
        if cat.price != nil || fund.price != nil || cat.cost != nil || fund.currency != cat.currency { continue }
        guard let units = cat.units, let ccy = cat.currency else { continue }
        let kind: TxKind? = cat.account.hasPrefix("Income") ? .income : units < 0 ? nil : .expense
        guard let k = kind else { continue }
        let id = [t.payee, t.narration, cat.account, ccy].joined(separator: "|")
        if map[id] == nil {
            map[id] = Template(id: id, kind: k, payee: t.payee, narration: t.narration, account: cat.account, funding: fund.account, currency: ccy)
            order.append(id)
        }
        map[id]!.amounts.append(abs(units))
        map[id]!.dates.append(t.date)
        map[id]!.funding = fund.account
    }
    let prev = [1, 2, 3].map { Day.addMonth(cur, -$0) }
    var list: [Template] = []
    for id in order {
        guard var x = map[id], !hidden.contains(id) else { continue }
        var cnt: [Double: Int] = [:]
        var cntOrder: [Double] = []
        for a in x.amounts { if cnt[a] == nil { cntOrder.append(a) }; cnt[a, default: 0] += 1 }
        let top = cntOrder.max { cnt[$0]! < cnt[$1]! }!
        let topN = cnt[top]!
        x.fixed = topN >= 2 && Double(topN) / Double(x.amounts.count) >= 0.6 ? top : nil
        let months = Set(x.dates.map(Day.ym))
        var perMonth: [String: Int] = [:]
        for d in x.dates { perMonth[Day.ym(d), default: 0] += 1 }
        x.monthly = prev.allSatisfy { months.contains($0) } && perMonth.values.allSatisfy { $0 <= 2 }
        let days = x.dates.map { Int($0.suffix(2)) ?? 1 }.sorted()
        x.day = days[days.count / 2]
        x.due = x.monthly && !months.contains(cur) && (Int(now.suffix(2)) ?? 1) >= x.day - 2
        x.n = x.dates.count
        x.pinned = pinned.contains(id)
        if x.pinned || x.n >= 3 { list.append(x) }
    }
    list = list.enumerated().sorted { a, b in
        let x = a.element, y = b.element
        if x.pinned != y.pinned { return x.pinned }
        if x.pinned && y.pinned { return (pinned.firstIndex(of: x.id) ?? 0) < (pinned.firstIndex(of: y.id) ?? 0) }
        if x.due != y.due { return x.due }
        if x.n != y.n { return x.n > y.n }
        return a.offset < b.offset
    }.map { $0.element }
    return list
}

// MARK: - holdings

public struct Holding: Identifiable {
    public var id: String { acct + "|" + c + "|" + q }
    public let acct: String
    public let c: String
    public let q: String
    public let units: Double
    public let cost: Double
    public var avg: Double { units != 0 ? cost / units : 0 }
    public let px: Entry?
    public var value: Double? { px.map { units * $0.number } }
    public var pnl: Double? { value.map { $0 - cost } }
    public let lots: [Lot]
}

public func latestPrice(_ L: Ledger, _ c: String, _ quote: String) -> Entry? {
    var best: Entry? = nil
    for p in L.prices where p.currency == c && p.quote == quote && (best == nil || p.date >= best!.date) { best = p }
    return best
}

public func holdings(_ L: Ledger) -> [Holding] {
    var rows: [Holding] = []
    for (acct, lots) in L.inventory {
        var byC: [String: [Lot]] = [:]
        for l in lots where l.cost != nil && abs(l.units) > 1e-9 { byC[l.currency + "|" + (l.cost!.currency ?? ""), default: []].append(l) }
        for (k, ls) in byC {
            let parts = k.components(separatedBy: "|")
            let units = ls.reduce(0.0) { $0 + $1.units }
            let cost = ls.reduce(0.0) { $0 + $1.units * $1.cost!.number }
            rows.append(Holding(acct: acct, c: parts[0], q: parts[1], units: units, cost: cost, px: latestPrice(L, parts[0], parts[1]),
                                lots: ls.sorted { ($0.cost!.date ?? "") < ($1.cost!.date ?? "") }))
        }
    }
    return rows.sorted { ($0.value ?? $0.cost) > ($1.value ?? $1.cost) }
}
