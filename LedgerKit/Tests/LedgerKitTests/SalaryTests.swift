import XCTest
@testable import LedgerKit

/// salary by payslip
final class SalaryTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:BOC CNY
    2026-01-01 open Assets:Receivable:Employer
    2026-01-01 open Income:Salary:Base CNY
    2026-01-01 open Income:Salary:Bonus CNY
    2026-01-01 open Equity:Opening

    2026-09-09 * "星河" "2026-07 工资" ^salary-xinghe-202607
      payslip_days: 22
      Income:Salary:Base  -5000.00 CNY
      Assets:Bank:BOC  5000.00 CNY

    """

    func testPayslip() {
        let L = ledger(base)
        let t = PayslipTemplate(employer: "星河", account: "Assets:Bank:BOC")
        XCTAssertEqual(t.linkSlug, "xinghe")
        var d = payslipDraft(L, template: t, month: "2026-08", date: "2026-09-24")
        XCTAssertEqual(d.values["基本工资"], "5000.00")      // from July's payslip
        XCTAssertEqual(d.days, "22")
        d.values["绩效工资"] = "2000"
        d.values["请假扣除工资"] = "60"
        d.values["其他扣除"] = "40"
        XCTAssertEqual(d.gross, 7000)
        XCTAssertEqual(d.net, 6900)
        d.received = "4960"
        XCTAssertEqual(d.pending, 1940)
        let text = payslipText(d, L)
        // the accounts the ledger lacks are opened, both deductions go to one posting
        XCTAssertTrue(text.contains("open Income:Salary:Performance"), text)
        XCTAssertTrue(text.contains("open Income:Salary:Deduction"), text)
        XCTAssertFalse(text.contains("IncomeTax"), text)
        XCTAssertTrue(text.contains("2026-09-24 * \"星河\" \"2026-08 工资\" ^salary-xinghe-202608"), text)
        XCTAssertTrue(validateText(text, L, single: false).ok, text)
        let after = ledger(base + text + "\n")
        let tx = after.txns.last!
        XCTAssertEqual(tx.postings.first { $0.account == "Income:Salary:Deduction" }?.units, 100)
        XCTAssertEqual(tx.postings.first { $0.account == "Assets:Receivable:Employer" }?.units, 1940)
        XCTAssertEqual(employerOpen(after).open.map { $0.link }, ["salary-xinghe-202608"])

        let y = salaryYears(after)[0]
        XCTAssertEqual(y.year, "2026")
        XCTAssertEqual(y.gross, 12000)
        XCTAssertEqual(y.deductions, 100)
        XCTAssertEqual(y.months, 1)   // both paid in September

        // nothing earned: nothing to save
        XCTAssertEqual(payslipText(PayslipDraft(template: t, month: "2026-08", date: "2026-09-24"), L), "")
    }

    func testTemplatesInConfig() {
        var c = LedgerXConfig()
        XCTAssertFalse(c.json().contains("payslips"))
        c.payslips = [PayslipTemplate(employer: "星河", account: "Assets:Bank:BOC")]
        let back = LedgerXConfig.parse(c.json())
        XCTAssertEqual(back?.payslips?.first?.items.count, PayslipTemplate.defaultItems.count)
        XCTAssertEqual(back?.payslips?.first?.items.last?.deduct, true)
    }
}
