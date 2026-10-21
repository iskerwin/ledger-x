import Foundation

// MARK: - 报销单: the advances of one reimbursement (a ^reimburse-… batch, a petty cash ^float-…, the ones
// not claimed yet, or an event) as a list to hand to the company

public struct ReimbLine: Identifiable {
    public let entry: Entry
    public let date: String
    public let payee: String
    public let narration: String
    /// the account it was paid from (or, for money received, paid into), by its display name
    public let method: String
    /// on the reimbursement account, always positive
    public let amount: Double
    public let currency: String
    /// money received from the company (petty cash handed over, a payout) rather than an advance
    public let income: Bool
    /// 支出类型: the advance's `category:` (or the payee's usual category), by its display name
    public let category: String
    /// 凭证类型: `voucher:` on the advance, if given
    public let voucher: String
    /// the category is the payee's usual one, not written on the advance
    public let guessed: Bool
    public var id: String { "\(ObjectIdentifier(entry).hashValue)|\(currency)|\(income)" }
}

public struct ReimbReport {
    public let title: String
    /// who pays it back: the payee most of the batch's payouts or links point to, if known
    public let payer: String
    /// the advances
    public let lines: [ReimbLine]
    /// advances and money received, in date order (the running balance of the 报销模板)
    public let rows: [ReimbLine]
    /// per currency, in the order first seen
    public let totals: [(currency: String, amount: Double)]
    public var from: String { lines.first?.date ?? "" }
    public var to: String { lines.last?.date ?? "" }
}

/// the category a payee's own (not reimbursed) spending is usually recorded under, most recent first
func usualCategories(_ L: Ledger) -> [String: String] {
    var out: [String: String] = [:]
    for t in L.txns where !t.payee.isEmpty {
        if let e = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }) { out[t.payee] = e.account }
    }
    return out
}

/// The advances among `entries` (each transaction's positive postings on the reimbursement account) and the money
/// received from the company (its negative ones: petty cash handed over, payouts), oldest first.
public func reimbReport(_ entries: [Entry], _ L: Ledger, receivable: String, title: String, payer: String = "") -> ReimbReport {
    var rows: [ReimbLine] = []
    var seen = Set<ObjectIdentifier>()
    let usual = usualCategories(L)
    for t in entries.sorted(by: { $0.date != $1.date ? $0.date < $1.date : $0.line < $1.line }) where !t.synthetic {
        guard seen.insert(ObjectIdentifier(t)).inserted else { continue }
        for income in [false, true] {
            var by: [String: Double] = [:], order: [String] = []
            var cat: String?, voucher = ""
            for p in t.postings where p.account == receivable {
                guard let u = p.units, (u < 0) == income, abs(u) > 0.004, let c = p.currency else { continue }
                if by[c] == nil { order.append(c) }
                by[c, default: 0] += abs(u)
                if cat == nil { cat = advanceCategory(p) }
                if let v = p.meta[voucherMeta] { voucher = v.stringValue ?? v.display }
            }
            if order.isEmpty { continue }
            let other = t.postings.first { $0.account != receivable && (($0.units ?? 0) > 0) == income && !$0.account.hasPrefix("Income:") }?.account
            let category = income ? "" : (cat ?? usual[t.payee]).map { accountTitle(L, $0) } ?? ""
            for c in order {
                rows.append(ReimbLine(entry: t, date: t.date, payee: t.payee, narration: t.narration,
                                      method: other.map { accountTitle(L, $0) } ?? "", amount: roundTo(by[c]!, 2), currency: c,
                                      income: income, category: category, voucher: voucher, guessed: !income && cat == nil && !category.isEmpty))
            }
        }
    }
    let lines = rows.filter { !$0.income }
    var tot: [String: Double] = [:], order: [String] = []
    for l in lines {
        if tot[l.currency] == nil { order.append(l.currency) }
        tot[l.currency, default: 0] += l.amount
    }
    // who pays it back: given, else whoever paid out or handed over the petty cash in this group
    let from = payer.isEmpty ? rows.first { $0.income }?.payee ?? "" : payer
    return ReimbReport(title: title, payer: from, lines: lines, rows: rows, totals: order.map { ($0, roundTo(tot[$0]!, 2)) })
}

/// the report as CSV for a spreadsheet (byte-order mark so Excel reads the Chinese as UTF-8); `docs` gives the
/// file names attached to each line's transaction
public func reimbCSV(_ r: ReimbReport, docs: (Entry) -> [String] = { _ in [] }) -> String {
    func cell(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
    var rows = [tr("序号,日期,商户,说明,付款方式,金额,币种,附件", "No.,Date,Merchant,Description,Paid with,Amount,Currency,Attachments")]
    for (i, l) in r.lines.enumerated() {
        rows.append([String(i + 1), l.date, l.payee, l.narration, l.method, toFixed(l.amount, 2), l.currency,
                     docs(l.entry).joined(separator: " ")].map(cell).joined(separator: ","))
    }
    for t in r.totals { rows.append([tr("合计", "Total"), "", "", "", "", toFixed(t.amount, 2), t.currency, ""].map(cell).joined(separator: ",")) }
    return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
}

// MARK: - 报销单 and 备用金 as a whole: every ^reimburse-… and ^float-… link, open or settled

public struct ReimbBatch: Identifiable {
    public enum Kind { case reimburse, float }
    public let link: String
    public let kind: Kind
    /// advances (positive on the receivable accounts)
    public let advanced: Double
    /// paid back / petty cash handed over (negative on them)
    public let received: Double
    public let currency: String
    public let first: String
    public let last: String
    /// who paid it back or handed over the petty cash
    public let payer: String
    /// advances in it
    public let count: Int
    public var id: String { link }
    /// what is still open: owed to you for a reimbursement; petty cash still in hand (negative) for a float
    public var balance: Double { roundTo(advanced - received, 2) }
    public var settled: Bool { abs(balance) < 0.005 }
}

/// Every reimbursement batch and petty cash in the ledger (on any receivable but the company's salary account),
/// open ones first, then the newest.
public func reimbBatches(_ L: Ledger) -> [ReimbBatch] {
    var plus: [String: Double] = [:], minus: [String: Double] = [:], ccy: [String: String] = [:]
    var first: [String: String] = [:], last: [String: String] = [:], payer: [String: String] = [:], n: [String: Int] = [:]
    var order: [String] = []
    for t in L.txns where !t.synthetic {
        for l in t.links where l.hasPrefix("reimburse") || isFloatLink(l) {
            var touched = false
            // the reimbursement account, or a person's receivable for one they pay back (older ledgers)
            for p in t.postings where p.account.hasPrefix("Assets:Receivable") && !isSalaryClearing(p.account) {
                guard let u = p.units else { continue }
                touched = true
                if u > 0 { plus[l, default: 0] += u; n[l, default: 0] += 1 } else {
                    minus[l, default: 0] -= u
                    if payer[l] == nil, !t.payee.isEmpty { payer[l] = t.payee }
                }
                ccy[l] = p.currency ?? L.base
            }
            guard touched else { continue }
            if first[l] == nil { order.append(l); first[l] = t.date }
            last[l] = max(last[l] ?? "", t.date)
        }
    }
    let out = order.map { l in
        ReimbBatch(link: l, kind: isFloatLink(l) ? .float : .reimburse, advanced: roundTo(plus[l] ?? 0, 2), received: roundTo(minus[l] ?? 0, 2),
                   currency: ccy[l] ?? L.base, first: first[l] ?? "", last: last[l] ?? "", payer: payer[l] ?? "", count: n[l] ?? 0)
    }
    return out.sorted { a, b in
        if a.settled != b.settled { return !a.settled }
        return a.last != b.last ? a.last > b.last : a.link < b.link
    }
}

// MARK: - metadata on one posting, for editing 支出类型 / 凭证类型 in place

/// The transaction text with `key: value` set on the first posting to `account` whose amount has `sign` (or
/// removed when `value` is nil); every other line stays as it is. nil when there is no such posting.
public func setPostingMeta(_ src: String, account: String, positive: Bool = true, key: String, value: String?) -> String? {
    var lines = src.components(separatedBy: "\n")
    func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
    guard let i = lines.indices.first(where: { k in
        let l = lines[k], t = l.trimmingCharacters(in: .whitespaces)
        guard k > 0, indent(l) > 0, t.hasPrefix(account) else { return false }
        let rest = t.dropFirst(account.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return false }
        let n = Double(rest.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
        return positive ? n > 0 : n < 0
    }) else { return nil }
    let pad = String(repeating: " ", count: indent(lines[i]) + 2)
    // the posting's own metadata: the deeper-indented lines right under it
    var j = i + 1, at: Int?
    while j < lines.count, indent(lines[j]) > indent(lines[i]), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
        if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") { at = j }
        j += 1
    }
    let v = value?.trimmingCharacters(in: .whitespaces) ?? ""
    if let a = at {
        if v.isEmpty { lines.remove(at: a) } else { lines[a] = metaLine(pad, key, v) }
    } else if !v.isEmpty {
        lines.insert(metaLine(pad, key, v), at: j)
    }
    return lines.joined(separator: "\n")
}

/// The transaction text with `key: value` set in the transaction's own metadata (the indented `key:` lines
/// before the first posting), or removed when `value` is nil; every other line stays as it is.
public func setTxnMeta(_ src: String, key: String, value: String?) -> String {
    var lines = src.components(separatedBy: "\n")
    guard !lines.isEmpty else { return src }
    func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
    // metadata, tag lines and comments come first; the first posting ends them
    var j = 1, at: Int?, pad = "  "
    while j < lines.count {
        let t = lines[j].trimmingCharacters(in: .whitespaces)
        guard indent(lines[j]) > 0, !t.isEmpty else { break }
        if t.hasPrefix(";") || t.hasPrefix("#") || t.hasPrefix("^") { j += 1; continue }
        guard let c = t.firstIndex(of: ":"), let f = t.first, f.isLowercase,
              t[..<c].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { break }
        pad = String(lines[j].prefix(indent(lines[j])))
        if t[..<c] == key { at = j }
        j += 1
    }
    let v = value?.trimmingCharacters(in: .whitespaces) ?? ""
    if let a = at {
        if v.isEmpty { lines.remove(at: a) } else { lines[a] = metaLine(pad, key, v) }
    } else if !v.isEmpty {
        lines.insert(metaLine(pad, key, v), at: j)
    }
    return lines.joined(separator: "\n")
}

/// 凭证类型 written on an advance
public let voucherMeta = "voucher"
/// the usual kinds of 凭证
public let voucherKinds = ["发票", "收据", "无"]

/// A reimbursement batch has one currency; a mixed selection must never be summed as raw numbers.
public func reimbursementTotal(_ items: [Unclaimed], currency: String) -> Double? {
    guard items.allSatisfy({ $0.currency == currency && $0.amount.isFinite }) else { return nil }
    return roundMoney(items.reduce(0) { $0 + $1.amount }, 2)
}
