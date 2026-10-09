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
    return plain ? v : roundTo(v, 2)
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
    public var ccyTouched = false
    public init(account: String = "", currency: String = "CNY") { self.account = account; self.currency = currency }
}

public enum DraftKind: String, CaseIterable, Identifiable {
    case expense, income, transfer, refund, multi, raw
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .expense: return "支出"
        case .income: return "收入"
        case .transfer: return "转账"
        case .refund: return "退款"
        case .multi: return "分录"
        case .raw: return "文本"
        }
    }
}

public struct RefundOf: Equatable {
    public var path: String
    public var line: Int
    public var header: String
    public var link: String
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
    public init() {}
}

public func parseTagsLinks(_ s: String) -> (tags: [String], links: [String]) {
    var tags: [String] = [], links: [String] = []
    for w in s.components(separatedBy: CharacterSet(charactersIn: " \t,，")) where !w.isEmpty {
        if w.hasPrefix("^") { let v = String(w.dropFirst()); if !v.isEmpty { links.append(v) } }
        else { let v = w.hasPrefix("#") ? String(w.dropFirst()) : w; if !v.isEmpty { tags.append(v) } }
    }
    return (tags, links)
}

public func newDraft(_ kind: DraftKind = .expense, _ D: Derived, defaultFunding: String?) -> Draft {
    var d = Draft()
    d.kind = kind
    let funding = defaultFunding.flatMap { D.openAccounts.contains($0) ? $0 : nil } ?? D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).first ?? ""
    d.funding = funding
    d.currency = D.acctCcy[funding] ?? "CNY"
    d.rows = [DraftRow(), DraftRow(account: funding, currency: D.acctCcy[funding] ?? "CNY")]
    return d
}

func multiTx(_ d: Draft, _ L: Ledger) -> TxDraft? {
    let tl = parseTagsLinks(d.tagsText)
    let rows = d.rows.filter { !$0.account.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !d.date.isEmpty, !rows.isEmpty else { return nil }
    var tx = TxDraft(date: d.date)
    tx.flag = d.flag.isEmpty ? "*" : d.flag
    tx.payee = d.payee.trimmingCharacters(in: .whitespaces)
    tx.narration = d.narration.trimmingCharacters(in: .whitespaces)
    tx.tags = tl.tags; tx.links = tl.links
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
        p.meta = []
        return p
    }
    return tx
}

func draftTx(_ d: Draft, _ L: Ledger, _ D: Derived) -> TxDraft? {
    guard !d.date.isEmpty, let amt = evalAmount(d.amount), amt > 0 else { return nil }
    var tx = TxDraft(date: d.date)
    tx.payee = d.payee.trimmingCharacters(in: .whitespaces)
    tx.narration = d.narration.trimmingCharacters(in: .whitespaces)
    tx.tags = d.tags
    let lk = d.link.trimmingCharacters(in: .whitespaces)
    tx.links = lk.isEmpty ? [] : [lk.hasPrefix("^") ? String(lk.dropFirst()) : lk]
    if d.kind == .transfer {
        guard !d.funding.isEmpty, !d.to.isEmpty else { return nil }
        let fc = d.currency, tc = D.acctCcy[d.to] ?? fc
        if d.to.hasPrefix("Liabilities:CreditCard") {
            if tx.payee.isEmpty { tx.payee = "\(leaf(d.to)) Credit Card" }
            if tx.narration.isEmpty { tx.narration = "Repayment" }
            tx.postings = [TxPosting(account: d.to, amount: amt, currency: fc), TxPosting(account: d.funding, amount: -amt, currency: fc)]
        } else {
            if tx.payee.isEmpty { tx.payee = "Transfer" }
            if tx.narration.isEmpty { tx.narration = "\(D.shortName(d.funding)) -> \(D.shortName(d.to))" }
            if !tx.tags.contains("transfer") { tx.tags.insert("transfer", at: 0) }
            if tc != fc, let ta = evalAmount(d.toAmount), ta > 0 {
                tx.meta.append(("exchange_rate", "1 \(fc) = \(toFixed(ta / amt, 5)) \(tc)"))
                var toP = TxPosting(account: d.to, amount: ta, currency: tc)
                toP.priceTotal = amt; toP.priceCcy = fc
                tx.postings = [TxPosting(account: d.funding, amount: -amt, currency: fc), toP]
            } else {
                tx.postings = [TxPosting(account: d.funding, amount: -amt, currency: fc), TxPosting(account: d.to, amount: amt, currency: fc)]
            }
        }
        return tx
    }
    guard !d.account.isEmpty, !d.funding.isEmpty else { return nil }
    let sgn: Double = d.kind == .expense ? 1 : -1 // income & refund reduce the category
    let fc = D.acctCcy[d.funding] ?? d.currency
    var catAccount = d.account
    if d.kind == .expense && d.reimb {
        catAccount = D.receivable
        if !tx.tags.contains("reimbursed") { tx.tags.append("reimbursed") }
    }
    if d.kind == .refund && !tx.tags.contains("refund") { tx.tags.append("refund") }
    var cat = TxPosting(account: catAccount, amount: sgn * amt, currency: d.currency)
    if fc != d.currency, let paid = evalAmount(d.paid), paid > 0 {
        cat.suffix = "@ \(toFixed(paid / amt, 5)) \(fc)"
        tx.postings = [cat, TxPosting(account: d.funding, amount: -sgn * paid, currency: fc)]
    } else {
        tx.postings = [cat, TxPosting(account: d.funding, amount: -sgn * amt, currency: d.currency)]
    }
    return tx
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
    return formatTxn(tx)
}

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
        return Validation(ok: false, msg: r.msg ?? "这里应当正好是一笔交易", entries: r.entries, warnings: r.warnings)
    }
    if r.ok && txns.contains(where: { $0.postings.count < 2 }) {
        return Validation(ok: false, msg: "交易至少需要两条分录", entries: r.entries, warnings: r.warnings)
    }
    return Validation(ok: r.ok, msg: r.msg, entries: r.entries, warnings: r.warnings)
}

public let TYPE_ZH: [EntryType: String] = [.txn: "交易", .balance: "余额断言", .price: "价格", .open: "开户", .close: "关户", .commodity: "商品",
                                           .pad: "补齐", .note: "备注", .event: "事件", .document: "文档", .query: "查询", .custom: "自定义"]

/// Where things go in the repository. Defaults follow the usual layout
/// (main.bean including journals/<year>.bean); `detect` reads it off an existing ledger.
public struct RepoLayout: Equatable, Codable {
    public var main: String
    /// file for transactions; "{year}" is replaced by the transaction's year
    public var journal: String

    public init(main: String = "main.bean", journal: String = "journals/{year}.bean") {
        self.main = main
        self.journal = journal
    }

    public func journalPath(_ date: String) -> String { journal.replacingOccurrences(of: "{year}", with: String(date.prefix(4))) }
    public var perYear: Bool { journal.contains("{year}") }
    /// "journals/" for "journals/{year}.bean"
    public var journalDir: String {
        guard let r = journal.range(of: "/", options: .backwards) else { return "" }
        return String(journal[..<r.upperBound])
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
    default: return journal
    }
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
    guard v.ok else { return .failure(OpError(v.msg ?? "内容有误")) }
    let many = v.entries.count > 1
    var out: [Op] = []
    for (i, e) in v.entries.enumerated() {
        let path = fileFor(e, L, layout: layout)
        if layout.perYear && path == layout.journalPath(e.date) && !fileExists(path)
            && !pending.contains(where: { $0.path == path }) && !out.contains(where: { $0.path == path }) {
            // a new year's file: include it from the main file (path relative to it)
            var inc = Op(kind: .include, path: layout.main)
            let mainDir = RepoLayout(journal: layout.main).journalDir
            let rel = !mainDir.isEmpty && path.hasPrefix(mainDir) ? String(path.dropFirst(mainDir.count)) : path
            inc.line = "include \"\(rel)\""
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
            op.label = label ?? "\(old != nil ? "覆盖对账" : "对账")：\(e.account ?? "") \(e.date)"
            op.summary = "\(old != nil ? "覆盖" : "")余额断言 \(e.account ?? "")"
            op.amountText = money(e.number, e.currency ?? "CNY")
            op.silent = extra.silent
            out.append(op)
            continue
        }
        var summary: String
        var amountText = ""
        if e.type == .txn {
            summary = [e.payee, e.narration].filter { !$0.isEmpty }.joined(separator: " ")
            if summary.isEmpty { summary = "交易" }
            let c = classify(postings: e.postings.filter { $0.units != nil }, date: e.date, L)
            amountText = c.kind == .transfer ? money(c.amount, c.currency ?? "CNY") : signedMoney(c.amount)
        } else {
            summary = "\(TYPE_ZH[e.type] ?? e.type.rawValue) \(e.account ?? e.currency ?? e.name ?? "")".trimmingCharacters(in: .whitespaces)
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
        case .insert: return "记账：\(o.date ?? "") \(o.summary ?? "")"
        case .balance: return "对账：\(o.account ?? "")"
        default: return nil
        }
    }
    if labels.count == 1 { return labels[0] }
    if !labels.isEmpty { return "\(labels[0]) 等 \(labels.count) 项" }
    return "更新 \(path)"
}

// MARK: - from an existing transaction back to a form

public func isComplex(_ t: Entry) -> Bool {
    let real = t.postings.filter { !$0.interpolated }
    if t.postings.count > 2 { return true }
    if t.postings.contains(where: { $0.cost != nil || ($0.price != nil && t.postings.count > 2) || $0.flag != nil || !$0.meta.isEmpty }) { return true }
    if t.flag != "*" { return true }
    return t.postings.count != real.count && t.postings.count > 1 && !t.tags.contains("transfer")
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
    var d = newDraft(kind ?? .expense, D, defaultFunding: defaultFunding)
    d.kind = kind ?? (c.kind == .refund ? .refund : c.kind == .income ? .income : c.kind == .transfer ? .transfer : .expense)
    d.payee = t.payee; d.narration = t.narration
    let cat = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") } ?? t.postings.first { $0.account.hasPrefix("Assets:Receivable") }
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
            d.account = D.rankAccounts(["Expenses:"]).first ?? ""
        } else { d.account = cat.account }
        d.amount = jsNumberString(abs(cat.units ?? 0)); d.currency = cat.currency ?? "CNY"
        if let fund = fund {
            d.funding = fund.account
            if fund.currency != cat.currency { d.paid = jsNumberString(abs(fund.units ?? 0)) }
        }
    }
    return d
}

public func refundDraft(_ t: Entry, _ L: Ledger, _ D: Derived, defaultFunding: String?) -> Draft {
    var d = draftFromTxn(t, kind: .refund, L, D, defaultFunding: defaultFunding)
    d.kind = .refund; d.date = Day.today(); d.reimb = false
    d.narration = !t.narration.isEmpty && !t.narration.hasSuffix("退款") ? t.narration + "退款" : t.narration
    let existing = t.links.first { $0.hasPrefix("refund") }
    var h: UInt32 = 0
    for ch in (t.payee + t.narration + t.date).utf16 { h = h &* 31 &+ UInt32(ch) }
    let base = existing ?? "refund-\(t.date.replacingOccurrences(of: "-", with: ""))-\(String(String(h, radix: 36).suffix(4)))"
    d.link = base
    if existing == nil {
        let header = t.src.components(separatedBy: "\n").first ?? ""
        d.refundOf = RefundOf(path: t.file, line: t.line, header: header, link: base)
    }
    return d
}
