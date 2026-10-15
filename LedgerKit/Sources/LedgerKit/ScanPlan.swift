import Foundation

// 截图记账, second half: what was read off a screenshot (ScanFields), turned into a 记一笔 draft with what
// the ledger already knows — the card behind "BOC Debit Card (4321)", how this payee was recorded before,
// whether the payment is already in the ledger, which purchase a refund belongs to.

/// what to check before saving
public enum ScanCheck: String, Equatable {
    /// no date on the screen: today's is used
    case date
    /// the paying account was guessed (or is the default)
    case funding
    /// the category was guessed
    case category
    /// a foreign card with no amount charged on the screen: the ledger's rate is used
    case charged
    /// a refund whose purchase wasn't found: the category to give back to
    case refundCategory
    /// money sent to a person: an expense, or lent to them
    case person
}

public struct ScanPlan {
    public var fields: ScanFields
    public var draft: Draft?
    public var checks: [ScanCheck] = []
    /// an entry already in the ledger that looks like this payment
    public var duplicate: Entry?
    /// a refund: the purchases it may belong to, most likely first
    public var refundOf: [Entry] = []
    /// how the card is remembered ("4321", or the method as written) and whether the account came from that
    public var cardKey: String?
    /// nothing to fill in (several payments on the screen, no amount read)
    public var problem: String?
}

/// "BOC Debit Card" in English and Chinese words the bank matching knows
private let englishBanks: [(String, String)] = [
    ("BOC", "中国银行"), ("ICBC", "工商"), ("CCB", "建设"), ("ABC", "农业"), ("CMB", "招商"), ("BOCOM", "交通"), ("COMM", "交通"),
    ("CGB", "广发"), ("SPDB", "浦发"), ("CIB", "兴业"), ("CMBC", "民生"), ("CITIC", "中信"), ("CEB", "光大"), ("PSBC", "邮储"),
    ("HXB", "华夏"), ("PAB", "平安"),
]

/// the account a card or payment method stands for: one remembered for it, else an open account whose name or
/// `name:` has its last four digits, else the bank (and debit / credit) it names
public func scanFunding(_ f: ScanFields, cards: [String: String], _ L: Ledger, _ D: Derived) -> (account: String?, sure: Bool) {
    let key = scanCardKey(f)
    if let k = key, let a = cards[k], D.openAccounts.contains(a) { return (a, true) }
    if let l4 = f.last4 {
        let hits = D.openAccounts.filter { a in
            guard a.hasPrefix("Assets:") || a.hasPrefix("Liabilities:") else { return false }
            if a.contains(l4) { return true }
            return L.accounts[a]?.meta.items.contains { ($0.1.stringValue ?? $0.1.display).contains(l4) } ?? false
        }
        if hits.count == 1 { return (hits[0], true) }
    }
    guard var m = f.method else { return (nil, false) }
    // English screens: BOC Debit Card → 中国银行 储蓄卡
    let words = Set(m.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
    for (code, zh) in englishBanks where words.contains(code) { m += " " + zh }
    if m.lowercased().contains("credit") { m += " 信用" }
    let src: ImportSource = f.source == .alipay ? .alipay : f.source == .wechat ? .wechat : .bank
    return (guessFunding(m, source: src, L, D), false)
}

/// how a card is remembered: its last four digits, else the method as written ("零钱通")
public func scanCardKey(_ f: ScanFields) -> String? {
    if let l = f.last4 { return l }
    guard let m = f.method?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
    return m
}

/// the payee as the ledger has it: the same name, a shorter or longer form of it ("广东岭南通股份有限公司" →
/// "岭南通"), or, for a starred name ("宝贝**店"), one with the same start and end; the platform for a shop on one
public func scanPayee(_ f: ScanFields, _ D: Derived) -> (name: String, known: Bool) {
    if let p = f.platform { return (p, D.payee(p) != nil) }
    let raw = (f.payee ?? f.payeeFull ?? "").trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return ("", false) }
    if D.payee(raw) != nil { return (raw, true) }
    if f.masked {
        let parts = raw.components(separatedBy: "*").filter { !$0.isEmpty }
        if let head = parts.first {
            let tail = parts.count > 1 ? parts.last! : ""
            if let p = D.payees.filter({ $0.name.hasPrefix(head) && $0.name.hasSuffix(tail) && $0.name.count > head.count }).max(by: { $0.n < $1.n }) {
                return (p.name, true)
            }
        }
        return (raw, false)
    }
    for name in [raw, f.payeeFull].compactMap({ $0 }) where name.count >= 2 {
        if let p = D.payees.filter({ $0.name.count >= 2 && (name.contains($0.name) || $0.name.contains(name)) }).max(by: { $0.n < $1.n }) {
            return (p.name, true)
        }
    }
    return (raw, false)
}

/// the category for a purchase on a platform: the one used for the most alike thing bought there before
/// (the longest piece of the item's name found in an earlier description)
func platformCategory(_ payee: String, item: String, _ L: Ledger) -> String? {
    let chars = Array(item)
    guard chars.count >= 2 else { return nil }
    var best: (Int, String)?
    for t in L.txns.reversed() where t.payee == payee {
        guard let cat = t.postings.first(where: { $0.account.hasPrefix("Expenses:") })?.account else { continue }
        let n = t.narration
        var len = 0
        // the longest run of the item's characters that the description contains
        for i in 0..<chars.count {
            var k = len + 1
            while i + k <= chars.count, n.contains(String(chars[i..<(i + k)])) { len = k; k += 1 }
        }
        if len >= 2, len > (best?.0 ?? 0) { best = (len, cat) }
    }
    return best?.1
}

public func scanPlan(_ f: ScanFields, _ L: Ledger, _ D: Derived, cards: [String: String] = [:], defaultFunding: String?, today: String = Day.today()) -> ScanPlan {
    var plan = ScanPlan(fields: f)
    if case .several(let n) = f.kind {
        plan.problem = tr("这张截图里有 \(n) 笔，请改用其中一笔的账单详情截图", "This screenshot shows \(n) payments; use the details screen of one of them")
        return plan
    }
    guard let amount = f.amount, amount > 0 else {
        plan.problem = tr("没有读出金额", "No amount found")
        return plan
    }
    let date = f.date ?? today
    if f.date == nil { plan.checks.append(.date) }
    let who = scanPayee(f, D)
    plan.cardKey = scanCardKey(f)
    var (funding, sure) = scanFunding(f, cards: cards, L, D)
    if funding == nil {
        // as this payee was paid before, else the usual account
        funding = D.payee(who.name)?.last.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? defaultFunding
    }
    if !sure { plan.checks.append(.funding) }
    let fund = funding ?? ""

    // already in the ledger?
    var row = ImportRow(id: 0, date: date)
    row.payee = who.name; row.amount = amount; row.orderID = f.orderNo ?? ""
    row.direction = f.kind == .refund ? .income : .expense
    let fc = fund.isEmpty ? nil : accountCurrency(fund, L, D)
    plan.duplicate = findDuplicate(row, funding: fc == f.currency ? (fund.isEmpty ? nil : fund) : nil, L)

    // a refund: the purchase it belongs to (paid with the same account, within 60 days before)
    if f.kind == .refund {
        let lo = Day.shift(date, -60)
        let cands = L.txns.filter { t in
            t.date >= lo && t.date <= date && !t.synthetic && !t.tags.contains("refund")
                && t.postings.contains { $0.account.hasPrefix("Expenses:") && ($0.units ?? 0) > 0 }
                && (fund.isEmpty || t.postings.contains { $0.account == fund && ($0.units ?? 0) < 0 })
                && (who.name.isEmpty || t.payee == who.name || (!who.known && f.masked && t.payee.hasPrefix(who.name.components(separatedBy: "*").first ?? "\u{0}")))
        }
        func spent(_ t: Entry) -> Double { t.postings.filter { $0.account.hasPrefix("Expenses:") }.reduce(0) { $0 + ($1.units ?? 0) } }
        plan.refundOf = cands.sorted { a, b in
            let ea = abs(spent(a) - amount) < 0.005, eb = abs(spent(b) - amount) < 0.005
            return ea != eb ? ea : a.date > b.date
        }
        if let t = plan.refundOf.first, plan.refundOf.count == 1 || abs(spent(t) - amount) < 0.005 && (plan.refundOf.count < 2 || abs(spent(plan.refundOf[1]) - amount) >= 0.005) {
            var d = refundDraft(t, L, D, defaultFunding: defaultFunding)
            d.date = date
            d.amount = jsNumberString(amount)
            if !fund.isEmpty { d.funding = fund }
            plan.draft = d
            return plan
        }
        var d = Draft()
        d.kind = .refund; d.date = date; d.payee = who.name; d.amount = jsNumberString(amount); d.currency = f.currency
        d.funding = fund
        d.narration = tr("退款", "Refund")
        plan.checks.append(.refundCategory)
        plan.draft = d
        return plan
    }

    var d = Draft()
    d.kind = .expense
    d.date = date
    d.payee = who.name
    d.funding = fund
    d.currency = f.currency
    d.amount = jsNumberString(amount)
    // what it was for: the screen's description, else how this payee is usually described
    if let n = f.note, !n.isEmpty { d.narration = String(n.prefix(20)) }
    else if let n = D.payee(who.name)?.narrations.first { d.narration = n }

    // the category: an alike purchase on the platform, as this payee before, by the app's own category
    var cat: String?
    if f.platform != nil, let item = f.note { cat = platformCategory(who.name, item: item, L) }
    if cat == nil {
        var r = ImportRow(id: 0, date: date)
        r.payee = who.known ? who.name : (f.payee ?? who.name)
        r.category = f.category ?? ""; r.narration = f.note ?? ""
        cat = guessCategory(r, L, D)
    }
    d.account = cat ?? ""
    if cat == nil || !who.known || f.platform != nil { plan.checks.append(.category) }
    if f.kind == .transfer { plan.checks.append(.person) }

    // another currency on the card: the receipt's rate, the amount charged, or the ledger's rate to check later
    if let fc = fc, fc != f.currency {
        if let r = f.rate, f.rateBase == f.currency, f.rateQuote == fc {
            d.byRate = true; d.rate = r
        } else if let c = f.charged, f.chargedCurrency == fc {
            d.paid = jsNumberString(c)
        } else if let r = convertAmount(L, 1, from: f.currency, to: fc, date: date) {
            d.byRate = true; d.rate = rateString(r)
            plan.checks.append(.charged)
        } else {
            plan.checks.append(.charged)
        }
        // a discount can't be listed on its own when the card is in another currency: noted instead
        if let x = f.discount { d.narration = [d.narration, tr("立减 \(toFixed(x, 2))", "discount \(toFixed(x, 2))")].filter { !$0.isEmpty }.joined(separator: " ") }
    } else if let x = f.discount, x > 0 {
        // the price before the discount, the discount as income (优惠)
        d.amount = jsNumberString(roundMoney(f.listPrice ?? amount + x, 2))
        d.discount = jsNumberString(x)
    }
    // quoted: a long number as text, kept exact
    if let o = f.orderNo { d.keepMeta = [KeptMeta(key: "order", value: quoted(o))] }
    d.edited = nil
    plan.draft = d
    return plan
}
