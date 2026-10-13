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

        2026-08-31 * "星河" "备用金" ^float-co-20260831
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
        XCTAssertEqual(r.payer, "星河")
        XCTAssertEqual(r.from, "2026-09-01")
        let csv = reimbCSV(r) { $0.payee == "五金店" ? ["a.jpg"] : [] }
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("2,2026-09-02,五金店,\"网线, 六类\",中国银行,98.00,CNY,a.jpg"), csv)
        XCTAssertTrue(csv.contains("107.59,CNY"), csv)
    }

    func testXLSX() throws {
        let L = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Assets:Receivable:Reimbursement
        2026-01-01 open Expenses:Transit:Tolls
          name: "路桥通行"
        2026-01-01 open Expenses:Transit:Taxi
          name: "打车出行"

        2026-08-10 * "ETC" "高速费" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  50.00 CNY
            category: "Expenses:Transit:Tolls"
            voucher: "发票"
          Assets:Bank  -50.00 CNY

        2026-08-31 * "星河" "备用金" ^float-co-20260831
          Assets:Receivable:Reimbursement  -5000.00 CNY
          Assets:Bank  5000.00 CNY

        2026-09-01 * "高德打车" "郑州出差 & <夜>" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  9.59 CNY
          Assets:Bank  -9.59 CNY

        2026-09-02 * "五金店" "网线" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  98.00 CNY
          Assets:Bank  -98.00 CNY

        2026-09-03 * "高德打车" "打车"
          Expenses:Transit:Taxi  12.00 CNY
          Assets:Bank  -12.00 CNY

        """)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let es = L.txns.filter { $0.links.contains("float-co-20260831") }
        let r = reimbReport(es, L, receivable: "Assets:Receivable:Reimbursement", title: "^float-co-20260831")
        // money received is a row of its own; the category comes from the advance, else the payee's usual one
        XCTAssertEqual(r.rows.map { $0.income }, [false, true, false, false])
        XCTAssertEqual(r.rows.map { $0.category }, ["路桥通行", "", "打车出行", ""])
        XCTAssertEqual(r.rows[0].voucher, "发票")
        XCTAssertEqual(r.lines.count, 3)
        XCTAssertEqual(excelSerial("2026-08-10"), 46244)
        XCTAssertEqual(colName(0), "A"); XCTAssertEqual(colName(26), "AA")
        XCTAssertEqual(crc32(Data("123456789".utf8)), 0xCBF43926)

        let x = reimbXLSX(r)
        XCTAssertEqual(Array(x.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let text = String(decoding: x, as: UTF8.self)
        XCTAssertTrue(text.contains("郑州出差 &amp; &lt;夜&gt;"))
        XCTAssertTrue(text.contains("<f>E2+C3-D3</f><v>4950</v>"), "running balance after the petty cash")
        XCTAssertTrue(text.contains("<f>SUM(D2:D5)</f><v>157.59</v>"))
        // a sample for checking in Excel / LibreOffice (CI uploads it with the dev build)
        if let dir = ProcessInfo.processInfo.environment["SAMPLE_OUT"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try x.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample-reimb.xlsx"))
        }
    }

    func testBatchesAndEditing() {
        let L = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Assets:Receivable:Reimbursement
        2026-01-01 open Income:ReimbExcess

        2026-07-01 * "店" "工具" #reimbursed ^reimburse-co-20260710
          Assets:Receivable:Reimbursement  100.00 CNY
          Assets:Bank  -100.00 CNY

        2026-07-10 * "星河" "报销入账" #reimbursement ^reimburse-co-20260710
          Assets:Receivable:Reimbursement  -100.00 CNY
          Assets:Bank  100.00 CNY

        2026-08-31 * "星河" "备用金" ^float-co-20260831
          Assets:Receivable:Reimbursement  -1000.00 CNY
          Assets:Bank  1000.00 CNY

        2026-09-02 * "五金店" "网线" #reimbursed ^float-co-20260831
          Assets:Receivable:Reimbursement  98.00 CNY
          Assets:Bank  -98.00 CNY

        """)
        let b = reimbBatches(L)
        // the open petty cash first, then the settled reimbursement
        XCTAssertEqual(b.map { $0.link }, ["float-co-20260831", "reimburse-co-20260710"])
        XCTAssertEqual(b[0].balance, -902)
        XCTAssertEqual(b[0].payer, "星河")
        XCTAssertTrue(b[1].settled)
        XCTAssertEqual(b[1].count, 1)
        XCTAssertEqual(b[1].last, "2026-07-10")

        // 支出类型 / 凭证类型 on the advance line only
        let src = L.txns.first { $0.payee == "五金店" }!.src
        let a = setPostingMeta(src, account: "Assets:Receivable:Reimbursement", key: "category", value: "Expenses:Shopping:Household")!
        XCTAssertTrue(a.contains("  Assets:Receivable:Reimbursement  98.00 CNY\n    category: \"Expenses:Shopping:Household\"\n  Assets:Bank"), a)
        let v = setPostingMeta(a, account: "Assets:Receivable:Reimbursement", key: "voucher", value: "收据")!
        XCTAssertTrue(v.contains("    category: \"Expenses:Shopping:Household\"\n    voucher: \"收据\"\n  Assets:Bank"), v)
        let c = setPostingMeta(v, account: "Assets:Receivable:Reimbursement", key: "voucher", value: "发票")!
        XCTAssertTrue(c.contains("voucher: \"发票\"") && !c.contains("收据"), c)
        XCTAssertEqual(setPostingMeta(c, account: "Assets:Receivable:Reimbursement", key: "voucher", value: nil), a)
        XCTAssertNil(setPostingMeta(src, account: "Assets:Receivable:Reimbursement", positive: false, key: "voucher", value: "x"))
        // the edited text still parses and balances
        XCTAssertTrue(validateText(v, L).ok)

        // a reimbursable expense written from the form keeps both
        let D = Derived(L, today: "2026-10-01")
        var d = Draft()
        d.kind = .expense; d.date = "2026-10-01"; d.payee = "五金店"; d.account = "Expenses:Shopping:Household"; d.funding = "Assets:Bank"
        d.amount = "20"; d.currency = "CNY"; d.reimb = true; d.voucher = "收据"
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("    category: \"Expenses:Shopping:Household\"\n    voucher: \"收据\""), t)
        let back = draftFromTxn(ledger("option \"operating_currency\" \"CNY\"\n2026-01-01 open Assets:Bank CNY\n2026-01-01 open Assets:Receivable:Reimbursement\n2026-01-01 open Expenses:Shopping:Household\n" + t + "\n").txns.last!, L, D, defaultFunding: nil)
        XCTAssertEqual(back.kind, .expense)
        XCTAssertEqual(back.voucher, "收据")
        XCTAssertEqual(back.account, "Expenses:Shopping:Household")
    }
}
