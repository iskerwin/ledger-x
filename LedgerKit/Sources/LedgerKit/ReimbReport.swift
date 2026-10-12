import Foundation

// MARK: - 报销单: the advances of one reimbursement (a ^reimburse-… batch, a petty cash ^float-…, the ones
// not claimed yet, or an event) as a list to hand to the company

public struct ReimbLine: Identifiable {
    public let entry: Entry
    public let date: String
    public let payee: String
    public let narration: String
    /// the account it was paid from, by its display name
    public let method: String
    /// on the reimbursement account
    public let amount: Double
    public let currency: String
    public var id: ObjectIdentifier { ObjectIdentifier(entry) }
}

public struct ReimbReport {
    public let title: String
    /// who pays it back: the payee most of the batch's payouts or links point to, if known
    public let payer: String
    public let lines: [ReimbLine]
    /// per currency, in the order first seen
    public let totals: [(currency: String, amount: Double)]
    public var from: String { lines.first?.date ?? "" }
    public var to: String { lines.last?.date ?? "" }
}

/// The advances among `entries`: each transaction's positive postings on the reimbursement account (petty cash
/// handed over, payouts and returns are left out), oldest first.
public func reimbReport(_ entries: [Entry], _ L: Ledger, receivable: String, title: String, payer: String = "") -> ReimbReport {
    var lines: [ReimbLine] = []
    var seen = Set<ObjectIdentifier>()
    for t in entries.sorted(by: { $0.date != $1.date ? $0.date < $1.date : $0.line < $1.line }) where !t.synthetic {
        guard seen.insert(ObjectIdentifier(t)).inserted else { continue }
        var by: [String: Double] = [:], order: [String] = []
        for p in t.postings where p.account == receivable {
            guard let u = p.units, u > 0, let c = p.currency else { continue }
            if by[c] == nil { order.append(c) }
            by[c, default: 0] += u
        }
        guard !order.isEmpty else { continue }
        let paid = t.postings.first { ($0.units ?? 0) < 0 && $0.account != receivable }?.account
        for c in order {
            lines.append(ReimbLine(entry: t, date: t.date, payee: t.payee, narration: t.narration,
                                   method: paid.map { accountTitle(L, $0) } ?? "", amount: roundTo(by[c]!, 2), currency: c))
        }
    }
    var tot: [String: Double] = [:], order: [String] = []
    for l in lines {
        if tot[l.currency] == nil { order.append(l.currency) }
        tot[l.currency, default: 0] += l.amount
    }
    // who pays it back: given, else whoever paid out or handed over the petty cash in this group
    let from = payer.isEmpty ? entries.first { t in t.postings.contains { $0.account == receivable && ($0.units ?? 0) < 0 } }?.payee ?? "" : payer
    return ReimbReport(title: title, payer: from, lines: lines, totals: order.map { ($0, roundTo(tot[$0]!, 2)) })
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
