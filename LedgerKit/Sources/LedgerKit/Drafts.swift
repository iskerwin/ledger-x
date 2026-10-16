import Foundation

// MARK: - amount input

/// "12+8.5", "3×4", "1,234.5", "12,5" → number (nil if not a valid expression)
public func evalExpr(_ input: String) -> Double? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.range(of: #"^-?\d+,\d{1,2}$"#, options: .regularExpression) != nil { s = s.replacingOccurrences(of: ",", with: ".") }
    s = s.replacingOccurrences(of: #"[，,\s]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[×xX]"#, with: "*", options: .regularExpression)
        .replacingOccurrences(of: "÷", with: "/")
        .replacingOccurrences(of: #"[−–]"#, with: "-", options: .regularExpression)
    guard !s.isEmpty, s.range(of: #"^[\d.+\-*/()]+$"#, options: .regularExpression) != nil else { return nil }
    let sc = Scan(s)
    guard let n = sc.number(), sc.eof(), n.value.isFinite else { return nil }
    return n.value
}

/// like evalExpr but rounded to cents (the simple forms)
public func evalAmount(_ input: String) -> Double? {
    guard let v = evalExpr(input) else { return nil }
    let plain = input.trimmingCharacters(in: .whitespaces).range(of: #"^\d*\.?\d+$"#, options: .regularExpression) != nil
    return plain ? v : roundMoney(v, 2)
}

public func isExpression(_ s: String) -> Bool {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("-") { t.removeFirst() }
    return t.range(of: #"[+\-*/×÷]"#, options: .regularExpression) != nil
}

// MARK: - the entry form

public struct DraftRow: Equatable, Identifiable {
    public var id = UUID()
    public var account = ""
    public var amount = ""
    public var currency = "CNY"
    public var cost = ""
    public var price = ""
    public var flag = ""
    /// who a personal receivable row is with (`person:`)
    public var person = ""
    /// the line's other metadata (`category:` on an advance…), written back as it was
    public var meta: [String: String] = [:]
    public var ccyTouched = false
    public init(account: String = "", currency: String = "CNY") { self.account = account; self.currency = currency }
}

public enum DraftKind: String, CaseIterable, Identifiable {
    case expense, income, transfer, refund, multi, raw
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .expense: return tr("支出", "Expense")
        case .income: return tr("收入", "Income")
        case .transfer: return tr("转账", "Transfer")
        case .refund: return tr("退款", "Refund")
        case .multi: return tr("分录", "Split")
        case .raw: return tr("文本", "Text")
        }
    }
}

/// posting metadata on an advance (报销应收): the expense category it would have been
public let categoryMeta = "category"

/// the category written on an advance
public func advanceCategory(_ p: Posting) -> String? {
    guard let v = p.meta[categoryMeta] else { return nil }
    let s = (v.stringValue ?? v.display).trimmingCharacters(in: .whitespaces)
    return s.hasPrefix("Expenses:") ? s : nil
}

/// someone's part of an expense you paid (AA): it goes to the personal receivable, `person:` naming them
public struct Share: Equatable, Identifiable {
    public var id = UUID()
    public var person: String
    public var amount: String
    public init(person: String, amount: String = "") { self.person = person; self.amount = amount }
}

/// 组合付款: another account paying part of an expense (the main paying account pays the rest)
public struct ExtraFund: Equatable, Identifiable {
    public var id = UUID()
    public var account: String
    public var amount: String
    public init(account: String, amount: String = "") { self.account = account; self.amount = amount }
}

/// where a discount (优惠 / 立减 / 红包抵扣) is recorded unless another income account is picked
public let defaultDiscountAccount = "Income:Rewards"

public struct RefundOf: Equatable {
    public var path: String
    public var line: Int
    public var header: String
    public var link: String
}

/// the entry being edited: where it is and its text as it stands in the file
public struct Replacing: Equatable {
    public var path: String
    public var old: String
    public var date: String
    public var summary: String
    /// the text the form made of it before any change (saving that again changes nothing)
    public var baseline: String
    public init(path: String, old: String, date: String, summary: String, baseline: String) {
        self.path = path; self.old = old; self.date = date; self.summary = summary; self.baseline = baseline
    }
}

/// `exchange_rate: "1 USD = 7.80000 HKD"` as written, kept while the amounts are `amount` → `toAmount`
public struct KeptRate: Equatable {
    public var text: String
    public var amount: Double
    public var toAmount: Double
    public init(text: String, amount: Double, toAmount: Double) { self.text = text; self.amount = amount; self.toAmount = toAmount }
    /// the currency quoted per one unit ("USD" in "1 USD = 7.80000 HKD")
    var base: String? {
        let w = text.split(separator: " ")
        return w.count >= 2 && w[0] == "1" ? String(w[1]) : nil
    }
}

public struct KeptMeta: Equatable {
    public var key: String
    /// as written in Beancount: a string in quotes, anything else as it is
    public var value: String
}

public struct Draft: Equatable {
    public var kind: DraftKind = .expense
    public var date = Day.today()
    public var payee = ""
    public var narration = ""
    public var amount = ""
    public var currency = "CNY"
    public var account = ""
    public var funding = ""
    public var to = ""
    public var toAmount = ""
    public var paid = ""
    public var reimb = false
    public var link = ""
    public var tags: [String] = []
    public var edited: String? = nil
    public var refundOf: RefundOf? = nil
    public var flag = "*"
    public var tagsText = ""
    public var rows: [DraftRow] = [DraftRow(), DraftRow()]
    public var raw = ""
    /// tags of the events this entry belongs to (#tag on the transaction; not on transfers)
    public var events: [String] = []
    /// the events were picked by hand: don't follow the date any more
    public var eventsTouched = false
    /// AA: split this expense with others
    public var split = false
    /// AA: the others' parts of an expense (your part is what is left)
    public var shares: [Share] = []
    /// the parts were typed by hand: don't even them out again when the amount changes
    public var sharesEdited = false
    /// 凭证类型 of a reimbursable expense (发票 / 收据 / 无), written as `voucher:`
    public var voucher = ""
    /// who the personal receivable is with, when it is the category or paying account
    /// (someone paid for you: the paying account is Assets:Receivable:Personal)
    public var person = ""
    /// 组合付款: other accounts paying part of an expense
    public var extraFunds: [ExtraFund] = []
    /// 优惠: the part of an expense's price not paid (recorded as income), as typed
    public var discount = ""
    /// 本期补差: a subscription charge paid on top of the previous one (`topup: TRUE`), not a new period
    public var topup = false
    /// paid from an account in another currency: the receipt's rate (1 expense currency = `rate` account
    /// currency, "1CNY=1.17912HKD") instead of the amount charged; written as it is (23.00 CNY @ 1.17912 HKD)
    public var byRate = false
    public var rate = ""
    /// editing an entry already in the ledger (instead of adding one)
    public var replacing: Replacing? = nil
    /// what the form doesn't show, kept as it was: the other links and the transaction's metadata
    public var keepLinks: [String] = []
    public var keepMeta: [KeptMeta] = []
    /// an exchange being edited: its `exchange_rate:` as the bank wrote it, and the amounts it went with
    public var fxRate: KeptRate? = nil
    public var discountAccount = defaultDiscountAccount
    /// filled in from a screenshot: what it keeps of it (the card to remember, the rate to apply again)
    public var scan: ScanMemo? = nil
    public init() {}
}

/// a discount applies to a plain expense; a reimbursed or shared one is entered at what was actually paid
public func discountAllowed(_ d: Draft) -> Bool { d.kind == .expense && !d.reimb && !d.split }

/// The paying side of an expense with 组合付款 or 优惠: the main account (what is left), the other accounts' parts,
/// then the discount. nil when something doesn't add up, or an account is in another currency.
/// the currency an account is used in: what it has been used with, else the one its open line allows (when just one)
/// the account has held `c` before, or its open line allows it (a multi-currency account, say)
public func accountTakes(_ a: String, _ c: String, _ L: Ledger) -> Bool {
    if L.accounts[a]?.currencies.contains(c) == true { return true }
    return L.final[a]?[c] != nil
}

public func accountCurrency(_ a: String, _ L: Ledger, _ D: Derived) -> String? {
    D.acctCcy[a] ?? L.accounts[a].flatMap { $0.currencies.count == 1 ? $0.currencies[0] : nil }
}

func payingPostings(_ d: Draft, total amt: Double, _ L: Ledger, _ D: Derived) -> [TxPosting]? {
    var disc = 0.0
    if discountAllowed(d) && !d.discount.trimmingCharacters(in: .whitespaces).isEmpty {
        // a discount has to leave something to pay
        guard let v = evalAmount(d.discount), v >= 0, v < amt - 0.004 else { return nil }
        disc = v
    }
    var out: [TxPosting] = []
    var rest = amt - disc
    for x in d.extraFunds {
        let a = x.account.trimmingCharacters(in: .whitespaces)
        if a.isEmpty && x.amount.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard !a.isEmpty, a != d.funding, let v = evalAmount(x.amount), v > 0, (accountCurrency(a, L, D) ?? d.currency) == d.currency else { return nil }
        rest -= v
        out.append(TxPosting(account: a, amount: -v, currency: d.currency))
    }
    rest = roundMoney(rest, 2)
    guard rest > -0.004, (accountCurrency(d.funding, L, D) ?? d.currency) == d.currency else { return nil }
    if rest > 0.004 { out.insert(TxPosting(account: d.funding, amount: -rest, currency: d.currency), at: 0) }
    if disc > 0.004 {
        let acct = d.discountAccount.trimmingCharacters(in: .whitespaces)
        guard acct.hasPrefix("Income:") else { return nil }
        out.append(TxPosting(account: acct, amount: -roundMoney(disc, 2), currency: d.currency))
    }
    return out
}

/// What the main paying account is left to pay with 组合付款 / 优惠 (nil when the amount isn't filled in yet).
public func comboRest(_ d: Draft) -> Double? {
    guard let amt = evalAmount(d.amount), amt > 0 else { return nil }
    var rest = amt
    if discountAllowed(d) { rest -= evalAmount(d.discount) ?? 0 }
    for x in d.extraFunds { rest -= evalAmount(x.amount) ?? 0 }
    return roundMoney(rest, 2)
}

/// Why 组合付款 / 优惠 can't be written as it stands, in words for the form; nil when it can.
public func comboIssue(_ d: Draft, _ L: Ledger, _ D: Derived) -> String? {
    guard hasCombo(d) else { return nil }
    for x in d.extraFunds {
        let a = x.account.trimmingCharacters(in: .whitespaces), v = x.amount.trimmingCharacters(in: .whitespaces)
        if a.isEmpty && v.isEmpty { continue }
        if a.isEmpty { return tr("有一行没选付款账户", "A row has no account") }
        if a == d.funding { return tr("其他付款账户不能和主账户相同", "Another account can't be the main one") }
        guard let n = evalAmount(v), n > 0 else { return tr("%@ 的金额要大于 0", "Enter an amount for %@").replacingOccurrences(of: "%@", with: leaf(a)) }
        if let c = accountCurrency(a, L, D), c != d.currency { return tr("组合付款的账户要与支出同币种", "Accounts in a combination must be in the expense's currency") }
    }
    if let c = accountCurrency(d.funding, L, D), c != d.currency { return tr("组合付款的账户要与支出同币种", "Accounts in a combination must be in the expense's currency") }
    if discountAllowed(d), !d.discount.trimmingCharacters(in: .whitespaces).isEmpty {
        guard (evalAmount(d.discount) ?? -1) >= 0 else { return tr("优惠金额不正确", "The discount isn't a number") }
        if !d.discountAccount.hasPrefix("Income:") { return tr("优惠要记到收入科目", "A discount goes to an income account") }
    }
    if let r = comboRest(d), r < -0.004 { return tr("其他账户和优惠加起来超过了总额", "The other accounts and the discount come to more than the total") }
    if let r = comboRest(d), r < 0.004, discountAllowed(d), (evalAmount(d.discount) ?? 0) > 0, d.extraFunds.allSatisfy({ $0.account.isEmpty }) {
        return tr("优惠不能等于总额", "The discount can't be the whole price")
    }
    return nil
}

/// the form uses 组合付款 or 优惠
public func hasCombo(_ d: Draft) -> Bool {
    d.kind == .expense && (d.extraFunds.contains { !$0.account.isEmpty || !$0.amount.isEmpty }
        || (discountAllowed(d) && !d.discount.trimmingCharacters(in: .whitespaces).isEmpty))
}

public func parseTagsLinks(_ s: String) -> (tags: [String], links: [String]) {
    var tags: [String] = [], links: [String] = []
    for w in s.components(separatedBy: CharacterSet(charactersIn: " \t,，")) where !w.isEmpty {
        if w.hasPrefix("^") { let v = String(w.dropFirst()); if !v.isEmpty { links.append(v) } }
        else { let v = w.hasPrefix("#") ? String(w.dropFirst()) : w; if !v.isEmpty { tags.append(v) } }
    }
    return (tags, links)
}

/// `defaultCurrency`: currency for expenses, income and refunds whatever account pays (nil = the account's own)
public func newDraft(_ kind: DraftKind = .expense, _ D: Derived, defaultFunding: String?, defaultCurrency: String? = nil) -> Draft {
    var d = Draft()
    d.kind = kind
    let funding = defaultFunding.flatMap { D.openAccounts.contains($0) ? $0 : nil } ?? D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).first ?? ""
    d.funding = funding
    let own = D.acctCcy[funding] ?? defaultCurrency ?? "CNY"
    d.currency = kind == .transfer || kind == .multi ? own : defaultCurrency ?? own
    d.rows = [DraftRow(), DraftRow(account: funding, currency: own)]
    return d
}

func multiTx(_ d: Draft, _ L: Ledger) -> TxDraft? {
    guard var tx = multiTx0(d, L) else { return nil }
    keepParts(&tx, d)
    return tx
}

func multiTx0(_ d: Draft, _ L: Ledger) -> TxDraft? {
    let tl = parseTagsLinks(d.tagsText)
    let rows = d.rows.filter { !$0.account.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !d.date.isEmpty, !rows.isEmpty else { return nil }
    var tx = TxDraft(date: d.date)
    tx.flag = d.flag.isEmpty ? "*" : d.flag
    tx.payee = d.payee.trimmingCharacters(in: .whitespaces)
    tx.narration = d.narration.trimmingCharacters(in: .whitespaces)
    tx.tags = tl.tags; tx.links = tl.links
    for e in d.events where !tx.tags.contains(e) { tx.tags.append(e) }
    tx.postings = rows.map { r in
        let a = r.amount.trimmingCharacters(in: .whitespaces)
        var units: String? = nil
        if !a.isEmpty {
            if a.range(of: #"^[-+]?\d+,\d{1,2}$"#, options: .regularExpression) != nil {
                units = a.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: #"^\+"#, with: "", options: .regularExpression)
            } else if a.range(of: #"^[-+]?\d[\d,]*(\.\d+)?$"#, options: .regularExpression) != nil {
                units = a.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: #"^\+"#, with: "", options: .regularExpression)
            } else if let v = evalExpr(a) {
                units = numText(v)
            } else { units = a }
        }
        if let u = units, u.range(of: #"^-?\d+(\.\d*)?$"#, options: .regularExpression) != nil {
            // pad to the currency's usual decimals (at most 2), as in "12.50 CNY"
            let precText = L.commodities[r.currency]?["precision"]?.display
            let prec = min(2, Int(precText ?? "2") ?? 2)
            let dec = u.contains(".") ? u.split(separator: ".", omittingEmptySubsequences: false)[1].count : 0
            if dec < prec { units = toFixed(Double(u) ?? 0, prec) }
        }
        let pr = r.price.trimmingCharacters(in: .whitespaces)
        var p = TxPosting(account: r.account.trimmingCharacters(in: .whitespaces), units: units, currency: units != nil ? r.currency : nil,
                          flag: r.flag.isEmpty ? nil : r.flag, cost: r.cost.trimmingCharacters(in: .whitespaces).isEmpty ? nil : r.cost.trimmingCharacters(in: .whitespaces),
                          price: pr.isEmpty ? nil : (pr.hasPrefix("@") ? pr : "@ " + pr))
        p.meta = r.meta.keys.sorted().map { ($0, r.meta[$0]!) }
        let who = r.person.trimmingCharacters(in: .whitespaces)
        if isPersonal(p.account) && !who.isEmpty { p.meta.insert((personMeta, who), at: 0) }
        return p
    }
    return tx
}

/// the institution an account is at: its third part (Assets:Bank:ZABank:Cash → ZABank, Assets:Bank:HSBC → HSBC)
public func institution(_ account: String) -> String {
    let p = account.components(separatedBy: ":")
    return p.count > 2 ? p[2] : p.last ?? account
}

/// moving money between your own accounts: a transfer, or an exchange from one currency to another
public func isTransferTag(_ t: Entry) -> Bool { t.tags.contains("transfer") || t.tags.contains("fx") }

func draftTx(_ d: Draft, _ L: Ledger, _ D: Derived) -> TxDraft? {
    guard var tx = draftTx0(d, L, D) else { return nil }
    if d.kind != .multi && !d.flag.isEmpty { tx.flag = d.flag }
    keepParts(&tx, d)
    return tx
}

/// what the form doesn't show, carried over when an entry is edited: its other links and its metadata
func keepParts(_ tx: inout TxDraft, _ d: Draft) {
    for l in d.keepLinks where !tx.links.contains(l) { tx.links.append(l) }
    for m in d.keepMeta where !tx.meta.contains(where: { $0.0 == m.key }) { tx.meta.append((m.key, m.value)) }
}

func draftTx0(_ d: Draft, _ L: Ledger, _ D: Derived) -> TxDraft? {
    guard !d.date.isEmpty, let amt = evalAmount(d.amount), amt > 0 else { return nil }
    var tx = TxDraft(date: d.date)
    tx.payee = d.payee.trimmingCharacters(in: .whitespaces)
    tx.narration = d.narration.trimmingCharacters(in: .whitespaces)
    tx.tags = d.tags
    let lk = d.link.trimmingCharacters(in: .whitespaces)
    tx.links = lk.isEmpty ? [] : [lk.hasPrefix("^") ? String(lk.dropFirst()) : lk]
    if d.kind == .transfer {
        guard !d.funding.isEmpty, !d.to.isEmpty else { return nil }
        let fc = d.currency, tc = accountCurrency(d.to, L, D) ?? fc
        if d.to.hasPrefix("Liabilities:CreditCard") {
            if tx.payee.isEmpty { tx.payee = "\(leaf(d.to)) Credit Card" }
            if tx.narration.isEmpty { tx.narration = "Repayment" }
            tx.postings = [TxPosting(account: d.to, amount: amt, currency: fc), TxPosting(account: d.funding, amount: -amt, currency: fc)]
        } else {
            let exchange = tc != fc && (evalAmount(d.toAmount) ?? 0) > 0
            // a currency exchange is #fx with the institution that received it as payee; else a plain #transfer
            if tx.payee.isEmpty { tx.payee = exchange ? institution(d.to) : "Transfer" }
            if tx.narration.isEmpty { tx.narration = "\(D.shortName(d.funding)) -> \(D.shortName(d.to))" }
            let tag = exchange ? "fx" : "transfer"
            tx.tags.removeAll { $0 == (exchange ? "transfer" : "fx") }
            if !tx.tags.contains(tag) { tx.tags.insert(tag, at: 0) }
            if exchange, let ta = evalAmount(d.toAmount) {
                // as the bank wrote it while the amounts stay; else worked out, quoted the same way round
                if let k = d.fxRate, abs(k.amount - amt) < 0.005, abs(k.toAmount - ta) < 0.005 {
                    tx.meta.append(("exchange_rate", k.text))
                } else if d.fxRate?.base == tc {
                    tx.meta.append(("exchange_rate", "1 \(tc) = \(moneyText(decimalOf(amt) / decimalOf(ta), 5)) \(fc)"))
                } else {
                    tx.meta.append(("exchange_rate", "1 \(fc) = \(moneyText(decimalOf(ta) / decimalOf(amt), 5)) \(tc)"))
                }
                var toP = TxPosting(account: d.to, amount: ta, currency: tc)
                toP.priceTotal = amt; toP.priceCcy = fc
                tx.postings = [TxPosting(account: d.funding, amount: -amt, currency: fc), toP]
            } else {
                // no amount received in the other currency: only into an account that holds this one too
                if tc != fc && !accountTakes(d.to, fc, L) { return nil }
                tx.postings = [TxPosting(account: d.funding, amount: -amt, currency: fc), TxPosting(account: d.to, amount: amt, currency: fc)]
            }
        }
        return tx
    }
    guard !d.account.isEmpty, !d.funding.isEmpty else { return nil }
    for e in d.events where !tx.tags.contains(e) { tx.tags.append(e) }
    let sgn: Double = d.kind == .expense ? 1 : -1 // income & refund reduce the category
    let fc = accountCurrency(d.funding, L, D) ?? d.currency
    var catAccount = d.account
    if d.kind == .expense && d.reimb {
        catAccount = D.receivable
        if !tx.tags.contains("reimbursed") { tx.tags.append("reimbursed") }
    }
    if d.kind == .refund && !tx.tags.contains("refund") { tx.tags.append("refund") }
    if d.kind == .expense && !d.reimb && d.split && !d.shares.isEmpty {
        // AA: your part to the category, theirs to their receivables; paying in another currency isn't supported
        guard fc == d.currency || (evalAmount(d.paid) == nil && !(d.byRate && evalAmount(d.rate) != nil)) else { return nil }
        // the bill's amount is paid as it is: the account must hold the bill's currency
        if fc != d.currency && !accountTakes(d.funding, d.currency, L) { return nil }
        var theirs: [TxPosting] = []
        var sum = 0.0
        for x in d.shares {
            let who = x.person.trimmingCharacters(in: .whitespaces)
            guard let v = evalAmount(x.amount), v > 0, !who.isEmpty else { return nil }
            sum += v
            theirs.append(personalPosting(who, amount: v, currency: d.currency))
        }
        let mine = roundMoney(amt - sum, 2)
        guard mine > -0.004 else { return nil }
        let paying: [TxPosting]
        if hasCombo(d) { guard let p = payingPostings(d, total: amt, L, D) else { return nil }; paying = p }
        else { paying = [TxPosting(account: d.funding, amount: -amt, currency: d.currency)] }
        tx.postings = (mine > 0.004 ? [TxPosting(account: catAccount, amount: mine, currency: d.currency)] : []) + theirs + paying
        if d.topup && !tx.links.isEmpty { tx.meta.append((subTopupMeta, "TRUE")) }
        return tx
    }
    var cat = TxPosting(account: catAccount, amount: sgn * amt, currency: d.currency)
    // an advance keeps the category it would have had, for the expense claim (支出类型)
    if d.kind == .expense && d.reimb && d.account.hasPrefix("Expenses:") { cat.meta = [(categoryMeta, d.account)] }
    if d.kind == .expense && d.reimb && !d.voucher.trimmingCharacters(in: .whitespaces).isEmpty {
        cat.meta.append((voucherMeta, d.voucher.trimmingCharacters(in: .whitespaces)))
    }
    if hasCombo(d) {
        guard let paying = payingPostings(d, total: amt, L, D) else { return nil }
        tx.postings = [cat] + paying
    } else if fc != d.currency, d.byRate, let r = Double(d.rate.trimmingCharacters(in: .whitespaces)), r > 0 {
        // the receipt's rate as it is; the account is charged what it comes to, to the cent
        cat.suffix = "@ \(d.rate.trimmingCharacters(in: .whitespaces)) \(fc)"
        tx.postings = [cat, TxPosting(account: d.funding, amount: -sgn * mulMoney(amt, r, 2), currency: fc)]
    } else if fc != d.currency, let paid = evalAmount(d.paid), paid > 0 {
        // a per-unit price rounded to 5 places can miss the paid total by more than the tolerance on
        // large amounts (9999.99 USD → 0.03 CNY off); then write the exact total instead
        let unit = moneyText(decimalOf(paid) / decimalOf(amt), 5)
        let back = rounded(decimalOf(Double(unit) ?? 0) * decimalOf(amt), 2)
        cat.suffix = back != rounded(decimalOf(paid), 2) ? "@@ \(moneyText(paid, 2)) \(fc)" : "@ \(unit) \(fc)"
        tx.postings = [cat, TxPosting(account: d.funding, amount: -sgn * paid, currency: fc)]
    } else {
        // no rate and no amount charged: only for an account that holds the bill's currency too, else the bill's
        // amount would land in it as a second currency (draftMissing says what to fill in)
        if fc != d.currency && !accountTakes(d.funding, d.currency, L) { return nil }
        tx.postings = [cat, TxPosting(account: d.funding, amount: -sgn * amt, currency: d.currency)]
    }
    let who = d.person.trimmingCharacters(in: .whitespaces)
    if !who.isEmpty {
        for i in tx.postings.indices where isPersonal(tx.postings[i].account) { tx.postings[i].meta = [(personMeta, who)] }
    }
    // 本期补差 only means something on a subscription's charge
    if d.topup && d.kind == .expense && !tx.links.isEmpty { tx.meta.append((subTopupMeta, "TRUE")) }
    return tx
}

/// What still has to be filled in before the form makes a transaction (shown when 完成 is tapped too early);
/// the same conditions `draftTx` / `multiTx` need, said in words. nil when nothing is missing.
public func draftMissing(_ d: Draft, _ L: Ledger, _ D: Derived) -> String? {
    func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
    switch d.kind {
    case .raw:
        return blank(d.raw) ? tr("请输入 Beancount 文本", "Enter the Beancount text") : nil
    case .multi:
        if d.date.isEmpty { return tr("请选择日期", "Choose a date") }
        if d.rows.filter({ !blank($0.account) }).count < 2 { return tr("至少要填两行分录", "Fill in at least two postings") }
        return nil
    default: break
    }
    if d.date.isEmpty { return tr("请选择日期", "Choose a date") }
    guard let amt = evalAmount(d.amount) else { return tr("请输入金额", "Enter an amount") }
    guard amt > 0 else { return tr("金额要大于 0", "The amount must be more than 0") }
    if d.kind == .transfer {
        if d.funding.isEmpty { return tr("请选择转出账户", "Choose the account to transfer from") }
        if d.to.isEmpty { return tr("请选择转入账户", "Choose the account to transfer to") }
        let fc = d.currency, tc = accountCurrency(d.to, L, D) ?? fc
        if tc != fc && (evalAmount(d.toAmount) ?? 0) <= 0 && !accountTakes(d.to, fc, L) {
            return tr("转入账户是 \(tc)，请填写入账金额", "The receiving account is in \(tc): fill in the amount received")
        }
        return nil
    }
    if d.account.isEmpty {
        return d.kind == .income ? tr("请选择收入科目", "Choose an income category") : tr("请选择支出科目", "Choose an expense category")
    }
    if d.funding.isEmpty {
        switch d.kind {
        case .income: return tr("请选择收款账户", "Choose the receiving account")
        case .refund: return tr("请选择退回的账户", "Choose the account refunded to")
        default: return tr("请选择付款账户", "Choose the paying account")
        }
    }
    let fc = accountCurrency(d.funding, L, D) ?? d.currency
    if d.kind == .expense && !d.reimb && d.split && !d.shares.isEmpty {
        if !(fc == d.currency || (evalAmount(d.paid) == nil && !(d.byRate && evalAmount(d.rate) != nil)))
            || (fc != d.currency && !accountTakes(d.funding, d.currency, L)) {
            return tr("AA 分摊暂不支持用另一种货币付款", "Splitting isn't supported when paying in another currency")
        }
        var sum = 0.0
        for x in d.shares {
            guard let v = evalAmount(x.amount), v > 0, !blank(x.person) else {
                return tr("AA 分摊：每一位都要填名字和金额", "Split: give each person a name and an amount")
            }
            sum += v
        }
        if roundMoney(amt - sum, 2) <= -0.004 { return tr("AA 分摊的金额加起来超过了总额", "The split parts add up to more than the total") }
    }
    if hasCombo(d) {
        if discountAllowed(d) && !blank(d.discount) {
            guard let v = evalAmount(d.discount), v >= 0, v < amt - 0.004 else { return tr("优惠金额要小于总额", "The discount must be less than the total") }
            if !d.discountAccount.trimmingCharacters(in: .whitespaces).hasPrefix("Income:") {
                return tr("优惠要记到一个收入科目", "Choose an income category for the discount")
            }
        }
        for x in d.extraFunds where !(blank(x.account) && blank(x.amount)) {
            let a = x.account.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, let v = evalAmount(x.amount), v > 0 else { return tr("组合付款：每个账户都要填金额", "Combined payment: give each account an amount") }
            if a == d.funding { return tr("组合付款里的账户不能和主付款账户相同", "A combined payment account can't be the main paying account") }
            if (accountCurrency(a, L, D) ?? d.currency) != d.currency {
                return tr("组合付款的账户要与账单同一币种", "Combined payment accounts must be in the bill's currency")
            }
        }
        if fc != d.currency { return tr("组合付款时，付款账户要与账单同一币种", "With a combined payment the paying account must be in the bill's currency") }
        if payingPostings(d, total: amt, L, D) == nil { return tr("组合付款的金额加起来超过了总额", "The combined payment adds up to more than the total") }
        return nil
    }
    // an account in another currency needs the rate or the amount charged, unless it holds the bill's currency too
    if fc != d.currency && draftRate(d) == nil && !accountTakes(d.funding, d.currency, L) {
        return d.kind == .income
            ? tr("收款账户是 \(fc)，请填写汇率或入账金额", "The receiving account is in \(fc): fill in the rate or the amount received")
            : tr("付款账户是 \(fc)，请填写汇率或扣款金额", "The paying account is in \(fc): fill in the rate or the amount charged")
    }
    return nil
}

/// The Beancount text for the form as it is now.
public func draftText(_ d: Draft, _ L: Ledger, _ D: Derived, explicit: Bool = true) -> String {
    if d.kind == .raw { return d.raw }
    if let e = d.edited { return e }
    if d.kind == .multi {
        guard var tx = multiTx(d, L) else { return "" }
        var text = formatTxn(tx)
        // write auto-balanced amounts out explicitly (skipped when lots/costs are involved)
        if explicit && !tx.postings.contains(where: { $0.cost != nil }) {
            let r = checkText(text, L)
            if r.ok, let t = r.entries.first(where: { $0.type == .txn }) {
                let ip = t.postings.filter { $0.interpolated }
                if !ip.isEmpty {
                    tx.postings = tx.postings.flatMap { p -> [TxPosting] in
                        guard p.units == nil && p.price == nil else { return [p] }
                        return ip.filter { $0.account == p.account }.map { x in
                            var q = p
                            q.units = numText(x.units ?? 0)
                            q.currency = x.currency
                            return q
                        }
                    }
                    text = formatTxn(tx)
                }
            }
        }
        return text
    }
    guard let tx = draftTx(d, L, D) else { return "" }
    // the first AA split opens the personal receivable along with the expense
    let opens = sharesNeedOpen(d, L) ? [personalOpenLine(L, date: d.date)].compactMap { $0 } : []
    return (opens + [formatTxn(tx)]).joined(separator: "\n\n")
}

/// an AA split while the ledger has no personal receivable yet
public func sharesNeedOpen(_ d: Draft, _ L: Ledger) -> Bool {
    d.kind == .expense && !d.reimb && d.split && !d.shares.isEmpty && personalOpenLine(L, date: d.date) != nil
}

/// the form's text is exactly one transaction (not when it also opens the personal receivable)
public func draftIsSingle(_ d: Draft, _ L: Ledger) -> Bool { d.kind != .raw && !sharesNeedOpen(d, L) }

// MARK: - validation & where things go

public struct Validation {
    public var ok: Bool
    public var msg: String?
    public var entries: [Entry]
    public var warnings: [LedgerError]
    public var txn: Entry? { entries.first { $0.type == .txn } }
}

public func validateText(_ text: String, _ L: Ledger, single: Bool = true) -> Validation {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Validation(ok: false, msg: "", entries: [], warnings: []) }
    let r = checkText(text, L)
    let txns = r.entries.filter { $0.type == .txn }
    if single && (txns.count != 1 || r.entries.count != 1) {
        return Validation(ok: false, msg: r.msg ?? tr("这里应当正好是一笔交易", "This must be exactly one transaction"), entries: r.entries, warnings: r.warnings)
    }
    if r.ok && txns.contains(where: { $0.postings.count < 2 }) {
        return Validation(ok: false, msg: tr("交易至少需要两条分录", "A transaction needs at least two postings"), entries: r.entries, warnings: r.warnings)
    }
    return Validation(ok: r.ok, msg: r.msg, entries: r.entries, warnings: r.warnings)
}

public let TYPE_ZH: [EntryType: String] = [.txn: "交易", .balance: "余额断言", .price: "价格", .open: "开户", .close: "关户", .commodity: "商品",
                                           .pad: "补齐", .note: "备注", .event: "事件", .document: "文档", .query: "查询", .custom: "自定义"]

/// What a file in the layout holds (the keys of ledger-x.json's "files").
public enum LayoutKind: String, CaseIterable, Codable, Identifiable {
    case transactions, accounts, balance, price, commodity, budget, subscriptions, document, note, query
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .transactions: return tr("交易", "Transactions")
        case .accounts: return tr("开户 / 关户", "Open / close")
        case .balance: return tr("余额断言 / pad", "Balance / pad")
        case .price: return tr("价格", "Prices")
        case .commodity: return tr("商品", "Commodities")
        case .budget: return tr("预算", "Budgets")
        case .subscriptions: return tr("订阅", "Subscriptions")
        case .document: return tr("票据", "Documents")
        case .note: return tr("事件 / 备注", "Events / notes")
        case .query: return tr("查询", "Queries")
        }
    }
    public static func of(_ e: Entry) -> LayoutKind? {
        switch e.type {
        case .txn: return .transactions
        case .open, .close: return .accounts
        case .balance, .pad: return .balance
        case .price: return .price
        case .commodity: return .commodity
        case .document: return .document
        case .note, .event: return .note
        case .query: return .query
        case .custom where e.name == "budget": return .budget
        case .custom where e.name == "subscription": return .subscriptions
        default: return nil
        }
    }
}

/// transactions touching `account` (or its sub-accounts) go to `file`
public struct LayoutRule: Codable, Equatable, Hashable {
    public var account: String
    public var file: String
    public init(account: String, file: String) { self.account = account; self.file = file }
    public func matches(_ e: Entry) -> Bool {
        let a = account.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return false }
        return e.postings.contains { $0.account == a || $0.account.hasPrefix(a + ":") }
    }
}

/// a saved search on 明细
public struct QuickSearch: Codable, Equatable, Identifiable, Hashable {
    public var name: String
    public var query: String
    public var id: String { name + "|" + query }
    public init(name: String, query: String) { self.name = name; self.query = query }
}

/// ledger-x.json in the repository root: where each kind of directive is written, shared by every device
public struct LedgerXConfig: Codable, Equatable {
    public static let path = "ledger-x.json"
    public var files: [String: String] = [:]
    public var rules: [LayoutRule] = []
    public var receivable: String?
    /// link spellings for payees (polyphones, preferred names): "岭南通 羊城通": "yangchengtong"
    public var slugs: [String: String] = [:]
    /// payslip templates, one per employer
    public var payslips: [PayslipTemplate]?
    /// accounts (and their sub-accounts) left out of 净资产 and its trend
    public var netWorthExclude: [String]?
    /// accounts (and their sub-accounts) left out of 资产负债表
    public var balanceExclude: [String]?
    /// the file the ledger starts from (main.bean when not given)
    public var main: String?
    /// 记账偏好: the paying account and currency of a new entry
    public var defaultFunding: String?
    public var defaultCurrency: String?
    /// a single expense this large is unusual (值得留意) and left out of the forecast's daily average; 0 = never
    public var largeExpense: Double?
    /// 值得留意 items checked and found fine
    public var alertsConfirmed: [String]?
    /// link problems and subscription suggestions set aside
    public var linksIgnored: [String]?
    public var subsIgnored: [String]?
    /// 常用交易 pinned to the front, and the ones not offered
    public var templatesPinned: [String]?
    public var templatesHidden: [String]?
    /// 快速搜索 on 明细: a name and what goes in the search box ("出差和旅行": "#出差|#旅行"), in order
    public var searches: [QuickSearch]?
    /// 截图记账: a card's last four digits (or a method as written, "零钱通") → the account it is
    public var scanCards: [String: String]?

    public init(files: [String: String] = [:], rules: [LayoutRule] = [], receivable: String? = nil, slugs: [String: String] = [:]) {
        self.files = files; self.rules = rules; self.receivable = receivable; self.slugs = slugs
    }

    enum CodingKeys: String, CodingKey {
        case files, rules, receivable, slugs, payslips
        case netWorthExclude = "networth_exclude", balanceExclude = "balance_exclude"
        case main, defaultFunding = "default_funding", defaultCurrency = "default_currency", largeExpense = "large_expense"
        case alertsConfirmed = "alerts_confirmed", linksIgnored = "links_ignored", subsIgnored = "subs_ignored"
        case templatesPinned = "templates_pinned", templatesHidden = "templates_hidden"
        case searches
        case scanCards = "scan_cards"
    }

    /// every key is optional, so a hand-written file with only some of them still loads
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        rules = try c.decodeIfPresent([LayoutRule].self, forKey: .rules) ?? []
        receivable = try c.decodeIfPresent(String.self, forKey: .receivable)
        slugs = try c.decodeIfPresent([String: String].self, forKey: .slugs) ?? [:]
        payslips = try? c.decodeIfPresent([PayslipTemplate].self, forKey: .payslips)
        netWorthExclude = try? c.decodeIfPresent([String].self, forKey: .netWorthExclude)
        balanceExclude = try? c.decodeIfPresent([String].self, forKey: .balanceExclude)
        main = try? c.decodeIfPresent(String.self, forKey: .main)
        defaultFunding = try? c.decodeIfPresent(String.self, forKey: .defaultFunding)
        defaultCurrency = try? c.decodeIfPresent(String.self, forKey: .defaultCurrency)
        largeExpense = try? c.decodeIfPresent(Double.self, forKey: .largeExpense)
        alertsConfirmed = try? c.decodeIfPresent([String].self, forKey: .alertsConfirmed)
        linksIgnored = try? c.decodeIfPresent([String].self, forKey: .linksIgnored)
        subsIgnored = try? c.decodeIfPresent([String].self, forKey: .subsIgnored)
        templatesPinned = try? c.decodeIfPresent([String].self, forKey: .templatesPinned)
        templatesHidden = try? c.decodeIfPresent([String].self, forKey: .templatesHidden)
        searches = try? c.decodeIfPresent([QuickSearch].self, forKey: .searches)
        scanCards = try? c.decodeIfPresent([String: String].self, forKey: .scanCards)
    }

    /// the same settings with an account renamed (its sub-accounts too); nil when nothing refers to it
    public func renamingAccount(_ from: String, to: String) -> LedgerXConfig? {
        func move(_ a: String) -> String {
            a == from ? to : a.hasPrefix(from + ":") ? to + String(a.dropFirst(from.count)) : a
        }
        var c = self
        for i in c.rules.indices { c.rules[i].account = move(c.rules[i].account) }
        if let r = c.receivable { c.receivable = move(r) }
        // a merge can leave the same name twice
        func dedup(_ xs: [String]?) -> [String]? { xs.map { l in l.map(move).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } } }
        if let f = c.defaultFunding { c.defaultFunding = move(f) }
        if let m = c.scanCards { c.scanCards = m.mapValues(move) }
        c.netWorthExclude = dedup(c.netWorthExclude)
        c.balanceExclude = dedup(c.balanceExclude)
        return c == self ? nil : c
    }

    public func file(_ k: LayoutKind) -> String? {
        let v = (files[k.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    public static func parse(_ text: String) -> LedgerXConfig? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LedgerXConfig.self, from: d)
    }

    public func json() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var c = self
        c.files = files.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        c.rules = rules.filter { !$0.account.trimmingCharacters(in: .whitespaces).isEmpty && !$0.file.trimmingCharacters(in: .whitespaces).isEmpty }
        if c.receivable?.trimmingCharacters(in: .whitespaces).isEmpty ?? false { c.receivable = nil }
        if c.payslips?.isEmpty ?? false { c.payslips = nil }
        c.searches = c.searches?.filter { !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
        if c.searches?.isEmpty ?? false { c.searches = nil }
        if c.scanCards?.isEmpty ?? false { c.scanCards = nil }
        if c.netWorthExclude?.isEmpty ?? false { c.netWorthExclude = nil }
        if c.balanceExclude?.isEmpty ?? false { c.balanceExclude = nil }
        func blank(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if blank(c.main) { c.main = nil }
        if blank(c.defaultFunding) { c.defaultFunding = nil }
        if blank(c.defaultCurrency) { c.defaultCurrency = nil }
        for k in [\LedgerXConfig.alertsConfirmed, \.linksIgnored, \.subsIgnored, \.templatesPinned, \.templatesHidden] {
            if let l = c[keyPath: k] { c[keyPath: k] = l.isEmpty ? nil : Array(Set(l)).sorted() }
        }
        return (String(data: (try? e.encode(c)) ?? Data(), encoding: .utf8) ?? "{}") + "\n"
    }
}

/// Where things go in the repository. Defaults follow the usual layout
/// (main.bean including journals/<year>.bean); `detect` reads it off an existing ledger.
public struct RepoLayout: Equatable, Codable {
    public var main: String
    /// file for transactions; "{year}" / "{month}" are replaced from the transaction's date
    public var journal: String
    /// file for subscription lines (kept out of the main file)
    public var subscriptions: String?
    /// files set for the other kinds (empty = the file already holding most of them)
    public var files: [LayoutKind: String] = [:]
    /// transactions by account, before the journal
    public var rules: [LayoutRule] = []

    public init(main: String = "main.bean", journal: String = "journals/{year}.bean", subscriptions: String? = nil) {
        self.main = main
        self.journal = journal
        self.subscriptions = subscriptions
    }

    public var subscriptionsPath: String {
        let s = (subscriptions ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "subscriptions.bean" : s
    }

    /// the include line for `path`, relative to the main file's folder
    public func includeLine(_ path: String) -> String {
        let mainDir = RepoLayout(journal: main).journalDir
        let rel = !mainDir.isEmpty && path.hasPrefix(mainDir) ? String(path.dropFirst(mainDir.count)) : path
        return "include \"\(rel)\""
    }

    /// a file pattern filled in: {year}, {month} from the date, {root} from the account (Assets, Expenses, …),
    /// {root_lower} the same in small letters (assets, expenses, …)
    public static func expand(_ pattern: String, date: String, account: String? = nil) -> String {
        var p = pattern.replacingOccurrences(of: "{year}", with: String(date.prefix(4)))
        if p.contains("{month}") { p = p.replacingOccurrences(of: "{month}", with: String(date.dropFirst(5).prefix(2))) }
        let root = (account ?? "").components(separatedBy: ":")[0]
        if p.contains("{root_lower}") { p = p.replacingOccurrences(of: "{root_lower}", with: root.lowercased()) }
        if p.contains("{root}") { p = p.replacingOccurrences(of: "{root}", with: root) }
        return p
    }

    public func journalPath(_ date: String) -> String { RepoLayout.expand(journal, date: date) }
    /// "journals/" for "journals/{year}.bean"
    public var journalDir: String {
        guard let r = journal.range(of: "/", options: .backwards) else { return "" }
        return String(journal[..<r.upperBound])
    }

    /// the configured file for an entry (rules and kinds set in ledger-x.json), nil = decide automatically
    public func configured(_ e: Entry) -> String? {
        if e.type == .txn, let r = rules.first(where: { $0.matches(e) }) { return RepoLayout.expand(r.file, date: e.date) }
        guard let k = LayoutKind.of(e), k != .transactions, k != .subscriptions,
              let f = files[k]?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return nil }
        return RepoLayout.expand(f, date: e.date, account: e.account)
    }

    /// guess from the ledger: the file holding most of the latest year's transactions,
    /// with its year turned back into "{year}"
    public static func detect(_ L: Ledger, main: String = "main.bean") -> RepoLayout {
        guard let last = L.txns.last(where: { !$0.synthetic }) else { return RepoLayout(main: main) }
        let year = String(last.date.prefix(4))
        var count: [String: Int] = [:]
        for t in L.txns where !t.synthetic && t.date.hasPrefix(year) { count[t.file, default: 0] += 1 }
        guard let file = count.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { return RepoLayout(main: main) }
        if file.contains(year) { return RepoLayout(main: main, journal: file.replacingOccurrences(of: year, with: "{year}")) }
        return RepoLayout(main: main, journal: file)
    }
}

public func fileFor(_ e: Entry, _ L: Ledger, layout: RepoLayout = RepoLayout()) -> String {
    if let f = layout.configured(e) { return f }
    let journal = layout.journalPath(e.date)
    func most(_ pred: (Entry) -> Bool) -> String? {
        var c: [String: Int] = [:]
        for x in L.entries where pred(x) && !x.file.isEmpty { c[x.file, default: 0] += 1 }
        return c.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }
    func root(_ a: String?) -> String { (a ?? "").components(separatedBy: ":")[0] }
    switch e.type {
    case .balance: return most { $0.type == .balance } ?? journal
    case .price: return most { $0.type == .price } ?? journal
    case .open, .close:
        return most { ($0.type == .open || $0.type == .close) && root($0.account) == root(e.account) } ?? most { $0.type == .open } ?? journal
    case .commodity: return most { $0.type == .commodity } ?? journal
    case .document: return most { $0.type == .document } ?? journal
    // notes beside the balance assertions; Beancount's events with the notes
    case .note: return most { $0.type == .note } ?? most { $0.type == .balance } ?? journal
    case .event: return most { $0.type == .event } ?? most { $0.type == .note } ?? journal
    case .custom where e.name == "budget": return most { $0.type == .custom && $0.name == "budget" } ?? layout.main
    case .custom where e.name == "subscription": return layout.subscriptionsPath
    default: return journal
    }
}

/// where each kind of entry is now: the file holding most of them, and how many there are
public func layoutUsage(_ L: Ledger) -> [LayoutKind: (file: String, count: Int, files: Int)] {
    var by: [LayoutKind: [String: Int]] = [:]
    for e in L.entries where !e.file.isEmpty && !(e.type == .txn && e.synthetic) {
        guard let k = LayoutKind.of(e) else { continue }
        by[k, default: [:]][e.file, default: 0] += 1
    }
    var out: [LayoutKind: (file: String, count: Int, files: Int)] = [:]
    for (k, m) in by {
        let top = m.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!
        out[k] = (top.key, m.values.reduce(0, +), m.count)
    }
    return out
}

/// entries not in the file the configured layout gives them (only kinds and rules that are set)
public func misplacedEntries(_ L: Ledger, layout: RepoLayout) -> [(entry: Entry, to: String)] {
    var out: [(Entry, String)] = []
    for e in L.entries where !e.file.isEmpty && !e.src.isEmpty {
        if e.type == .txn && e.synthetic { continue }
        var to: String?
        if let f = layout.configured(e) { to = f }
        else if e.type == .txn, layout.files[.transactions] != nil { to = layout.journalPath(e.date) }
        else if LayoutKind.of(e) == .subscriptions, layout.files[.subscriptions] != nil { to = layout.subscriptionsPath }
        if let t = to, t != e.file { out.append((e, t)) }
    }
    return out
}

/// an existing assertion for the same account, date and currency (exact account)
public func existingBalance(_ L: Ledger, account: String, date: String, currency: String) -> BalanceResult? {
    L.balanceResults.first { $0.entry.account == account && $0.entry.date == date && $0.entry.currency == currency }
}

public func duplicateBalances(_ entries: [Entry], _ L: Ledger) -> [Entry] {
    entries.filter { $0.type == .balance && existingBalance(L, account: $0.account ?? "", date: $0.date, currency: $0.currency ?? "") != nil }
}

public struct OpError: Error {
    public let message: String
    public init(_ m: String) { message = m }
}

public struct OpExtra {
    public var label: String?
    public var silent: Bool?
    public init(label: String? = nil, silent: Bool? = nil) { self.label = label; self.silent = silent }
}

/// Turn validated text into queue operations (one per directive), in the file each belongs to.
/// `fileExists` says whether a path is in the repo already.
public func makeOps(_ text: String, _ L: Ledger, layout: RepoLayout = RepoLayout(), pending: [Op], fileExists: (String) -> Bool,
                    extra: OpExtra = OpExtra(), single: Bool) -> Result<[Op], OpError> {
    let v = validateText(text, L, single: single)
    guard v.ok else { return .failure(OpError(v.msg ?? tr("内容有误", "Invalid content"))) }
    let many = v.entries.count > 1
    var out: [Op] = []
    for (i, e) in v.entries.enumerated() {
        let path = fileFor(e, L, layout: layout)
        // a new file (a new year, the subscriptions file, a file from the layout): include it from the main file
        if path != layout.main && !fileExists(path) && !L.files.contains(path)
            && !pending.contains(where: { $0.path == path }) && !out.contains(where: { $0.path == path }) {
            var inc = Op(kind: .include, path: layout.main)
            inc.line = layout.includeLine(path)
            inc.silent = true
            out.append(inc)
        }
        let src = trimTrailing(e.src)
        let label = i == 0 ? extra.label : nil
        if e.type == .balance {
            let old = existingBalance(L, account: e.account ?? "", date: e.date, currency: e.currency ?? "")
            var op = Op(kind: .balance, path: old?.entry.file ?? path)
            op.account = e.account; op.date = e.date; op.currency = e.currency
            op.replace = old != nil
            op.line = src
            op.label = label ?? tr("\(old != nil ? "覆盖余额断言" : "余额核对")：\(e.account ?? "") \(e.date)", "\(old != nil ? "Replace balance" : "Balance check"): \(e.account ?? "") \(e.date)")
            op.summary = tr("\(old != nil ? "覆盖" : "")余额断言 \(e.account ?? "")", "\(old != nil ? "Replace " : "")balance \(e.account ?? "")")
            op.amountText = plainMoney(e.number, e.currency ?? "CNY")
            op.silent = extra.silent
            out.append(op)
            continue
        }
        var summary: String
        var amountText = ""
        if e.type == .txn {
            summary = [e.payee, e.narration].filter { !$0.isEmpty }.joined(separator: " ")
            if summary.isEmpty { summary = tr("交易", "Transaction") }
            let c = classify(postings: e.postings.filter { $0.units != nil }, date: e.date, L)
            amountText = c.kind == .transfer ? plainMoney(c.amount, c.currency ?? "CNY") : (c.amount > 1e-9 ? "+" : "") + plainMoney(c.amount)
        } else {
            summary = "\(KitLocale.chinese ? (TYPE_ZH[e.type] ?? e.type.rawValue) : e.type.rawValue) \(e.account ?? e.currency ?? e.name ?? "")".trimmingCharacters(in: .whitespaces)
        }
        var op = Op(kind: .insert, path: path)
        op.date = e.date; op.text = src; op.summary = summary; op.amountText = amountText
        op.label = many && i > 0 ? nil : label
        op.silent = extra.silent
        out.append(op)
    }
    return .success(out)
}

/// commit message for a group of ops written to one file
public func commitMessage(_ ops: [Op], path: String) -> String {
    let labels: [String] = ops.compactMap { o in
        if o.silent == true { return nil }
        if let l = o.label { return l }
        switch o.kind {
        case .insert: return tr("记账：", "Add: ") + "\(o.date ?? "") \(o.summary ?? "")"
        case .balance: return tr("余额核对：", "Balance check: ") + (o.account ?? "")
        default: return nil
        }
    }
    if labels.count == 1 { return labels[0] }
    if !labels.isEmpty { return tr("\(labels[0]) 等 \(labels.count) 项", "\(labels[0]) and \(labels.count - 1) more") }
    return tr("更新 \(path)", "Update \(path)")
}

// MARK: - from an existing transaction back to a form

/// An expense as the simple form writes 组合付款 / 优惠: one category (or advance) line, every other line paying
/// in the same currency (assets and liabilities), and at most one income line for a discount.
public func isComboPayment(_ t: Entry) -> Bool {
    guard t.flag == "*", t.postings.count > 2 else { return false }
    let pos = t.postings.filter { ($0.units ?? 0) > 0 }
    guard pos.count == 1, let cat = pos.first, let ccy = cat.currency,
          cat.account.hasPrefix("Expenses:") || (cat.account.hasPrefix("Assets:Receivable") && !isPersonal(cat.account)) else { return false }
    var funds = 0, discounts = 0
    for p in t.postings {
        guard p.cost == nil, p.price == nil, p.flag == nil, p.currency == ccy else { return false }
        if p === cat {
            if p.meta.items.contains(where: { $0.0 != categoryMeta && $0.0 != voucherMeta }) { return false }
            continue
        }
        guard p.meta.items.isEmpty, (p.units ?? 0) < 0 else { return false }
        if p.account.hasPrefix("Income:") { discounts += 1 }
        else if (p.account.hasPrefix("Assets:") || p.account.hasPrefix("Liabilities:")) && !isPersonal(p.account) { funds += 1 }
        else { return false }
    }
    // a discount only on an expense (an advance is entered at what was paid)
    if discounts > 0 && !cat.account.hasPrefix("Expenses:") { return false }
    return funds >= 1 && discounts <= 1 && (funds >= 2 || discounts == 1)
}

public func isComplex(_ t: Entry) -> Bool {
    let real = t.postings.filter { !$0.interpolated }
    if isComboPayment(t) { return false }
    if t.postings.count > 2 { return true }
    // `person:` on the receivable: the split form keeps it per row; an advance's `category:` the simple form keeps
    if t.postings.contains(where: { p in p.cost != nil || (p.price != nil && t.postings.count > 2) || p.flag != nil
        || p.meta.items.contains { kv in kv.0 != categoryMeta && kv.0 != voucherMeta } }) { return true }
    if t.flag != "*" { return true }
    return t.postings.count != real.count && t.postings.count > 1 && !t.tags.contains("transfer") && !t.tags.contains("fx")
        && !t.postings.contains(where: { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") })
}

public func rowsFromTxn(_ t: Entry, withAmounts: Bool = true) -> [DraftRow] {
    var rows: [DraftRow] = []
    for p in t.postings {
        if p.interpolated && rows.contains(where: { $0.account == p.account && $0.amount.isEmpty }) { continue }
        var r = DraftRow(account: p.account, currency: p.currency ?? "CNY")
        r.amount = withAmounts && !p.interpolated && p.units != nil ? numText(p.units!) : ""
        if let c = p.cost {
            r.cost = c.totalBraces ? "{{\(c.raw)}}" : p.booked != nil ? "{\(c.raw)}" : !c.raw.isEmpty ? c.raw : "{}"
        }
        if let pr = p.price {
            r.price = "\(pr.total ? "@@" : "@") \(pr.total ? numText(abs(pr.raw ?? 0)) : numText(pr.number ?? 0)) \(pr.currency ?? "")"
        }
        r.flag = p.flag ?? ""
        r.person = postingPerson(p) ?? ""
        for (k, v) in p.meta.items where k != personMeta { r.meta[k] = v.stringValue ?? v.display }
        rows.append(r)
    }
    return rows.isEmpty ? [DraftRow(), DraftRow()] : rows
}

public func multiDraftFromTxn(_ t: Entry, _ D: Derived, defaultFunding: String?) -> Draft {
    var d = newDraft(.multi, D, defaultFunding: defaultFunding)
    d.payee = t.payee; d.narration = t.narration; d.flag = t.flag == "!" ? "!" : "*"
    d.tagsText = (t.tags.map { "#" + $0 } + t.links.map { "^" + $0 }).joined(separator: " ")
    d.rows = rowsFromTxn(t, withAmounts: true)
    return d
}

public func draftFromTxn(_ t: Entry, kind: DraftKind? = nil, _ L: Ledger, _ D: Derived, defaultFunding: String?) -> Draft {
    if kind == nil && isComplex(t) { return multiDraftFromTxn(t, D, defaultFunding: defaultFunding) }
    let c = classify(t, L)
    // an advance to be reimbursed has no category (reimbursements account ← bank) but is an expense paid for
    // someone, not a transfer
    let advance = c.kind == .transfer && t.postings.contains { $0.account == D.receivable && ($0.units ?? 0) > 0 }
    var d = newDraft(kind ?? .expense, D, defaultFunding: defaultFunding)
    d.kind = kind ?? (advance ? .expense : c.kind == .refund ? .refund : c.kind == .income ? .income : c.kind == .transfer ? .transfer : .expense)
    d.payee = t.payee; d.narration = t.narration
    let combo = isComboPayment(t)
    let cat = combo ? t.postings.first { ($0.units ?? 0) > 0 }
        : t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") } ?? t.postings.first { $0.account.hasPrefix("Assets:Receivable") }
    let fund = t.postings.first { $0 !== cat && ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) }
    if d.kind == .transfer {
        let from = t.postings.first { ($0.units ?? 0) < 0 }, to = t.postings.first { ($0.units ?? 0) > 0 }
        d.funding = from?.account ?? ""; d.to = to?.account ?? ""
        d.amount = from?.units.map { jsNumberString(abs($0)) } ?? ""
        d.currency = from?.currency ?? "CNY"
        if let to = to, let from = from, to.currency != from.currency { d.toAmount = jsNumberString(to.units ?? 0) }
        d.payee = ""; d.narration = ""
    } else if let cat = cat {
        if cat.account.hasPrefix("Assets:Receivable") {
            d.reimb = true
            d.account = advanceCategory(cat) ?? D.rankAccounts(["Expenses:"]).first ?? ""
            d.voucher = cat.meta[voucherMeta].map { $0.stringValue ?? $0.display } ?? ""
            // paid from petty cash like the original while it lasts, else from the petty cash in hand (as when
            // 可报销 is switched on); a paid reimbursement's link is never reused
            let open = D.floats.filter { $0.left > 0.005 }
            d.link = t.links.first { l in open.contains { $0.link == l } } ?? open.last?.link ?? ""
        } else { d.account = cat.account }
        d.amount = jsNumberString(abs(cat.units ?? 0)); d.currency = cat.currency ?? "CNY"
        if combo {
            // the first paying line is the main account, the others its 组合付款 parts, an income line the discount
            let pay = t.postings.filter { $0 !== cat && !$0.account.hasPrefix("Income:") }
            d.funding = pay.first?.account ?? d.funding
            d.extraFunds = pay.dropFirst().map { ExtraFund(account: $0.account, amount: jsNumberString(abs($0.units ?? 0))) }
            if let disc = t.postings.first(where: { $0.account.hasPrefix("Income:") }) {
                d.discount = jsNumberString(abs(disc.units ?? 0))
                d.discountAccount = disc.account
            }
        } else if let fund = fund {
            d.funding = fund.account
            if fund.currency != cat.currency {
                d.paid = jsNumberString(abs(fund.units ?? 0))
                // a per-unit price on the category line is the receipt's rate: keep it
                if let pr = cat.price, !pr.total, let n = pr.number, pr.currency == fund.currency { d.byRate = true; d.rate = jsNumberString(n) }
            }
        }
    }
    return d
}

/// Link naming: <purpose>-<payee in pinyin>-<yyyymmdd>, e.g. refund-taobao-20260902.
/// `overrides` (from ledger-x.json "slugs") fixes polyphones and preferred spellings: 岭南通 羊城通 → yangchengtong.
public enum LinkNaming {
    public static var overrides: [String: String] = [:]
    /// place names in front and company words at the end say nothing about the payee
    static let prefixes = ["广东省", "广州市", "中国", "广东", "广州", "佛山", "南海区", "深圳"]
    static let suffixes = ["有限公司", "公司", "门店", "中心"]
}

func isHan(_ u: Unicode.Scalar) -> Bool { (0x3400...0x9FFF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) }

/// a readable piece of a link: "优衣库" → "youyiku", "Apple Store" → "apple-store", "广州腾视" → "tengshi".
/// At most `max` letters, cut between syllables or words (never inside one). Links allow only A-Z a-z 0-9 - _ / .
public func linkSlug(_ s0: String, max: Int = 16) -> String {
    let key = s0.trimmingCharacters(in: .whitespaces)
    if let o = LinkNaming.overrides[key], !o.isEmpty { return o }
    var s = key
    // "KFC 肯德基" → 肯德基: the Chinese name is the one that's meant
    if let r = s.range(of: #"^[A-Za-z0-9'&. ]+ (?=\p{Han})"#, options: .regularExpression) { s.removeSubrange(r) }
    for p in LinkNaming.prefixes where s.hasPrefix(p) && s.count - p.count >= 2 { s.removeFirst(p.count); break }
    for x in LinkNaming.suffixes where s.hasSuffix(x) && s.count - x.count >= 2 { s.removeLast(x.count); break }
    // pieces: one per Chinese character (its pinyin), one per run of ASCII letters/digits
    var parts: [(han: Bool, text: String)] = []
    var word = ""
    func flush() { if !word.isEmpty { parts.append((false, word.lowercased())); word = "" } }
    for ch in s {
        let u = ch.unicodeScalars.first!
        if isHan(u) {
            flush()
            var py = String(ch).applyingTransform(.toLatin, reverse: false) ?? ""
            py = (py.applyingTransform(.stripDiacritics, reverse: false) ?? py).lowercased()
            py = String(py.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            if !py.isEmpty { parts.append((true, py)) }
        } else if u.isASCII && CharacterSet.alphanumerics.contains(u) {
            word.append(ch)
        } else {
            flush()
        }
    }
    flush()
    var out = "", prevHan = false
    for p in parts {
        // syllables of one Chinese name run together; words are joined with "-"
        let sep = out.isEmpty || (p.han && prevHan) ? "" : "-"
        if !out.isEmpty && (out + sep + p.text).count > max { break }
        out = String((out + sep + p.text).prefix(max))
        prevHan = p.han
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

func uniqueLink(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    var k = 2
    while taken.contains("\(base)-\(k)") { k += 1 }
    return "\(base)-\(k)"
}

/// <purpose>-<payee>-<date> (the narration when there is no payee), with -2, -3 … when taken
public func newLink(_ purpose: String, payee: String, narration: String = "", date: String, taken: Set<String> = []) -> String {
    let d = date.replacingOccurrences(of: "-", with: "")
    var slug = linkSlug(payee)
    if slug.isEmpty { slug = linkSlug(narration) }
    return uniqueLink(slug.isEmpty ? "\(purpose)-\(d)" : "\(purpose)-\(slug)-\(d)", taken: taken)
}

/// a refund link for a purchase: refund-<payee>-<purchase date>
public func newRefundLink(_ t: Entry, taken: Set<String> = []) -> String {
    newLink("refund", payee: t.payee, narration: t.narration, date: t.date, taken: taken)
}

/// a link Beancount accepts
public func isValidLink(_ l: String) -> Bool {
    l.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-_/.]*$"#, options: .regularExpression) != nil
}

public func refundDraft(_ t: Entry, _ L: Ledger, _ D: Derived, defaultFunding: String?) -> Draft {
    var d = draftFromTxn(t, kind: .refund, L, D, defaultFunding: defaultFunding)
    d.kind = .refund; d.date = Day.today(); d.reimb = false
    let suffix = tr("退款", " (refund)")
    d.narration = !t.narration.isEmpty && !t.narration.hasSuffix(suffix) ? t.narration + suffix : t.narration
    let existing = t.links.first { $0.hasPrefix("refund") }
    let base = existing ?? newRefundLink(t, taken: Set(L.txns.flatMap { $0.links }))
    d.link = base
    if existing == nil {
        let header = t.src.components(separatedBy: "\n").first ?? ""
        d.refundOf = RefundOf(path: t.file, line: t.line, header: header, link: base)
    }
    return d
}

// MARK: - 汇率: 账单金额 × 汇率 = 换算金额

/// the three numbers of a payment in another currency; any two give the third
public enum RatePart: String, CaseIterable, Hashable { case amount, rate, converted }

/// the part not filled in, from the other two: an amount to the cent, a rate as it comes
public func solveRate(_ missing: RatePart, amount: Double?, rate: Double?, converted: Double?) -> Double? {
    switch missing {
    case .converted:
        guard let a = amount, let r = rate, r > 0 else { return nil }
        return mulMoney(a, r, 2)
    case .rate:
        guard let a = amount, a > 0, let c = converted, c > 0 else { return nil }
        return c / a
    case .amount:
        guard let r = rate, r > 0, let c = converted, c > 0 else { return nil }
        return divMoney(c, r, 2)
    }
}

/// a rate for showing: up to 5 places, no trailing zeros (6.70408, 7.8)
public func rateString(_ r: Double) -> String {
    var s = moneyText(r, 5)
    while s.contains("."), s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// how many of the account's currency one unit of the draft's comes to, as the draft has it: the rate typed in,
/// or what the amount charged (入账金额 for a transfer) works out to; nil when neither is filled in
public func draftRate(_ d: Draft) -> Double? {
    guard let a = evalAmount(d.amount), a > 0 else { return nil }
    if d.kind == .transfer { return evalAmount(d.toAmount).flatMap { $0 > 0 ? $0 / a : nil } }
    if d.byRate { return Double(d.rate.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
    return evalAmount(d.paid).flatMap { $0 > 0 ? $0 / a : nil }
}

/// the draft with the conversion filled in. A rate typed in (and the amount charged worked out from it) is
/// written as it is (`@ 1.17912 HKD`); otherwise the amount charged is (`@@`, or the per-unit price it
/// comes to). A transfer takes the amount received.
public func setConversion(_ d: inout Draft, amount: String, rate: String, converted: String, computed: RatePart) {
    d.amount = amount
    if d.kind == .transfer {
        d.toAmount = converted
    } else if computed == .converted {
        d.byRate = true; d.rate = rate; d.paid = ""
    } else {
        d.byRate = false; d.paid = converted; d.rate = ""
    }
    d.edited = nil
}
