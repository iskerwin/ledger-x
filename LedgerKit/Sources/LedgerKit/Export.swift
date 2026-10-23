import Foundation

/// Transactions between `from` and `to` (inclusive, "" = open) as CSV, one row per posting, for a
/// spreadsheet. Starts with a byte-order mark so Excel reads the Chinese text as UTF-8.
/// One CSV cell. Text that a spreadsheet would run as a formula (=, +, -, @, tab or return first: a payee from an
/// imported statement or a scan, "=HYPERLINK(…)") gets a leading ' so it opens as text; numbers stay numbers.
public func csvCell(_ s: String) -> String {
    var s = s
    if let first = s.first, "=+-@\t\r".contains(first), s.range(of: #"^[+-]?\d+(\.\d+)?$"#, options: .regularExpression) == nil {
        s = "'" + s
    }
    return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
}

public func exportCSV(_ L: Ledger, from: String = "", to: String = "") -> String {
    let cell = csvCell
    var lines = [tr("日期,状态,收付款方,摘要,科目,金额,币种,标签,链接,文件",
                    "Date,Flag,Payee,Narration,Account,Amount,Currency,Tags,Links,File")]
    for t in L.txns where !t.synthetic && (from.isEmpty || t.date >= from) && (to.isEmpty || t.date <= to) {
        for p in t.postings {
            let row = [t.date, t.flag, t.payee, t.narration, p.account,
                       p.units.map { jsNumberString($0) } ?? "", p.currency ?? "",
                       t.tags.joined(separator: " "), t.links.joined(separator: " "), t.file]
            lines.append(row.map(cell).joined(separator: ","))
        }
    }
    return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
}
