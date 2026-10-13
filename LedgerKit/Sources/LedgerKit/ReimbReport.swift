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
                if let v = p.meta["voucher"] { voucher = v.stringValue ?? v.display }
            }
            if order.isEmpty { continue }
            let other = t.postings.first { $0.account != receivable && (($0.units ?? 0) > 0) == income && !$0.account.hasPrefix("Income:") }?.account
            let category = income ? "" : (cat ?? usual[t.payee]).map { accountTitle(L, $0) } ?? ""
            for c in order {
                rows.append(ReimbLine(entry: t, date: t.date, payee: t.payee, narration: t.narration,
                                      method: other.map { accountTitle(L, $0) } ?? "", amount: roundTo(by[c]!, 2), currency: c,
                                      income: income, category: category, voucher: voucher))
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
