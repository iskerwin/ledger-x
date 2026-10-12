import XCTest
@testable import LedgerKit

/// 报销单: which lines go on it, totals and the CSV
final class ReimbReportTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    func testReport() {
        let L = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
          name: "中国银行"
        2026-01-01 open Assets:Receivable:Reimbursement

        2026-08-31 * "柴鹿" "备用金" ^float-co-20260831
          Assets:Receivable:Reimbursement  -1000.00 CNY
          Assets:Bank  1000.00 CNY

        2026-09-02 * "五金店" "网线, 六类" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  98.00 CNY
          Assets:Bank  -98.00 CNY

        2026-09-01 * "高德打车" "郑州出差" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  9.59 CNY
          Assets:Bank  -9.59 CNY

        """)
        let es = L.txns.filter { $0.links.contains("float-co-20260831") }
        let r = reimbReport(es, L, receivable: "Assets:Receivable:Reimbursement", title: "^float-co-20260831")
        // the petty cash handed over is not a line; oldest first
        XCTAssertEqual(r.lines.map { $0.payee }, ["高德打车", "五金店"])
        XCTAssertEqual(r.lines[0].method, "中国银行")
        XCTAssertEqual(r.totals.first?.amount, 107.59)
        XCTAssertEqual(r.payer, "柴鹿")
        XCTAssertEqual(r.from, "2026-09-01")
        let csv = reimbCSV(r) { $0.payee == "五金店" ? ["a.jpg"] : [] }
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("2,2026-09-02,五金店,\"网线, 六类\",中国银行,98.00,CNY,a.jpg"), csv)
        XCTAssertTrue(csv.contains("107.59,CNY"), csv)
    }
}
